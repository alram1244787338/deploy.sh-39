#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# 导入被测试的脚本, 但不执行 main 函数
eval "$(sed 's/main "$@"//g' "$(dirname "$0")/child.sh")"

# 测试辅助函数
_assert() {
    local condition=$1
    local message=$2
    if ! eval "$condition"; then
        echo "❌ 测试失败: $message"
        echo "条件: $condition"
        return 1
    else
        echo "✅ 测试通过: $message"
        return 0
    fi
}

_setup() {
    # 固定脚本路径/名称, 让被测脚本读写到测试可预期的 .status 文件
    SCRIPT_PATH=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
    SCRIPT_NAME="child.sh"
    SCRIPT_LOG="${SCRIPT_PATH}/${SCRIPT_NAME}.log"
    file_status="${SCRIPT_PATH}/${SCRIPT_NAME}.status"
    debug_mod=1

    # 清理可能残留的状态文件(含历史 .play/.rest 旧格式)与日志
    rm -f "${SCRIPT_PATH}/${SCRIPT_NAME}".{status,play,rest}
    rm -f "${SCRIPT_LOG}"

    # 创建初始单一状态文件(play_time + rest_time 同一份)
    {
        echo "play_time=2024-01-01 12:00:00"
        echo "rest_time=2024-01-01 10:00:00"
    } >"${file_status}"
    chmod 644 "${file_status}"

    # 模拟系统命令
    sudo() { echo "MOCK: sudo $*"; }
    poweroff() { echo "MOCK: poweroff"; }
    shutdown() { echo "MOCK: shutdown $*"; }

    # 默认不触发远程关机(注意: 真实函数名为 _remote_trigger)
    _remote_trigger() { return 1; }

    # 以 type(play/rest) 区分返回值, 与被测脚本 _get_minutes_elapsed type file 的签名一致
    _get_minutes_elapsed() {
        local type=$1
        if [[ ${type} == "play" ]]; then
            echo "${MOCK_PLAY_TIME:-30}"
        else
            echo "${MOCK_REST_TIME:-150}"
        fi
    }

    # 可控的 date 模拟: 能正确接受合法时间、拒绝非法时间, 让脏数据修复逻辑被真实触发
    date() {
        local dval="" out=""
        while (($#)); do
            case "$1" in
            -d)
                dval="$2"
                shift 2
                continue
                ;;
            +%s) out="epoch" ;;
            +%H) out="hour" ;;
            +%u) out="weekday" ;;
            +%F_%T) out="fdt_us" ;;
            "+%F %T") out="fdt_sp" ;;
            esac
            shift
        done

        case "${out}" in
        hour) echo "${MOCK_HOUR:-12}" ;;
        weekday) echo "${MOCK_WEEKDAY:-6}" ;;
        fdt_us) echo "2024-01-01_${MOCK_HOUR:-12}:00:00" ;;
        fdt_sp)
            if [[ -n ${dval} ]]; then
                echo "2024-01-01 10:00:00" # 任意合法的过去时间(用于 "N minutes ago")
            else
                echo "2024-01-01 ${MOCK_HOUR:-12}:00:00"
            fi
            ;;
        *)
            if [[ -n ${dval} ]]; then
                if [[ ${dval} == *"minutes ago"* ]] ||
                    [[ ${dval} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
                    echo "1704028800"
                    return 0
                fi
                return 1 # 非法时间字符串 -> 校验失败
            fi
            echo "${MOCK_TIMESTAMP:-1704028800}"
            ;;
        esac
    }
}

_teardown() {
    rm -f "${SCRIPT_PATH}/${SCRIPT_NAME}".{status,play,rest}
    rm -f "${SCRIPT_LOG}"
}

test_night_time_limit() {
    _setup
    debug_mod=1

    # 创建临时目录和假的 date 命令(走真实二进制, 验证十进制小时解析)
    local temp_dir
    temp_dir=$(mktemp -d)
    cat >"${temp_dir}/date" <<'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "23";;  # 晚上11点
    +%u) echo "6";;   # 周六
    +%F_%T) echo "2024-01-01_23:00:00";;
    +%F" "%T) echo "2024-01-01 23:00:00";;
    +%s)
        if [[ $* == *"-d"* ]]; then
            echo "1704067200"
        else
            echo "1704067200"
        fi
        ;;
    *) echo "2024-01-01 23:00:00";;
