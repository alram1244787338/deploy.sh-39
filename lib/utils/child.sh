#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# 默认配置(允许通过环境变量覆盖, 便于测试; 生产环境保持原有默认值)
: "${PLAY_MINUTES:=50}"
: "${REST_MINUTES:=120}"
: "${WORK_HOUR_8:=8}"
: "${WORK_HOUR_17:=17}"
: "${WORK_HOUR_21:=21}"
: "${DELAY_SECONDS:=60}"
: "${URL_HOST:=http://192.168.5.1}"

# 函数定义
_log() {
    local msg
    msg="[$(date +%F_%T)] $*"
    if [[ ${debug_mod:-0} == 1 ]]; then
        echo "${msg}" >&2
    else
        echo "${msg}" >>"${SCRIPT_LOG}"
    fi
}

# 校验时间字符串能否被 date 解析; 静默返回 0(有效)/1(无效)
_validate_time_format() {
    local time_str=$1
    [[ -n ${time_str} ]] || return 1
    date -d "${time_str}" +%s >/dev/null 2>&1
}

# 从状态文件读取指定字段的值(play_time / rest_time)
_read_status_field() {
    local key=$1 file=$2
    awk -F= -v k="${key}" '$1 == k {print substr($0, length(k) + 2); exit}' "${file}"
}

# 以可移植方式写入/更新状态文件字段(不依赖 sed -i, 兼容 macOS 与 Linux)
_set_status_field() {
    local key=$1 value=$2 file=$3 tmp
    tmp=$(mktemp)
    if [[ -f ${file} ]] && grep -q "^${key}=" "${file}"; then
        awk -F= -v k="${key}" -v v="${value}" '$1 == k {print k "=" v; next} {print}' "${file}" >"${tmp}"
    else
        [[ -f ${file} ]] && cat "${file}" >"${tmp}"
        echo "${key}=${value}" >>"${tmp}"
    fi
    mv "${tmp}" "${file}"
}

# 计算距离指定时间(play/rest)已过去的分钟数
_get_minutes_elapsed() {
    local type=$1 file=$2
    local time_str current_time time_seconds

    if [[ ${type} == "play" ]]; then
        time_str=$(_read_status_field "play_time" "${file}")
    else
        time_str=$(_read_status_field "rest_time" "${file}")
    fi

    if ! _validate_time_format "${time_str}"; then
        _log "无效的时间格式(${type}): ${time_str}"
        echo 0
        return 1
    fi

    current_time=$(date +%s)
    time_seconds=$(date +%s -d "${time_str}")
    echo $(((current_time - time_seconds) / 60))
}

# 初始化状态文件: 不存在则创建; 存在则校验并修复脏掉的字段
_ensure_status_file() {
    local file=$1
    local play rest

    if [[ ! -f ${file} ]]; then
        {
            echo "play_time=$(date +"%F %T")"
            # 首次运行视为已休息充分, 多留 1 分钟避免整除边界误判
            echo "rest_time=$(date -d "$((REST_MINUTES + 1)) minutes ago" +"%F %T")"
        } >"${file}"
        return 0
    fi

    play=$(_read_status_field "play_time" "${file}")
    rest=$(_read_status_field "rest_time" "${file}")

    if ! _validate_time_format "${play}"; then
        _log "play_time 无效, 重置为当前时间(原值: ${play})"
        _set_status_field "play_time" "$(date +"%F %T")" "${file}"
    fi
    if ! _validate_time_format "${rest}"; then
        _log "rest_time 无效, 重置为${REST_MINUTES}分钟前(原值: ${rest})"
        _set_status_field "rest_time" "$(date -d "$((REST_MINUTES + 1)) minutes ago" +"%F %T")" "${file}"
    fi
    return 0
}

