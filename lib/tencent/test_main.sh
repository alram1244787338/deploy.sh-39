#!/bin/bash
# -*- coding: utf-8 -*-
#
# 离线验证 lib/tencent/main.sh：通过 source 引入函数，并用 stub 替换
# _send_billing_request，从而在不访问腾讯云接口的前提下复现
# 成功 / 接口报错 / 非 JSON / 半截 JSON / 空响应 / 传输失败 等路径，
# 同时覆盖凭证文件多配置段解析、容错与环境变量回退。
#
# 用法： bash lib/tencent/test_main.sh
# 退出码：全部通过 0，存在失败 1。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引入被测函数（main.sh 被 source 时不会自动执行 query_balance）
# shellcheck source=/dev/null
source "$SCRIPT_DIR/main.sh"

PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; shift; for m in "$@"; do printf '       %s\n' "$m"; done; }

assert_eq()           { [[ "$2" == "$3" ]] && ok "$1" || ng "$1" "期望: <$2>" "实际: <$3>"; }
assert_contains()     { [[ "$2" == *"$3"* ]] && ok "$1" || ng "$1" "期望包含: <$3>" "实际: <$2>"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && ok "$1" || ng "$1" "期望不包含: <$3>" "实际: <$2>"; }

# 捕获命令的 stdout / stderr / 返回码到 OUT / ERR / RC
capture() {
    local errf; errf=$(mktemp)
    OUT=$("$@" 2>"$errf"); RC=$?
    ERR=$(cat "$errf"); rm -f "$errf"
}

# ---- 准备凭证 fixture：含注释、空行、空格、缺字段等容错场景 ----
FIX=$(mktemp)
cat > "$FIX" <<'EOF'
# 这是注释
; 另一种注释

[default]
secret_id = AKID_DEFAULT
secret_key = KEY_DEFAULT

[prod]
   secret_id=AKID_PROD
secret_key =    KEY_PROD

[broken]
secret_id = AKID_ONLY
EOF

echo "=== 1. 凭证文件解析与容错 ==="

export TENCENT_CREDENTIALS_FILE="$FIX"
unset TENCENT_SECRET_ID TENCENT_SECRET_KEY

creds=$(read_credentials default); rc=$?
assert_eq "default 段返回码为 0" "0" "$rc"
assert_eq "default 段密钥解析正确" "AKID_DEFAULT	KEY_DEFAULT" "$creds"

creds=$(read_credentials prod); rc=$?
assert_eq "prod 段返回码为 0" "0" "$rc"
assert_eq "prod 段能去除多余空格/缩进" "AKID_PROD	KEY_PROD" "$creds"

read_credentials broken >/dev/null; rc=$?
assert_eq "缺字段段返回码为 4" "4" "$rc"
assert_contains "缺字段提示点名 secret_key" "$CRED_ERR" "secret_key"
assert_contains "缺字段提示点名所在段" "$CRED_ERR" "[broken]"

read_credentials nosuch >/dev/null; rc=$?
assert_eq "配置段不存在返回码为 3" "3" "$rc"
assert_contains "不存在段提示点名段名" "$CRED_ERR" "[nosuch]"

TENCENT_CREDENTIALS_FILE="/no/such/credentials/file" read_credentials default >/dev/null; rc=$?
assert_eq "文件不存在返回码为 2" "2" "$rc"

echo "=== 2. 显式 section 与环境变量回退 ==="

# 文件读不到时回退环境变量并成功
export TENCENT_CREDENTIALS_FILE="/no/such/credentials/file"
export TENCENT_SECRET_ID="ENV_ID"
export TENCENT_SECRET_KEY="ENV_KEY"
_send_billing_request() { printf '%s' '{"Response":{"Balance":1,"Credit":2,"RealBalance":3,"RequestId":"r"}}'; return 0; }
capture query_balance default
assert_eq "环境变量回退后查询成功返回码为 0" "0" "$RC"
assert_contains "环境变量回退后输出余额" "$OUT" "账户余额信息"
assert_eq "环境变量回退成功时 stderr 为空" "" "$ERR"

