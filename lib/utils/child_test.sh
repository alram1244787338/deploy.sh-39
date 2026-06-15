#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# 导入被测试的脚本，但不执行main函数
eval "$(sed 's/main "$@"//g' "$(dirname "$0")/child.sh")"

# 测试辅助函数
_assert_failures=0

_assert() {
    local condition=$1
    local message=$2
    # 将条件中的 ${output} 占位展开时可能含换行，会导致 [[ ]] 语法错误
    # 因此先在当前作用域把 output 的换行替换为空格
    local output_flat="${output//$'\n'/ }"
    # 把条件字符串里的 ${output} 替换为已展平的值
    local safe_condition="${condition//\$\{output\}/\$\{output_flat\}}"
    if ! eval "$safe_condition"; then
        echo "❌ 测试失败: $message"
        echo "条件: $condition"
        ((_assert_failures++))
        return 1
    else
        echo "✅ 测试通过: $message"
        return 0
    fi
}

_setup() {
    # 使用脚本所在目录
    SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
    SCRIPT_NAME="child.sh"
    SCRIPT_LOG="${SCRIPT_PATH}/${SCRIPT_NAME}.log"
    file_status="${SCRIPT_PATH}/${SCRIPT_NAME}.status"
    debug_mod=1

    # 清除上一个测试遗留的函数覆盖
    unset -f _check_time_limits _get_minutes_elapsed _remote_trigger date 2>/dev/null || true

    # 重新加载原始函数定义
    eval "$(sed 's/main "$@"//g' "$(dirname "$0")/child.sh")"

    # 删除旧文件
    rm -f "${file_status}" "${SCRIPT_LOG}"
    rm -f "${SCRIPT_PATH}/${SCRIPT_NAME}".{play,rest}

    # 创建初始 .status 文件（格式与主脚本一致）
    {
        echo "play_time=2024-01-01 12:00:00"
        echo "rest_time=2024-01-01 10:00:00"
    } > "${file_status}"
    chmod 644 "${file_status}"

    # 模拟系统命令
    sudo() { echo "MOCK: sudo $*"; }
    poweroff() { echo "MOCK: poweroff"; }
    shutdown() { echo "MOCK: shutdown $*"; }

    # 默认不触发远程关机（curl 返回的内容不含 "rest"）
    curl() { echo "no_trigger"; }

    # 覆盖时间计算函数
    _get_minutes_elapsed() {
        local type=$1
        if [[ ${type} == "play" ]]; then
            echo "${MOCK_PLAY_TIME:-30}"
        else
            echo "${MOCK_REST_TIME:-150}"
        fi
    }

    # 覆盖 date 函数（处理所有主脚本用到的格式）
    # 注意：case 分支优先级很重要，*+%s* 必须在 -d* 之前，否则
    # date -d "time" +%s 会被 -d* 匹配而返回日期字符串而非数字时间戳
    date() {
        case "$*" in
            +%H)
                echo "${MOCK_HOUR:-12}"
                ;;
            +%u)
                echo "${MOCK_WEEKDAY:-6}"
                ;;
            +%F_%T)
                echo "2024-01-01_${MOCK_HOUR:-12}:00:00"
                ;;
            *+%s*)
                # 所有含 +%s 的调用都返回数字时间戳
                if [[ $* == *"-d"* ]]; then
                    local time_str
                    time_str=$(echo "$*" | sed 's/.*-d //' | tr -d '"')
                    local hour_part
                    hour_part=$(echo "${time_str}" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | cut -d: -f1)
                    if [[ -n ${hour_part} ]]; then
                        echo $(( ${MOCK_TIMESTAMP:-1704028800} + (${hour_part#0} - 12) * 3600 ))
                    else
                        echo "${MOCK_TIMESTAMP:-1704028800}"
                    fi
                else
                    echo "${MOCK_TIMESTAMP:-1704028800}"
                fi
                ;;
            -d*)
                echo "2024-01-01 ${MOCK_HOUR:-12}:00:00"
                ;;
            *+%F*%T*|*"%F %T"*)
                echo "2024-01-01 ${MOCK_HOUR:-12}:00:00"
                ;;
            *)
                echo "2024-01-01 ${MOCK_HOUR:-12}:00:00"
                ;;
        esac
    }
}

_teardown() {
    rm -f "${file_status}" "${SCRIPT_LOG}"
    rm -f "${SCRIPT_PATH}/${SCRIPT_NAME}".{play,rest}
    unset -f _check_time_limits _get_minutes_elapsed _remote_trigger date 2>/dev/null || true
}

# ==================== 时间窗口测试（PATH-based date mock） ====================

