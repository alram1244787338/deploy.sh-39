#!/bin/bash
# -*- coding: utf-8 -*-
# =============================================================================
# lib/tencent/test_balance.sh — 腾讯云余额查询离线单元测试
#
# 不依赖真实腾讯云 API，通过 mock curl 函数覆盖所有核心路径：
#   - 凭证读取（默认段、显式段、缺失字段、环境变量 fallback）
#   - 成功响应解析
#   - API 错误对象
#   - 非 JSON / 截断 JSON / 空响应
#   - HTTP 错误状态码
#   - curl 连接失败
#
# 用法:
#   bash lib/tencent/test_balance.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 测试框架 ----
_PASS=0
_FAIL=0
_CURRENT_GROUP=""

_group() {
    _CURRENT_GROUP="$1"
    echo ""
    echo "[$1]"
}

_pass() {
    echo "  ✓ $1"
    ((_PASS++))
}

_fail() {
    echo "  ✗ $1"
    [[ -n "${2:-}" ]] && echo "    ↳ $2"
    ((_FAIL++))
}

# 断言：输出包含期望子串
assert_contains() {
    local test_name="$1" output="$2" expected="$3"
    if echo "$output" | grep -qF "$expected"; then
        _pass "$test_name"
    else
        _fail "$test_name" "期望包含: '$expected'"
    fi
}

# 断言：输出不包含期望子串
assert_not_contains() {
    local test_name="$1" output="$2" unexpected="$3"
    if ! echo "$output" | grep -qF "$unexpected"; then
        _pass "$test_name"
    else
        _fail "$test_name" "不应包含: '$unexpected'"
    fi
}

# 断言：退出码匹配
assert_exit() {
    local test_name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$test_name"
    else
        _fail "$test_name" "期望退出码 $expected，实际 $actual"
    fi
}

# ---- 测试环境 ----
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# 隔离 HOME，避免影响真实配置
export HOME="$TMPDIR_TEST"
mkdir -p "$HOME/.tencentcloud"
cat > "$HOME/.tencentcloud/credentials" <<'CRED'
[default]
secret_id = AKID_default_id
secret_key = default_key_abc

; 这是注释行
# 这也是注释行

[myaccount]
  secret_id = AKID_custom_id
  secret_key  =  custom_key_xyz

[broken]
secret_id = AKID_broken_only

[empty_section]
CRED

# ---- Mock curl ----
# 通过环境变量控制 mock 行为:
#   CURL_MOCK_BODY  — 响应体
#   CURL_MOCK_CODE  — HTTP 状态码（追加到输出末尾，模拟 -w '%{http_code}'）
#   CURL_MOCK_EXIT  — curl 自身退出码（0=成功）

CURL_MOCK_BODY=""
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

curl() {
    # 忽略所有参数，输出 mock 响应体 + 换行 + 状态码
    printf '%s\n%s' "$CURL_MOCK_BODY" "$CURL_MOCK_CODE"
    return "${CURL_MOCK_EXIT:-0}"
}
# 不需要 export -f，因为 query_balance 在同一 shell 的 $() 子 shell 中调用 curl，
# 子 shell 继承父 shell 的函数定义。

# ---- 加载被测脚本（阻止自动执行） ----
CLOUD_CLI_HOME="__test_sourced__"
source "$SCRIPT_DIR/main.sh"

# 关闭 set -e 以免影响测试流程（各断言独立判断）
set +e

# =====================================================================
#  测试开始
# =====================================================================
echo ""
echo "======================================"
echo "  腾讯云余额查询 — 离线单元测试"
echo "======================================"

# ---- 1. 凭证读取 ----
_group "凭证读取 — 默认段"

output=$(read_credentials "default" 2>&1)
rc=$?
assert_exit "默认段读取成功" "$rc" "0"
assert_contains "读到 secret_id" "$output" "AKID_default_id"
assert_contains "读到 secret_key" "$output" "default_key_abc"