_do_shutdown() {
    local reason=$1

    if [[ ${debug_mod:-0} == 1 ]]; then
        _log "DEBUG模式: 触发关机条件: ${reason}"
        return 0
    fi

    _log "执行关机: ${reason}"
    sleep "${DELAY_SECONDS}"
    sudo poweroff
}

# 时间段限制: 命中则输出具体原因并返回 1, 允许使用则无输出返回 0
_check_time_limits() {
    local curr_hour weekday
    # 强制十进制, 避免 08/09 被当作非法八进制
    curr_hour=$((10#$(date +%H)))
    weekday=$((10#$(date +%u)))

    # 夜间禁用时段: 21:00-08:00
    if ((curr_hour >= WORK_HOUR_21)) || ((curr_hour < WORK_HOUR_8)); then
        echo "当前处于禁止使用时间段(21:00-08:00)"
        return 1
    fi

    # 工作日(周一至周四)17:00 后禁用; 周五及周末不受此限制
    if ((weekday < 5)) && ((curr_hour >= WORK_HOUR_17)); then
        echo "当前为工作日17点后禁止使用(周一至周四)"
        return 1
    fi

    return 0
}

_remote_trigger() {
    local file=$1
    if curl -fsSL -X POST "${URL_HOST}/trigger" 2>/dev/null | grep -qi "rest"; then
        _do_shutdown "收到远程关机命令"
        return 0
    fi
    return 1
}

_reset() {
    local file=$1
    if [[ -f ${file} ]]; then
        rm -f "${file}" || return 1
    fi
    sudo shutdown -c || true
    return 0
}

main() {
    # 基础变量设置(允许测试预置, 生产环境按 $0 推导)
    : "${SCRIPT_NAME:=$(basename "$0")}"
    : "${SCRIPT_PATH:=$(dirname "$(readlink -f "$0")")}"
    : "${SCRIPT_LOG:=${SCRIPT_PATH}/${SCRIPT_NAME}.log}"
    : "${file_status:=${SCRIPT_PATH}/${SCRIPT_NAME}.status}"

    # 命令处理(reset 在初始化状态文件之前, 避免先创建后删除)
    case $1 in
    reset | r) _reset "${file_status}" && return ;;
    debug | d) debug_mod=1 ;;
    esac

    # 初始化并修复状态文件(覆盖首次运行与脏数据两种情况)
    _ensure_status_file "${file_status}"
    if [[ ${debug_mod:-0} == 1 ]]; then
        _log "DEBUG模式: 状态文件内容: $(cat "${file_status}")"
    fi

    # 1) 远程触发: 优先级最高, 命中立即返回, 不被后续分支覆盖
    if _remote_trigger "${file_status}"; then
        return
    fi

    # 2) 时间段限制: 命中立即返回, 关机原因区分夜间/工作日
    local reason
    if ! reason=$(_check_time_limits); then
        _do_shutdown "${reason}"
        return
    fi

    # 3) 休息时间与开机时长检查
    local rest_elapsed play_elapsed
    rest_elapsed=$(_get_minutes_elapsed "rest" "${file_status}")
    play_elapsed=$(_get_minutes_elapsed "play" "${file_status}")

    # 距离上次关机的休息时间不足, 立即关机
    if ((rest_elapsed < REST_MINUTES)); then
        _do_shutdown "距离上次关机未满${REST_MINUTES}分钟"
        return
    fi

    # 开机时长已达一个完整休息周期, 重置开机计时(视为已重新开始)
    if ((play_elapsed >= REST_MINUTES)); then
        _set_status_field "play_time" "$(date +"%F %T")" "${file_status}"
        _log "开机时长已达${REST_MINUTES}分钟, 重置开机计时"
        return
    fi

    # 开机时长超过上限, 记录关机时间并关机
    if ((play_elapsed >= PLAY_MINUTES)); then
        _set_status_field "rest_time" "$(date +"%F %T")" "${file_status}"
        _do_shutdown "开机时间超过${PLAY_MINUTES}分钟"
        return
    fi
}

main "$@"