test_night_time_limit() {
    _setup
    debug_mod=1

    local temp_dir
    temp_dir=$(mktemp -d)
    cat > "${temp_dir}/date" << 'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "23";;
    +%u) echo "6";;
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

    _get_minutes_elapsed() { echo "150"; }

    export PATH="${temp_dir}:$PATH"
    unset -f date

    output=$(_check_time_limits 2>&1)
    echo "测试输出: ${output}"

    _assert "[[ \"${output}\" == *'夜间'* ]]" "23时应该触发夜间时间限制" || {
        rm -rf "${temp_dir}"; return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

test_workday_time_limit() {
    _setup
    debug_mod=1

    local temp_dir
    temp_dir=$(mktemp -d)
    cat > "${temp_dir}/date" << 'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "18";;
    +%u) echo "3";;
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

    _get_minutes_elapsed() { echo "150"; }

    export PATH="${temp_dir}:$PATH"
    unset -f date

    output=$(_check_time_limits 2>&1)
    echo "测试输出: ${output}"

    _assert "[[ \"${output}\" == *'工作日'* ]]" "周三18时应该触发工作日时间限制" || {
        rm -rf "${temp_dir}"; return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

test_workday_friday_17_boundary() {
    _setup
    debug_mod=1

    local temp_dir
    temp_dir=$(mktemp -d)
    cat > "${temp_dir}/date" << 'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "17";;
    +%u) echo "5";;
    +%F_%T) echo "2024-01-01_17:00:00";;
    +%F" "%T) echo "2024-01-01 17:00:00";;
    +%s) echo "1704045600";;
    *) echo "2024-01-01 17:00:00";;
esac
EOF
    chmod +x "${temp_dir}/date"

    export PATH="${temp_dir}:$PATH"
    unset -f date

    output=$(_check_time_limits 2>&1)
    echo "测试输出: ${output}"

    _assert "[[ \"${output}\" == *'工作日'* ]]" "周五17:00应该触发工作日限制" || {
        rm -rf "${temp_dir}"; return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

test_friday_16_allowed() {
    _setup
    debug_mod=1

    local temp_dir
    temp_dir=$(mktemp -d)
    cat > "${temp_dir}/date" << 'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "16";;
    +%u) echo "5";;
    +%F_%T) echo "2024-01-01_16:00:00";;
    +%F" "%T) echo "2024-01-01 16:00:00";;
    +%s) echo "1704042000";;
    *) echo "2024-01-01 16:00:00";;
esac
EOF
    chmod +x "${temp_dir}/date"

    export PATH="${temp_dir}:$PATH"
    unset -f date

    _check_time_limits
    local rc=$?
    echo "返回码: ${rc}"

    _assert "[[ ${rc} -eq 0 ]]" "周五16时应该允许使用" || {
        rm -rf "${temp_dir}"; return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

test_weekend_18_allowed() {
    _setup
    debug_mod=1

    local temp_dir
    temp_dir=$(mktemp -d)
    cat > "${temp_dir}/date" << 'EOF'
#!/bin/bash
case "$1" in
    +%H) echo "18";;
    +%u) echo "6";;
    +%F_%T) echo "2024-01-01_18:00:00";;
    +%F" "%T) echo "2024-01-01 18:00:00";;
    +%s) echo "1704049200";;
    *) echo "2024-01-01 18:00:00";;
esac
EOF
    chmod +x "${temp_dir}/date"

    export PATH="${temp_dir}:$PATH"
    unset -f date

    _check_time_limits
    local rc=$?
    echo "返回码: ${rc}"

    _assert "[[ ${rc} -eq 0 ]]" "周六18时应该允许使用" || {
        rm -rf "${temp_dir}"; return 1
    }

    rm -rf "${temp_dir}"
    _teardown
}

# ==================== 主要关机分支测试 ====================

test_play_time_limit() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    MOCK_PLAY_TIME=60   # 开机60分钟
    MOCK_REST_TIME=150  # 关机150分钟
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
    MOCK_PLAY_TIME=0    # 刚开机
    MOCK_REST_TIME=30   # 关机才30分钟
    debug_mod=1

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    _assert "[[ \"${output}\" == *'距离上次关机未满'* ]]" "应该触发休息时间不足限制"
    _teardown
}

test_remote_trigger() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 覆盖远程触发函数
    _remote_trigger() {
        _do_shutdown "收到远程关机命令"
        return 0
    }

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    _assert "[[ \"${output}\" == *'收到远程关机命令'* ]]" "应该触发远程关机"
    _teardown
}

# ==================== 状态文件测试 ====================

test_reset_command() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 确认文件存在
    if [[ ! -f ${file_status} ]]; then
        echo "测试前文件不存在"
        return 1
    fi

    # 执行 reset
    main reset
    sync

    _assert "[[ ! -f ${file_status} ]]" "reset 应该删除 .status 文件"

    _teardown
}