_group "凭证读取 — 显式段（含空格）"

output=$(read_credentials "myaccount" 2>&1)
rc=$?
assert_exit "显式段读取成功" "$rc" "0"
assert_contains "读到去空格后的 secret_id" "$output" "AKID_custom_id"
assert_contains "读到去空格后的 secret_key" "$output" "custom_key_xyz"

_group "凭证读取 — 缺失字段"

output=$(read_credentials "broken" 2>&1)
rc=$?
assert_exit "缺失 secret_key 返回失败" "$rc" "1"
assert_contains "提示缺少 secret_key" "$output" "缺少 secret_key"

_group "凭证读取 — 空段"

output=$(read_credentials "empty_section" 2>&1)
rc=$?
assert_exit "空段返回失败" "$rc" "1"
assert_contains "提示未找到字段" "$output" "未找到"

_group "凭证读取 — 不存在的段"

output=$(read_credentials "nonexistent" 2>&1)
rc=$?
assert_exit "不存在的段返回失败" "$rc" "1"

_group "凭证读取 — 配置文件不存在"

old_home="$HOME"
export HOME="$TMPDIR_TEST/no_config_home"
mkdir -p "$HOME"
output=$(read_credentials "default" 2>&1)
rc=$?
assert_exit "文件不存在返回失败" "$rc" "1"
assert_contains "提示文件不存在" "$output" "配置文件不存在"
export HOME="$old_home"

# ---- 2. 环境变量 fallback ----
_group "环境变量 fallback"

# 让配置文件读取失败（不存在的 HOME），强制走环境变量
export HOME="$TMPDIR_TEST/empty_home"
mkdir -p "$HOME"
export TENCENT_SECRET_ID="AKID_env_id"
export TENCENT_SECRET_KEY="env_key_999"

CURL_MOCK_BODY='{"Response":{"Balance":10000,"Credit":5000,"RealBalance":8000,"RequestId":"env-1"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "env fallback 查询成功" "$rc" "0"
assert_contains "env 余额正确" "$output" "￥10000"

unset TENCENT_SECRET_ID TENCENT_SECRET_KEY
export HOME="$old_home"

# ---- 3. 成功响应解析 ----
_group "成功响应解析"

CURL_MOCK_BODY='{"Response":{"Balance":12345,"Credit":6789,"RealBalance":10000,"RequestId":"ok-1"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "成功退出码 0" "$rc" "0"
assert_contains "显示余额" "$output" "￥12345"
assert_contains "显示信用额度" "$output" "￥6789"
assert_contains "显示现金余额" "$output" "￥10000"
assert_contains "显示标题" "$output" "账户余额信息"

# ---- 4. API 错误对象 ----
_group "API 错误对象"

CURL_MOCK_BODY='{"Response":{"Error":{"Code":"AuthFailure.SecretIdNotFound","Message":"The SecretId is not found."},"RequestId":"err-1"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "API 错误退出码非 0" "$rc" "1"
assert_contains "包含错误码" "$output" "AuthFailure.SecretIdNotFound"
assert_contains "包含错误信息" "$output" "SecretId is not found"
assert_not_contains "不显示余额" "$output" "账户余额"

# ---- 5. 非 JSON 响应 ----
_group "非 JSON 响应"

CURL_MOCK_BODY='<html><body>502 Bad Gateway</body></html>'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "非 JSON 退出码非 0" "$rc" "1"
assert_contains "提示非 JSON" "$output" "非 JSON"

# ---- 6. 截断的 JSON ----
_group "截断的 JSON"

CURL_MOCK_BODY='{"Response":{"Balance":1234'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "截断 JSON 退出码非 0" "$rc" "1"
assert_contains "提示非 JSON 或截断" "$output" "非 JSON"

# ---- 7. 缺少 Response 字段 ----
_group "缺少 Response 字段"

