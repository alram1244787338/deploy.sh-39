#!/bin/bash
# -*- coding: utf-8 -*-
#
# 腾讯云账户余额查询。
#
# 取密钥优先级：
#   1. 凭证文件中的指定配置段（默认 default，可通过第一个参数指定，如 `query_balance prod`）
#   2. 上一步失败时回退到环境变量 TENCENT_SECRET_ID / TENCENT_SECRET_KEY
#
# 可选环境变量：
#   DEBUG=true                  打印签名与请求细节（仅 stderr，不污染正常输出）
#   TENCENT_CREDENTIALS_FILE    覆盖默认凭证文件路径 ~/.tencentcloud/credentials

# 仅在 DEBUG 模式下向 stderr 打印调试信息，正常模式静默。
_log_debug() {
    [[ "${DEBUG:-}" == "true" ]] && echo "$@" >&2
    return 0
}

# 检查必要的外部依赖命令是否存在，缺失时给出可读提示。
_require_cmd() {
    local missing=0 c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "错误：缺少依赖命令 '$c'，请先安装后再运行。" >&2
            missing=1
        fi
    done
    return $missing
}

# 跨平台地把 Unix 时间戳转换为 UTC 的 YYYY-MM-DD（BSD/macOS 用 -r，GNU/Linux 用 -d）。
# 两种平台输出的日期字符串一致，因此签名结果不受平台影响。
_epoch_to_date() {
    local ts="$1"
    date -u -r "$ts" +%Y-%m-%d 2>/dev/null || date -u -d "@$ts" +%Y-%m-%d 2>/dev/null
}