# 文件与环境变量都缺：统一、可读的失败提示
export TENCENT_CREDENTIALS_FILE="/no/such/credentials/file"
unset TENCENT_SECRET_ID TENCENT_SECRET_KEY
capture query_balance default
assert_eq "两种来源都缺时返回码为 1" "1" "$RC"
assert_contains "失败提示说明未取到密钥" "$ERR" "未能获取到有效的密钥信息"
assert_contains "失败提示包含凭证文件原因" "$ERR" "凭证文件"
assert_contains "失败提示包含环境变量指引" "$ERR" "环境变量"
assert_not_contains "失败时不输出余额块" "$OUT" "账户余额信息"

echo "=== 3. 响应处理（stub 注入，不访问真实接口）==="

# 使用合法凭证文件，越过取密钥阶段，专注响应分支
export TENCENT_CREDENTIALS_FILE="$FIX"
unset TENCENT_SECRET_ID TENCENT_SECRET_KEY

# 3a. 成功响应
_send_billing_request() { printf '%s' '{"Response":{"Balance":10000,"Credit":5000,"RealBalance":9999,"RequestId":"req-1"}}'; return 0; }
capture query_balance default
assert_eq "成功响应返回码为 0" "0" "$RC"
assert_contains "成功响应展示账户余额" "$OUT" "账户余额：￥10000"
assert_contains "成功响应展示现金余额" "$OUT" "现金余额：￥9999"
assert_eq "成功响应 stderr 为空" "" "$ERR"

# 3b. 接口返回错误对象
_send_billing_request() { printf '%s' '{"Response":{"Error":{"Code":"AuthFailure.SignatureFailure","Message":"签名校验失败"},"RequestId":"req-2"}}'; return 0; }
capture query_balance default
assert_eq "接口错误返回码为 1" "1" "$RC"
assert_contains "接口错误透出错误码" "$ERR" "AuthFailure.SignatureFailure"
assert_contains "接口错误透出错误信息" "$ERR" "签名校验失败"
assert_not_contains "接口错误时不输出余额块" "$OUT" "账户余额信息"

# 3c. 非 JSON 响应（模拟 verbose 日志/被拦截等混入的情况）
_send_billing_request() { printf '%s' '* Trying 1.2.3.4...
< HTTP/1.1 200 OK
这不是 JSON'; return 0; }
capture query_balance default
assert_eq "非 JSON 响应返回码为 1" "1" "$RC"
assert_contains "非 JSON 响应落到统一错误路径" "$ERR" "不是合法的 JSON"
assert_not_contains "非 JSON 响应时不输出余额块" "$OUT" "账户余额信息"

# 3d. 半截 JSON（截断的内容）
_send_billing_request() { printf '%s' '{"Response":{"Balance":100'; return 0; }
capture query_balance default
assert_eq "半截 JSON 返回码为 1" "1" "$RC"
assert_contains "半截 JSON 落到统一错误路径" "$ERR" "不是合法的 JSON"

# 3e. 空响应
_send_billing_request() { printf ''; return 0; }
capture query_balance default
assert_eq "空响应返回码为 1" "1" "$RC"
assert_contains "空响应给出可读提示" "$ERR" "未返回任何内容"

# 3f. 传输失败（curl 非 0 退出码）
_send_billing_request() { printf ''; return 7; }
capture query_balance default
assert_eq "传输失败返回码为 1" "1" "$RC"
assert_contains "传输失败提示网络/传输错误" "$ERR" "网络或传输错误"
assert_contains "传输失败带出 curl 退出码" "$ERR" "退出码 7"

echo "=== 4. DEBUG 模式不污染正常 stdout ==="

_send_billing_request() { printf '%s' '{"Response":{"Balance":10000,"Credit":5000,"RealBalance":9999}}'; return 0; }
capture env DEBUG=true bash -c 'source "'"$SCRIPT_DIR"'/main.sh"; _send_billing_request(){ printf "%s" "{\"Response\":{\"Balance\":10000,\"Credit\":5000,\"RealBalance\":9999}}"; return 0; }; TENCENT_CREDENTIALS_FILE="'"$FIX"'" query_balance default'
assert_eq "DEBUG 模式仍正常返回 0" "0" "$RC"
assert_contains "DEBUG 模式 stdout 仍是余额结果" "$OUT" "账户余额：￥10000"
assert_not_contains "DEBUG 细节不混入 stdout" "$OUT" "String to Sign"
assert_contains "DEBUG 细节出现在 stderr" "$ERR" "String to Sign"

rm -f "$FIX"

echo "================================"
printf "结果：通过 %d，失败 %d\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
