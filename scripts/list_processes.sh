#!/usr/bin/env bash
#
# scripts/list_processes.sh — 在 Pixel 4XL 设备上列出所有运行进程
#
# 用法:
#   ./scripts/list_processes.sh                      默认:显示所有
#   ./scripts/list_processes.sh <UID>                 只显示某 UID(uid_xxxx 风格)
#   ./scripts/list_processes.sh <name>              按名字过滤(子串匹配)
#   ./scripts/list_processes.sh --kernel-modules    只显示加载的内核模块
#   ./scripts/list_processes.sh --top <N>           显示 CPU 占用前 N 名
#   ./scripts/list_processes.sh --zombies           只显示僵尸进程
#   ./scripts/list_processes.sh --count            只显示进程总数
#   ./scripts/list_processes.sh --threads <PID>     显示某 PID 的所有线程
#
# 跨设备(本地 / adb),自动检测

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 颜色
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'
    C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log()  { echo "${C_BLUE}[list_processes]${C_RESET} $*" >&2; }
warn() { echo "${C_YELLOW}[list_processes] ⚠${C_RESET} $*" >&2; }

# ============================================================
# 运行模式:local / adb
# ============================================================

# 用法: run <command...>   在"远端"(设备或本地)执行命令并打印
declare -A REMOTE

is_local() {
    [[ "${REMOTE[mode]:-}" == "local" ]]
}

setup_local() {
    REMOTE[mode]=local
    REMOTE[prefix]=""  # 不加任何前缀
}

setup_adb() {
    local device="${ADB_DEVICE:-}"
    local adb_cmd

    if [[ -n "$device" ]]; then
        adb_cmd=(adb -s "$device")
    else
        adb_cmd=(adb)
    fi

    # 检查设备
    if ! "${adb_cmd[@]}" get-state >/dev/null 2>&1; then
        echo "ERROR: adb 设备不可用" >&2
        echo "  1. 手机连接 USB,打开 USB 调试" >&2
        echo "  2. adb devices 应该能看到设备" >&2
        exit 1
    fi

    # adb shell <cmd> 在大部分 shell 里会经过远端 sh 重新解释,需要引号转义
    REMOTE[mode]=adb
    REMOTE[adb_cmd]="${adb_cmd[*]}"
    REMOTE[prefix]="${adb_cmd[*]} shell"
}

remote_run() {
    if is_local; then
        "$@"
    else
        ${REMOTE[adb_cmd]} shell "$@"
    fi
}

# 把命令改成"在远端执行"。如果是 adb,需要把命令拼成字符串。
# 用法: REMOTE_CMD <command...>
REMOTE_CMD() {
    if is_local; then
        "$@"
    else
        # adb 模式:把命令拼成字符串(用空格 join),然后 adb shell 执行
        local cmd=""
        for arg in "$@"; do
            # 加引号以防空格
            cmd+="\"$arg\" "
        done
        ${REMOTE[adb_cmd]} shell "$cmd"
    fi
}

# ============================================================
# 子命令
# ============================================================

cmd_default() {
    # 默认列出所有进程
    remote_run ps -A -o PID,USER,PID,PPID,VSZ,RSS,WCHAN,STAT,NAME
}

cmd_filter_uid() {
    local uid="$1"
    log "过滤 UID $uid"
    remote_run ps -A -o PID,USER,PID,PPID,VSZ,RSS,STAT,NAME | head -n 1
    remote_run ps -A -o PID,USER,PID,PPID,VSZ,RSS,STAT,NAME | grep -E "\\b$uid\\b" | grep -v -E "^USER|^PID" || true
}

cmd_filter_name() {
    local name="$1"
    log "过滤进程名包含 '$name'"
    remote_run ps -A -o PID,USER,PID,PPID,VSZ,RSS,STAT,NAME | head -n 1
    remote_run ps -A -o PID,USER,PID,PPID,VSZ,RSS,STAT,NAME | grep "$name" | grep -v -E "^USER|^PID" || true
}

cmd_kernel_modules() {
    log "已加载的内核模块"
    # /proc/modules 永远存在,Android 也保留
    if is_local; then
        cat /proc/modules
    else
        ${REMOTE[adb_cmd]} shell cat /proc/modules
    fi
}

cmd_top() {
    local n="${1:-10}"
    log "CPU 占用前 $n"
    remote_run top -b -n 1 | head -n $((n + 7)) | tail -n $((n + 6))
}

cmd_zombies() {
    log "僵尸进程"
    # STAT 列第 2 列含 'Z'
    remote_run ps -A -o PID,USER,STAT,NAME | head -n 1
    remote_run ps -A -o PID,USER,STAT,NAME | awk '$3 ~ /Z/' | grep -v "^PID" || true
}

cmd_count() {
    local count
    if is_local; then
        count=$(ls /proc | grep -E '^[0-9]+$' | wc -l)
    else
        # adb shell 处理起来麻烦,简单点直接 ps -A
        count=$(${REMOTE[adb_cmd]} shell "ps -A | wc -l" | tr -d '[:space:]')
    fi
    echo "运行进程数: $count"
}

cmd_threads() {
    local pid="$1"
    log "PID $pid 的所有线程"
    if is_local; then
        if [[ ! -d "/proc/$pid" ]]; then
            echo "ERROR: 进程 $pid 不存在" >&2
            exit 1
        fi
        ps -L -p "$pid" -o PID,USER,PID,PPID,LWP,STAT,NAME
    else
        # 先确认进程存在
        if ! ${REMOTE[adb_cmd]} shell "test -d /proc/$pid" 2>/dev/null; then
            echo "ERROR: 设备上进程 $pid 不存在" >&2
            exit 1
        fi
        ${REMOTE[adb_cmd]} shell "ps -L -p $pid -o PID,USER,PID,PPID,LWP,STAT,NAME"
    fi
}

# ============================================================
# 入口
# ============================================================
main() {
    # 默认 adb,除非 --local 显式指定
    if [[ "${1:-}" == "--local" ]]; then
        setup_local
        shift
    else
        setup_adb
    fi

    if [[ $# -eq 0 ]]; then
        cmd_default
        return 0
    fi

    case "$1" in
        --kernel-modules|-m)
            cmd_kernel_modules
            ;;
        --top)
            shift
            cmd_top "${1:-10}"
            ;;
        --zombies|-z)
            cmd_zombies
            ;;
        --count|-c)
            cmd_count
            ;;
        --threads|-t)
            shift
            [[ -n "${1:-}" ]] || { echo "用法: $0 --threads <PID>" >&2; exit 1; }
            cmd_threads "$1"
            ;;
        --help|-h|help)
            sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            ;;
        --*)
            echo "未知选项: $1" >&2
            exit 1
            ;;
        *)
            # 数字 = UID,字符串 = name
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                cmd_filter_uid "$1"
            else
                cmd_filter_name "$1"
            fi
            ;;
    esac
}

main "$@"