CURL_MOCK_BODY='{"some_other_field": true}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "缺少 Response 退出码非 0" "$rc" "1"
assert_contains "提示缺少 Response" "$output" "Response"

# ---- 8. curl 连接失败 ----
_group "curl 连接失败"

CURL_MOCK_BODY=""
CURL_MOCK_CODE="000"
CURL_MOCK_EXIT=7  # curl: couldn't connect to host

output=$(query_balance 2>&1)
rc=$?
assert_exit "连接失败退出码非 0" "$rc" "1"
assert_contains "提示连接失败" "$output" "curl 请求失败"

CURL_MOCK_EXIT=0  # 恢复

# ---- 9. HTTP 500 ----
_group "HTTP 错误状态码"

CURL_MOCK_BODY='{"code":"InternalError"}'
CURL_MOCK_CODE="500"
CURL_MOCK_EXIT=0

output=$(query_balance 2>&1)
rc=$?
assert_exit "HTTP 500 退出码非 0" "$rc" "1"
assert_contains "提示状态码" "$output" "500"

# ---- 10. --section 显式段查询 ----
_group "--section 显式段查询"

CURL_MOCK_BODY='{"Response":{"Balance":99999,"Credit":0,"RealBalance":99999,"RequestId":"sec-1"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance --section myaccount 2>&1)
rc=$?
assert_exit "显式段查询成功" "$rc" "0"
assert_contains "显式段余额" "$output" "￥99999"

# ---- 11. --section 失败不 fallback 到 env ----
_group "--section 失败不 fallback"

export TENCENT_SECRET_ID="AKID_should_not_use"
export TENCENT_SECRET_KEY="should_not_use"

CURL_MOCK_BODY='{"Response":{"Balance":111,"Credit":0,"RealBalance":111,"RequestId":"nope"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(query_balance --section nonexistent 2>&1)
rc=$?
assert_exit "显式段失败退出码非 0" "$rc" "1"
assert_contains "提示段未找到" "$output" "未找到"
assert_not_contains "不使用 env 凭证" "$output" "￥111"

unset TENCENT_SECRET_ID TENCENT_SECRET_KEY

# ---- 12. handle_command 适配 ----
_group "handle_command 适配 (bin/cloud)"

CURL_MOCK_BODY='{"Response":{"Balance":55555,"Credit":1000,"RealBalance":54000,"RequestId":"hc-1"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(handle_command "balance" 2>&1)
rc=$?
assert_exit "handle_command balance 成功" "$rc" "0"
assert_contains "handle_command 余额" "$output" "￥55555"

output=$(handle_command "unknown_cmd" 2>&1)
rc=$?
assert_exit "handle_command 未知命令返回失败" "$rc" "1"
assert_contains "提示可用命令" "$output" "balance"

# ---- 13. debug 模式 ----
_group "DEBUG 模式"

CURL_MOCK_BODY='{"Response":{"Balance":777,"Credit":0,"RealBalance":777,"RequestId":"dbg-1"}}'
CURL_MOCK_CODE="200"
CURL_MOCK_EXIT=0

output=$(DEBUG=true query_balance 2>&1)
rc=$?
assert_exit "DEBUG 模式查询成功" "$rc" "0"
assert_contains "DEBUG 输出包含签名信息" "$output" "Authorization"
assert_contains "DEBUG 输出包含余额" "$output" "￥777"

# =====================================================================
#  汇总
# =====================================================================
echo ""
echo "======================================"
_TOTAL=$((_PASS + _FAIL))
if [[ $_FAIL -eq 0 ]]; then
    echo "  结果: ${_PASS} 通过 / 共 ${_TOTAL} — 全部通过 ✓"
else
    echo "  结果: ${_PASS} 通过, ${_FAIL} 失败 / 共 ${_TOTAL}"
fi
echo "======================================"
echo ""

[[ $_FAIL -eq 0 ]] && exit 0 || exit 1
