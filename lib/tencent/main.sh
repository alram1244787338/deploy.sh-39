#!/bin/bash
# -*- coding: utf-8 -*-

# =============================================================================
# 腾讯云账户余额查询
#
# 用法:
#   ./main.sh                          # 从 [default] 段读取密钥
#   ./main.sh --section myaccount      # 从指定配置段读取密钥
#   DEBUG=true ./main.sh               # 输出签名和请求细节到 stderr
#
# 凭证优先级:
#   1. --section <name>  → 仅从该段读取，失败即退出
#   2. 无 --section      → 先尝试 [default] 段，失败后 fallback 到环境变量
#      TENCENT_SECRET_ID / TENCENT_SECRET_KEY
# =============================================================================

# ---- 内部工具函数 ----

_tencent_err() {
    echo "错误：$*" >&2
}

_tencent_debug() {
    [[ "${DEBUG:-}" == "true" ]] && echo "[DEBUG] $*" >&2
    return 0
}

# ---- 凭证读取 ----
# 从 ~/.tencentcloud/credentials（INI 格式）读取指定配置段的 secret_id / secret_key。
# 容错：空行、注释行（# 或 ; 开头）、等号两侧空格、值末尾空格均可正确处理。
# 输出: secret_id<TAB>secret_key
# 返回: 0 成功, 1 文件缺失或字段不全