# 去除字符串首尾空白（纯 bash，不依赖 sed）。
_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# 从凭证文件的指定配置段读取 secret_id / secret_key。
# 成功：stdout 输出 "secret_id<TAB>secret_key"，返回 0。
# 失败：不向 stderr 输出（避免环境变量回退成功时产生噪音），把具体原因写入全局变量
#       CRED_ERR，并按原因返回不同退出码：
#         2 = 文件不存在    3 = 配置段不存在    4 = 字段缺失
read_credentials() {
    CRED_ERR=""
    local section="${1:-default}"
    local credentials_file="${TENCENT_CREDENTIALS_FILE:-${HOME}/.tencentcloud/credentials}"

    if [[ ! -f "$credentials_file" ]]; then
        CRED_ERR="凭证文件不存在：${credentials_file}"
        return 2
    fi

    local in_section=0 found_section=0
    local secret_id="" secret_key=""
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(_trim "$line")

        # 跳过空行与注释（# 或 ; 开头）
        [[ -z "$line" ]] && continue
        [[ "$line" == "#"* || "$line" == ";"* ]] && continue

        # 配置段标记 [name]
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            if [[ "$(_trim "${BASH_REMATCH[1]}")" == "$section" ]]; then
                in_section=1
                found_section=1
            else
                in_section=0
            fi
            continue
        fi

        # 目标配置段内的 key = value（用首个 = 切分，值中允许包含 =）
        if [[ $in_section -eq 1 && "$line" == *=* ]]; then
            key=$(_trim "${line%%=*}")
            value=$(_trim "${line#*=}")
            case "$key" in
                secret_id)  secret_id="$value" ;;
                secret_key) secret_key="$value" ;;
            esac
        fi
    done < "$credentials_file"

    if [[ $found_section -eq 0 ]]; then
        CRED_ERR="凭证文件 ${credentials_file} 中未找到配置段 [${section}]"
        return 3
    fi

    local missing=()
    [[ -z "$secret_id" ]]  && missing+=("secret_id")
    [[ -z "$secret_key" ]] && missing+=("secret_key")
    if [[ ${#missing[@]} -gt 0 ]]; then
        CRED_ERR="配置段 [${section}] 缺少字段：${missing[*]}（文件：${credentials_file}）"
        return 4
    fi

    printf '%s\t%s' "$secret_id" "$secret_key"
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
    date=$(_epoch_to_date "$timestamp")

    # 1. 拼接规范请求串
    local http_request_method="POST"
    local canonical_uri="/"
    local canonical_querystring=""
    local canonical_headers="content-type:application/json\nhost:${host}\n"
    local signed_headers="content-type;host"

    # 计算请求体哈希
    local hashed_request_payload
    hashed_request_payload=$(echo -n "$payload" | openssl dgst -sha256 -hex | sed 's/^.* //')

    local canonical_request="${http_request_method}\n${canonical_uri}\n${canonical_querystring}\n${canonical_headers}\n${signed_headers}\n${hashed_request_payload}"

    # 调试信息
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "===== Debug Info =====" >&2
        echo "Canonical Request:" >&2
        echo -e "$canonical_request" >&2
        echo "Hashed Payload: $hashed_request_payload" >&2
        echo "===================" >&2
    fi

    # 2. 拼接待签名字符串
    local credential_scope="${date}/${service}/tc3_request"
    local hashed_canonical_request
    hashed_canonical_request=$(echo -n "$canonical_request" | openssl dgst -sha256 -hex | sed 's/^.* //')
    local string_to_sign="${algorithm}\n${timestamp}\n${credential_scope}\n${hashed_canonical_request}"

    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "String to Sign:" >&2
        echo -e "$string_to_sign" >&2
        echo "===================" >&2
    fi

    # 3. 计算签名
    local secret_date
    secret_date=$(echo -n "$date" | openssl dgst -sha256 -hmac "TC3${secret_key}" -hex | sed 's/^.* //')
    local secret_service
    secret_service=$(echo -n "$service" | openssl dgst -sha256 -hmac "$secret_date" -hex | sed 's/^.* //')
    local secret_signing
    secret_signing=$(echo -n "tc3_request" | openssl dgst -sha256 -hmac "$secret_service" -hex | sed 's/^.* //')
    local signature
    signature=$(echo -n "$string_to_sign" | openssl dgst -sha256 -hmac "$secret_signing" -hex | sed 's/^.* //')

    # 4. 拼接 Authorization
    echo "${algorithm} Credential=${secret_id}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"
}

# 发送余额查询请求。stdout 只输出接口返回的响应体；curl 的 verbose/错误
# 信息一律走 stderr，且 verbose 仅在 DEBUG 模式下展示，绝不与 JSON 混在一起。
# 返回 curl 的退出码（非 0 表示网络/传输错误）。
# 该函数被单独拆出，便于测试时用 stub 替换，无需真正访问腾讯云接口。
_send_billing_request() {
    local authorization="$1"
    local timestamp="$2"
    local payload="$3"
    local url="https://billing.tencentcloudapi.com/"

    local curl_args=(
        -sS -X POST "$url"
        -H "Authorization: $authorization"
        -H "Content-Type: application/json"
        -H "X-TC-Timestamp: $timestamp"
        -H "X-TC-Action: DescribeAccountBalance"
        -H "X-TC-Version: 2018-07-09"
        -H "X-TC-Region: ap-guangzhou"
        -d "$payload"
    )

    local err_file body status
    err_file=$(mktemp)

    if [[ "${DEBUG:-}" == "true" ]]; then
        body=$(curl -v "${curl_args[@]}" 2>"$err_file")
        status=$?
        echo "===== curl 调试输出 =====" >&2
        cat "$err_file" >&2
        echo "=========================" >&2
    else
        body=$(curl "${curl_args[@]}" 2>"$err_file")
        status=$?
        # 正常模式下只在传输失败时把 curl 的错误透传到 stderr
        [[ $status -ne 0 ]] && cat "$err_file" >&2
    fi

    rm -f "$err_file"
    printf '%s' "$body"
    return $status
}

query_balance() {
    local section="${1:-default}"

    _require_cmd curl jq openssl || return 1

    # ---- 取密钥：配置段优先，失败回退环境变量 ----
    local secret_id secret_key cred_source="" creds
    if creds=$(read_credentials "$section"); then
        IFS=$'\t' read -r secret_id secret_key <<< "$creds"
        cred_source="凭证文件[${section}]"
    else
        _log_debug "凭证文件读取失败：${CRED_ERR}（尝试回退环境变量）"
        secret_id="${TENCENT_SECRET_ID:-}"
        secret_key="${TENCENT_SECRET_KEY:-}"
        [[ -n "$secret_id" && -n "$secret_key" ]] && cred_source="环境变量"
    fi

    if [[ -z "$secret_id" || -z "$secret_key" ]]; then
        echo "错误：未能获取到有效的密钥信息。" >&2
        [[ -n "$CRED_ERR" ]] && echo "  - 凭证文件：${CRED_ERR}" >&2
        echo "  - 环境变量：请设置 TENCENT_SECRET_ID 与 TENCENT_SECRET_KEY" >&2
        echo "提示：可用第一个参数指定配置段（如 query_balance prod），或用 TENCENT_CREDENTIALS_FILE 指定文件路径。" >&2
        return 1
    fi
    _log_debug "使用凭证来源：${cred_source}"

    # ---- 构造并发送请求 ----
    local timestamp payload authorization
    timestamp=$(date +%s)
    payload="{}"
    authorization=$(generate_signature "$secret_id" "$secret_key" "$timestamp" "$payload")
    _log_debug "Authorization: $authorization"
    _log_debug "Timestamp: $timestamp"

    local response status
    response=$(_send_billing_request "$authorization" "$timestamp" "$payload")
    status=$?

    # ---- 统一错误路径 ----
    if [[ $status -ne 0 ]]; then
        echo "错误：查询请求失败（网络或传输错误，curl 退出码 ${status}）。" >&2
        return 1
    fi

    if [[ -z "${response//[[:space:]]/}" ]]; then
        echo "错误：查询请求未返回任何内容。" >&2
        return 1
    fi

    # JSON 合法性校验：非 JSON、半截内容都在这里被拦下，不让 jq 在后续解析时炸掉
    if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
        echo "错误：响应不是合法的 JSON（可能是网络中断、被拦截或返回了非预期内容）。" >&2
        _log_debug "原始响应（前 500 字符）："
        _log_debug "$(printf '%s' "$response" | head -c 500)"
        return 1
    fi

    # 接口返回的错误对象
    if printf '%s' "$response" | jq -e '.Response.Error' >/dev/null 2>&1; then
        local error_code error_message
        error_code=$(printf '%s' "$response" | jq -r '.Response.Error.Code // "Unknown"')
        error_message=$(printf '%s' "$response" | jq -r '.Response.Error.Message // "无错误信息"')
        echo "错误：查询失败 (代码: ${error_code}) - ${error_message}" >&2
        return 1
    fi

    # ---- 解析并显示余额信息 ----
    local balance credit real_balance
    balance=$(printf '%s' "$response" | jq -r '.Response.Balance // "N/A"')
    credit=$(printf '%s' "$response" | jq -r '.Response.Credit // "N/A"')
    real_balance=$(printf '%s' "$response" | jq -r '.Response.RealBalance // "N/A"')

    echo "账户余额信息："
    echo "--------------------------------"
    echo "账户余额：￥${balance}"
    echo "账户可用信用额度：￥${credit}"
    echo "现金余额：￥${real_balance}"
    return 0
}

# 仅在脚本被直接执行时运行查询；被 source 时不自动执行，便于测试注入 stub。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    query_balance "$@"
fi