esac
EOF
    chmod +x "${temp_dir}/date"

    export PATH="${temp_dir}:$PATH"
    unset -f date

    local date_path
    date_path=$(which date)
    if [[ ${date_path} != "${temp_dir}/date" ]]; then
        echo "错误: 使用了错误的date命令: ${date_path}"
        rm -rf "${temp_dir}"
        return 1
    fi

    output=$(_check_time_limits 2>&1)
    echo "测试输出: ${output}"

    _assert "[[ \"${output}\" == *'禁止使用时间段'* ]]" "应该触发夜间时间限制" || {
        rm -rf "${temp_dir}"
        return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

test_workday_time_limit() {
    _setup
    debug_mod=1

    local temp_dir
    temp_dir=$(mktemp -d)
    cat >"${temp_dir}/date" <<'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "18";;  # 晚上6点
    +%u) echo "3";;   # 周三
    +%F_%T) echo "2024-01-01_18:00:00";;
    +%F" "%T) echo "2024-01-01 18:00:00";;
    +%s)
        if [[ $* == *"-d"* ]]; then
            echo "1704049200"
        else
            echo "1704049200"
        fi
        ;;
    *) echo "2024-01-01 18:00:00";;
esac
EOF
    chmod +x "${temp_dir}/date"

    export PATH="${temp_dir}:$PATH"
    unset -f date

    local date_path
    date_path=$(which date)
    if [[ ${date_path} != "${temp_dir}/date" ]]; then
        echo "错误: 使用了错误的date命令: ${date_path}"
        rm -rf "${temp_dir}"
        return 1
    fi

    output=$(_check_time_limits 2>&1)
    echo "测试输出: ${output}"

    _assert "[[ \"${output}\" == *'工作日17点后'* ]]" "应该触发工作日时间限制" || {
        rm -rf "${temp_dir}"
        return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

# 周五晚上不应触发工作日限制(脚本原意: 周五及周末放宽)
test_friday_not_limited() {
    _setup
    MOCK_HOUR=18
    MOCK_WEEKDAY=5 # 周五
    debug_mod=1

    output=$(_check_time_limits 2>&1)
    local rc=$?
    echo "测试输出: ${output} (rc=${rc})"

    _assert "[[ ${rc} -eq 0 ]]" "周五18点不应被工作日限制拦截"
    _teardown
}

# 早上 08 点不应因八进制解析而出错, 且属于允许时段
test_morning_octal_hour() {
    _setup
    MOCK_HOUR=08
    MOCK_WEEKDAY=6
    debug_mod=1

    output=$(_check_time_limits 2>&1)
    local rc=$?
    echo "测试输出: ${output} (rc=${rc})"

    _assert "[[ ${rc} -eq 0 ]]" "08点应被正确解析为允许时段(无八进制报错)"
    _assert "[[ \"${output}\" != *'value too great'* ]]" "不应出现八进制解析错误"
    _teardown
}

test_play_time_limit() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    MOCK_PLAY_TIME=60  # 开机60分钟
    MOCK_REST_TIME=150 # 休息150分钟
    debug_mod=1

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    _assert "[[ \"${output}\" == *'开机时间超过'* ]]" "应该触发开机时间限制"
    _teardown
}

test_rest_time_limit() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    MOCK_PLAY_TIME=0  # 刚开机
    MOCK_REST_TIME=30 # 休息30分钟(不足)
    debug_mod=1

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    _assert "[[ \"${output}\" == *'距离上次关机未满'* ]]" "应该触发休息时间限制"
    _teardown
}

test_remote_trigger() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 模拟远程触发(覆盖默认的 _remote_trigger)
    _remote_trigger() {
        _do_shutdown "收到远程关机命令"
        return 0
    }

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    _assert "[[ \"${output}\" == *'收到远程关机命令'* ]]" "应该触发远程关机"
    _teardown
}