test_status_file_init() {
    _setup

    # 删除 .status 文件以测试首次初始化
    rm -f "${file_status}"

    # 覆盖检查函数，隔离初始化逻辑
    _check_time_limits() { return 0; }
    _get_minutes_elapsed() { echo "150"; }
    _remote_trigger() { return 1; }

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"
    sync

    _assert "[[ -f ${file_status} ]]" "应该创建 .status 文件"

    if [[ -f ${file_status} ]]; then
        local content
        content=$(cat "${file_status}")
        echo "状态文件内容: ${content}"

        _assert "[[ \"${content}\" == *'play_time='* ]]" ".status 应包含 play_time"
        _assert "[[ \"${content}\" == *'rest_time='* ]]" ".status 应包含 rest_time"
    fi

    _teardown
}

test_update_play_time() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 设置启动时间早于当前时间（超过 REST_MINUTES=120 分钟）
    echo "play_time=2024-01-01 09:00:00" > "${file_status}"
    echo "rest_time=2024-01-01 10:00:00" >> "${file_status}"

    MOCK_PLAY_TIME=180  # 开机已超过 120 分钟
    MOCK_REST_TIME=150  # 关机已超过 120 分钟

    main debug
    sync

    current_play_time=$(awk -F= '/^play_time=/{print $2}' "${file_status}")
    echo "更新后的 play_time: ${current_play_time}"

    _assert "[[ \"${current_play_time}\" != '2024-01-01 09:00:00' ]]" "play_elapsed >= 120 时应该更新启动时间"

    _teardown
}

test_invalid_time_format_recovery() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 写入无效的时间格式
    {
        echo "play_time=invalid_time"
        echo "rest_time=also_invalid"
    } > "${file_status}"

    # 使用原始 _get_minutes_elapsed（不用 mock），让它遇到无效格式时返回 1
    unset -f _get_minutes_elapsed
    eval "$(sed -n '/^_get_minutes_elapsed/,/^}/p' "$(dirname "$0")/child.sh")"

    # 原始 _validate_time_format 依赖 date -d，在 macOS 上 date mock 的 *+%s*
    # 分支会对任何输入返回数字时间戳，导致验证不会失败。
    # 因此额外覆盖 _validate_time_format 来模拟真实的验证行为。
    _validate_time_format() {
        local time_str=$1
        if [[ ${time_str} == *"invalid"* ]] || [[ ${time_str} == *"also_invalid"* ]]; then
            return 1
        fi
        return 0
    }

    output=$({ main debug; } 2>&1)
    echo "测试输出: ${output}"

    _assert "[[ \"${output}\" == *'无法获取'* || \"${output}\" == *'无效的时间格式'* ]]" "无效时间格式应被检测到并记录"

    _teardown
}

test_status_file_format() {
    _setup
    MOCK_HOUR=12
    MOCK_WEEKDAY=6
    debug_mod=1

    # 验证正常 .status 文件的格式可被 _get_minutes_elapsed 正确解析
    {
        echo "play_time=2024-01-01 12:00:00"
        echo "rest_time=2024-01-01 10:00:00"
    } > "${file_status}"

    # 使用原始 _get_minutes_elapsed
    unset -f _get_minutes_elapsed
    eval "$(sed -n '/^_get_minutes_elapsed/,/^}/p' "$(dirname "$0")/child.sh")"

    local play_result rest_result
    play_result=$(_get_minutes_elapsed "play" "${file_status}" 2>/dev/null)
    rest_result=$(_get_minutes_elapsed "rest" "${file_status}" 2>/dev/null)

    echo "play_elapsed: ${play_result}, rest_elapsed: ${rest_result}"

    _assert "[[ -n \"${play_result}\" ]]" "play_time 应该能被正确解析"
    _assert "[[ -n \"${rest_result}\" ]]" "rest_time 应该能被正确解析"

    _teardown
}

# ==================== 测试运行器 ====================

run_all_tests() {
    local total=0
    local test_result=0

    echo "开始运行测试..."
    echo "===================="

    for test_func in $(declare -F | grep "^declare -f test_" | cut -d" " -f3); do
        ((total++))
        echo "🧪 运行测试: ${test_func}"
        local before_failures=${_assert_failures}
        $test_func
        if [[ ${_assert_failures} -gt ${before_failures} ]]; then
            test_result=1
        fi
        echo "--------------------"
    done

    echo "===================="
    echo "测试完成: 总共 ${total} 个测试，失败 ${_assert_failures} 个断言"

    return $test_result
}

# 如果直接运行此脚本，则执行所有测试
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