read_credentials() {
    local credentials_file="${HOME}/.tencentcloud/credentials"
    local section="${1:-default}"

    if [[ ! -f "$credentials_file" ]]; then
        _tencent_err "配置文件不存在: ${credentials_file}"
        return 1
    fi

    local in_section=0
    local secret_id=""
    local secret_key=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去除首尾空白（纯 bash，不依赖 sed）
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # 跳过空行和注释行
        [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

        # 匹配配置段 [section_name]
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            local sec_name="${BASH_REMATCH[1]}"
            # 段名两侧也去空格
            sec_name="${sec_name#"${sec_name%%[![:space:]]*}"}"
            sec_name="${sec_name%"${sec_name##*[![:space:]]}"}"
            [[ "$sec_name" == "$section" ]] && in_section=1 || in_section=0
            continue
        fi

        # 在目标段内解析 key = value
        if [[ $in_section -eq 1 && "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*) ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # 去除值尾部空格
            val="${val%"${val##*[![:space:]]}"}"
            case "$key" in
                secret_id)  secret_id="$val" ;;
                secret_key) secret_key="$val" ;;
            esac
        fi
    done < "$credentials_file"

    # 精确提示缺失字段
    if [[ -z "$secret_id" && -z "$secret_key" ]]; then
        _tencent_err "配置段 [${section}] 中未找到 secret_id 和 secret_key (${credentials_file})"
        return 1
    elif [[ -z "$secret_id" ]]; then
        _tencent_err "配置段 [${section}] 中缺少 secret_id (${credentials_file})"
        return 1
    elif [[ -z "$secret_key" ]]; then
        _tencent_err "配置段 [${section}] 中缺少 secret_key (${credentials_file})"
        return 1
    fi

    printf '%s\t%s' "$secret_id" "$secret_key"
}

# ---- TC3-HMAC-SHA256 签名 ----

# 跨平台 date：先尝试 GNU (-d)，再尝试 BSD/macOS (-r)
_portable_date_from_epoch() {
    local ts="$1" fmt="$2"
    date -u -d "@${ts}" +"$fmt" 2>/dev/null && return
    date -u -r "$ts" +"$fmt" 2>/dev/null
}

generate_signature() {
    local secret_id="$1"
    local secret_key="$2"
    local timestamp="$3"
    local payload="$4"
    local host="billing.tencentcloudapi.com"
    local service="billing"
    local algorithm="TC3-HMAC-SHA256"
    local date
    date=$(_portable_date_from_epoch "$timestamp" "%Y-%m-%d")

    # 1. 拼接规范请求串（使用 printf 确保 \n 为真实换行符）
    local hashed_request_payload
    hashed_request_payload=$(printf '%s' "$payload" | openssl dgst -sha256 -hex | sed 's/^.* //')

    local canonical_request
    printf -v canonical_request \
        'POST\n/\n\ncontent-type:application/json\nhost:%s\n\ncontent-type;host\n%s' \
        "$host" "$hashed_request_payload"

    _tencent_debug "Canonical Request:"
    _tencent_debug "$canonical_request"

    # 2. 拼接待签名字符串
    local credential_scope="${date}/${service}/tc3_request"
    local hashed_canonical_request
    hashed_canonical_request=$(printf '%s' "$canonical_request" | openssl dgst -sha256 -hex | sed 's/^.* //')

    local string_to_sign
    printf -v string_to_sign '%s\n%s\n%s\n%s' \
        "$algorithm" "$timestamp" "$credential_scope" "$hashed_canonical_request"

    _tencent_debug "String to Sign:"
    _tencent_debug "$string_to_sign"

    # 3. 派生签名密钥 (HMAC 链)
    local secret_date secret_service secret_signing signature
    secret_date=$(printf '%s' "$date"          | openssl dgst -sha256 -hmac "TC3${secret_key}" -hex | sed 's/^.* //')
    secret_service=$(printf '%s' "$service"    | openssl dgst -sha256 -hmac "$secret_date"      -hex | sed 's/^.* //')
    secret_signing=$(printf '%s' "tc3_request" | openssl dgst -sha256 -hmac "$secret_service"   -hex | sed 's/^.* //')
    signature=$(printf '%s' "$string_to_sign"  | openssl dgst -sha256 -hmac "$secret_signing"   -hex | sed 's/^.* //')

    # 4. 拼接 Authorization 头
    echo "${algorithm} Credential=${secret_id}/${credential_scope}, SignedHeaders=content-type;host, Signature=${signature}"
}

# ---- 响应解析 ----

_parse_balance_response() {
    local response="$1"

    # 1) 合法 JSON 校验
    if ! printf '%s' "$response" | jq empty 2>/dev/null; then
        _tencent_err "接口返回了非 JSON 内容，请求可能被截断或网络异常"
        _tencent_debug "原始响应: $response"
        return 1
    fi

    # 2) 必须有 Response 顶层字段
    if ! printf '%s' "$response" | jq -e '.Response' >/dev/null 2>&1; then
        _tencent_err "接口响应缺少 Response 字段"
        _tencent_debug "原始响应: $response"
        return 1
    fi

    # 3) API 错误对象
    if printf '%s' "$response" | jq -e '.Response.Error' >/dev/null 2>&1; then
        local error_code error_message
        error_code=$(printf '%s' "$response" | jq -r '.Response.Error.Code // "Unknown"')
        error_message=$(printf '%s' "$response" | jq -r '.Response.Error.Message // "未知错误"')
        _tencent_err "查询失败 (${error_code}): ${error_message}"
        return 1
    fi

    # 4) 提取余额字段
    local balance credit real_balance
    balance=$(printf '%s' "$response" | jq -r '.Response.Balance // empty')
    credit=$(printf '%s' "$response" | jq -r '.Response.Credit // empty')
    real_balance=$(printf '%s' "$response" | jq -r '.Response.RealBalance // empty')

    if [[ -z "$balance" ]]; then
        _tencent_err "响应中缺少 Balance 字段，无法解析余额"
        _tencent_debug "原始响应: $response"
        return 1
    fi

    # 保持原有输出风格
    echo "账户余额信息："
    echo "--------------------------------"
    echo "账户余额：￥${balance}"
    echo "账户可用信用额度：￥${credit:-0}"
    echo "现金余额：￥${real_balance:-0}"
    return 0
}

# ---- 余额查询入口 ----

query_balance() {
    local section=""
    local explicit_section=0

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --section)
                section="${2:-}"
                explicit_section=1
                shift 2
                ;;
            --help|-h)
                echo "用法: $0 [--section <配置段名>]"
                echo ""
                echo "选项:"
                echo "  --section <name>   指定 credentials 中的配置段（默认 default）"
                echo ""
                echo "凭证来源优先级:"
                echo "  1. --section 指定段 → 仅使用该段"
                echo "  2. 无 --section    → [default] 段 → 环境变量 fallback"
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done

    # ---- 凭证获取策略 ----
    # 显式 --section: 只从该段读，失败直接退出
    # 无 --section:    先试 [default]，失败再尝试环境变量
    local secret_id="" secret_key=""

    if [[ $explicit_section -eq 1 ]]; then
        local credentials
        if credentials=$(read_credentials "$section"); then
            IFS=$'\t' read -r secret_id secret_key <<< "$credentials"
        else
            return 1
        fi
    else
        local credentials
        if credentials=$(read_credentials "default" 2>/dev/null); then
            IFS=$'\t' read -r secret_id secret_key <<< "$credentials"
        else
            _tencent_debug "配置文件未命中 [default]，尝试环境变量"
            secret_id="${TENCENT_SECRET_ID:-}"
            secret_key="${TENCENT_SECRET_KEY:-}"
        fi
    fi

    if [[ -z "${secret_id:-}" || -z "${secret_key:-}" ]]; then
        _tencent_err "未能获取到有效的密钥信息"
        echo "请确保以下任一条件满足：" >&2
        echo "  1. 配置文件 ~/.tencentcloud/credentials 包含 [default] 段及 secret_id / secret_key" >&2
        echo "  2. 使用 --section <name> 指定一个有效的配置段" >&2
        echo "  3. 设置环境变量 TENCENT_SECRET_ID 和 TENCENT_SECRET_KEY" >&2
        return 1
    fi

    # ---- 签名 ----
    local timestamp payload authorization
    timestamp=$(date +%s)
    payload="{}"
    authorization=$(generate_signature "$secret_id" "$secret_key" "$timestamp" "$payload")

    _tencent_debug "Authorization: $authorization"
    _tencent_debug "Timestamp: $timestamp"

    # ---- 发起 HTTP 请求 ----
    # curl 的 verbose/debug 输出和响应体严格分离：
    #   - 响应体 → stdout（被 $() 捕获）
    #   - curl 自身调试信息 → stderr（重定向到临时文件，仅在 DEBUG 模式展示）
    #   - -w 将 HTTP 状态码追加到 stdout 末尾，与响应体以换行分隔
    local response http_code
    local curl_stderr_tmp
    curl_stderr_tmp=$(mktemp 2>/dev/null || echo "/dev/null")

    response=$(curl -s -S -X POST "https://billing.tencentcloudapi.com/" \
        -H "Authorization: ${authorization}" \
        -H "Content-Type: application/json" \
        -H "X-TC-Timestamp: ${timestamp}" \
        -H "X-TC-Action: DescribeAccountBalance" \
        -H "X-TC-Version: 2018-07-09" \
        -H "X-TC-Region: ap-guangzhou" \
        -w $'\n%{http_code}' \
        -d "$payload" \
        2>"$curl_stderr_tmp")
    local curl_exit=$?

    # debug 模式下展示 curl stderr
    if [[ "${DEBUG:-}" == "true" && -f "$curl_stderr_tmp" && "$curl_stderr_tmp" != "/dev/null" ]]; then
        echo "===== curl stderr =====" >&2
        cat "$curl_stderr_tmp" >&2
        echo "=======================" >&2
    fi
    [[ -f "$curl_stderr_tmp" && "$curl_stderr_tmp" != "/dev/null" ]] && rm -f "$curl_stderr_tmp"

    # curl 自身失败（DNS、连接等）
    if [[ $curl_exit -ne 0 ]]; then
        _tencent_err "curl 请求失败 (退出码: ${curl_exit})，请检查网络连接"
        _tencent_debug "响应内容: $response"
        return 1
    fi

    # 空响应
    if [[ -z "$response" ]]; then
        _tencent_err "请求无响应，请检查网络连接"
        return 1
    fi

    # 分离 HTTP 状态码（最后一行）和响应体
    http_code=$(printf '%s' "$response" | tail -n1)
    response=$(printf '%s' "$response" | sed '$d')

    _tencent_debug "HTTP Status: $http_code"
    _tencent_debug "Response: $response"

    # HTTP 状态码检查
    if [[ "$http_code" != "200" ]]; then
        _tencent_err "HTTP 请求失败，状态码: ${http_code}"
        _tencent_debug "响应体: $response"
        return 1
    fi

    # 解析响应
    _parse_balance_response "$response"
}

# ---- bin/cloud 入口适配 ----
# bin/cloud 在 source 本文件后调用 handle_command "<command>" [args...]

handle_command() {
    local command="${1:-}"
    shift 2>/dev/null || true
    case "$command" in
        balance)
            query_balance "$@"
            ;;
        *)
            echo "Usage: cloud --provider tencent balance [--section <name>]" >&2
            echo "" >&2
            echo "可用命令:" >&2
            echo "  balance    查询账户余额" >&2
            return 1
            ;;
    esac
}

# ---- 向后兼容 ----
# 直接执行脚本时自动调用 query_balance；被 source 时仅定义函数。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_balance "$@"
fi