# 远程触发命中后, 不应再被休息/开机分支覆盖(只输出远程关机原因)
test_remote_trigger_not_overridden() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    MOCK_PLAY_TIME=0
    MOCK_REST_TIME=0 # 即便休息严重不足, 也应优先远程触发并立即返回
    debug_mod=1

    _remote_trigger() {
        _do_shutdown "收到远程关机命令"
        return 0
    }

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    _assert "[[ \"${output}\" == *'收到远程关机命令'* ]]" "应优先命中远程关机"
    _assert "[[ \"${output}\" != *'距离上次关机未满'* ]]" "远程关机后不应再触发休息时间分支"
    _teardown
}

test_reset_command() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 确保状态文件存在
    {
        echo "play_time=2024-01-01 12:00:00"
        echo "rest_time=2024-01-01 10:00:00"
    } >"${file_status}"
    chmod 644 "${file_status}"

    if [[ ! -f ${file_status} ]]; then
        echo "测试前状态文件不存在"
        return 1
    fi

    main reset
    sync

    _assert "[[ ! -f ${file_status} ]]" "reset 应该删除状态文件"
    _teardown
}

test_update_play_time() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    MOCK_PLAY_TIME=150 # 开机时长达到一个完整休息周期
    MOCK_REST_TIME=150 # 休息充分, 不触发休息分支
    debug_mod=1

    # 启动时间早于当前(模拟需要被重置)
    {
        echo "play_time=2024-01-01 09:00:00"
        echo "rest_time=2024-01-01 10:00:00"
    } >"${file_status}"

    main debug

    local current_play_time
    current_play_time=$(_read_status_field "play_time" "${file_status}")
    echo "更新后的启动时间: ${current_play_time}"
    _assert "[[ \"${current_play_time}\" != '2024-01-01 09:00:00' ]]" "应该更新启动时间"
    _teardown
}

# 状态文件不存在时应被创建, 且含合法的 play_time / rest_time
test_file_creation() {
    _setup

    # 禁用其他检查, 仅验证初始化
    _remote_trigger() { return 1; }
    _check_time_limits() { return 0; }
    _get_minutes_elapsed() { echo "150"; }

    rm -f "${file_status}"

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    sync

    _assert "[[ -f ${file_status} ]]" "应该创建状态文件"

    if [[ -f ${file_status} ]]; then
        local play_content rest_content
        play_content=$(_read_status_field "play_time" "${file_status}")
        rest_content=$(_read_status_field "rest_time" "${file_status}")
        echo "play_time=${play_content}"
        echo "rest_time=${rest_content}"
        _assert "date -d \"${play_content}\" +%s >/dev/null 2>&1" "play_time 格式应该正确"
        _assert "date -d \"${rest_content}\" +%s >/dev/null 2>&1" "rest_time 格式应该正确"
    fi

    _teardown
}

# 状态文件中时间格式脏掉时, 应被真实的修复逻辑改写为合法值
test_invalid_time_format() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 写入非法的 play_time, rest_time 合法
    {
        echo "play_time=invalid time"
        echo "rest_time=2024-01-01 10:00:00"
    } >"${file_status}"

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    sync

    local play_content
    play_content=$(_read_status_field "play_time" "${file_status}")
    echo "修复后的 play_time: ${play_content}"
    _assert "[[ -n \"${play_content}\" && \"${play_content}\" != 'invalid time' ]]" "非法时间应被改写"
    _assert "date -d \"${play_content}\" +%s >/dev/null 2>&1" "改写后的 play_time 格式应该正确"

    _teardown
}

# 运行所有测试
run_all_tests() {
    local failed=0
    local total=0
    local test_result=0

    echo "开始运行测试..."
    echo "===================="

    for test_func in $(declare -F | grep "^declare -f test_" | cut -d" " -f3); do
        ((total++))
        echo "🧪 运行测试: ${test_func}"
        if ! $test_func; then
            ((failed++))
            test_result=1
        fi
        echo "--------------------"
    done

    echo "===================="
    echo "测试完成: 总共 ${total} 个测试, 失败 ${failed} 个"

    return $test_result
}

# 如果直接运行此脚本, 则执行所有测试
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
