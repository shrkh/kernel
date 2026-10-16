#!/usr/bin/env bash
#
# scripts/flash.sh — Pixel 4XL (coral) 一键刷机
#
# 用法:
#   ./scripts/flash.sh boot <img>           刷 boot 分区(默认流程)
#   ./scripts/flash.sh dry-run <img>        仅 fastboot boot 试启动(不刷志)
#   ./scripts/flash.sh backup <partition>   备份当前分区
#   ./scripts/flash.sh restore <partition>  从备份恢复
#   ./scripts/flash.sh all <boot-img>       刷 boot + vendor_dlkm + dtbo
#   ./scripts/flash.sh reboot               重启到 system
#   ./scripts/flash.sh reboot-bootloader    重启到 bootloader
#
# 兼容: Windows / Linux / macOS(只要装了 platform-tools)

set -euo pipefail

# ============================================================
# 配置
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/backups}"
DEVICE_CODENAME="${DEVICE_CODENAME:-coral}"
PLATFORM_TOOLS_URL="https://developer.android.com/studio/releases/platform-tools"

# 颜色
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

log()  { echo "${C_BLUE}[flash.sh]${C_RESET} $*" >&2; }
ok()   { echo "${C_GREEN}[flash.sh] ✓${C_RESET} $*" >&2; }
warn() { echo "${C_YELLOW}[flash.sh] ⚠${C_RESET} $*" >&2; }
die()  { echo "${C_RED}[flash.sh] ✗${C_RESET} $*" >&2; exit 1; }

# ============================================================
# 工具检测
# ============================================================

find_fastboot() {
    # 优先级: ANDROID_HOME > PATH > 项目内 > ~/Android/Sdk
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        local fb="$ANDROID_HOME/platform-tools/fastboot"
        [[ -x "$fb" ]] && { echo "$fb"; return; }
        local fb="$ANDROID_HOME/platform-tools/fastboot.exe"
        [[ -x "$fb" ]] && { echo "$fb"; return; }
    fi
    if command -v fastboot >/dev/null 2>&1; then
        command -v fastboot
        return
    fi
    die "找不到 fastboot 命令
  1. 安装 Android SDK Platform Tools: $PLATFORM_TOOLS_URL
  2. 或设置 ANDROID_HOME 环境变量指向 SDK 目录"
}

find_adb() {
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        local a="$ANDROID_HOME/platform-tools/adb"
        [[ -x "$a" ]] && { echo "$a"; return; }
        local a="$ANDROID_HOME/platform-tools/adb.exe"
        [[ -x "$a" ]] && { echo "$a"; return; }
    fi
    command -v adb 2>/dev/null || echo "adb"
}

check_device_in_fastboot() {
    local fb="$1"
    local out
    out=$("$fb" devices 2>&1)
    if ! echo "$out" | grep -q "fastboot$"; then
        die "未检测到 fastboot 模式的设备:
$out

请先:
  1. 手机进入开发者选项,打开 USB 调试
  2. 运行: adb reboot bootloader
  3. 再执行本脚本"
    fi
    echo "$out" | grep "fastboot$" | head -n1 | awk '{print $1}'
}

# ============================================================
# 子命令
# ============================================================

cmd_boot() {
    local img="${1:-}"
    [[ -n "$img" && -f "$img" ]] || die "用法: $0 boot <img> 或 $0 dry-run <img>"

    local fb; fb=$(find_fastboot)
    check_device_in_fastboot "$fb"
    log "刷 boot: $img"
    "$fb" flash boot "$img"
    ok "boot 刷写完成"
    warn "建议先验证: $0 dry-run $img(再确认 reboot)"
}

cmd_dry_run() {
    local img="${1:-}"
    [[ -n "$img" && -f "$img" ]] || die "用法: $0 dry-run <img>"

    local fb; fb=$(find_fastboot)
    check_device_in_fastboot "$fb"
    log "fastboot boot 试启动(不刷志): $img"
    warn "设备会从 $img 启动,断电或 reboot 后恢复原 boot"
    "$fb" boot "$img"
    ok "已临时启动 $img"
    log "  验证方法: adb shell uname -r 应显示新内核版本"
    log "  满意后: $0 boot $img 永久刷入"
    log "  不满意: adb reboot bootloader(回到原内核)"
}

cmd_backup() {
    local partition="${1:-boot}"
    mkdir -p "$BACKUP_DIR"
    local fb; fb=$(find_fastboot)
    check_device_in_fastboot "$fb"

    local out="$BACKUP_DIR/${DEVICE_CODENAME}_${partition}_$(date +%Y%m%d_%H%M%S).img"
    log "备份 $partition -> $out"
    "$fb" fetch "$out" "$partition"
    ok "备份完成: $out"
}

cmd_restore() {
    local img="${1:-}"
    [[ -n "$img" && -f "$img" ]] || die "用法: $0 restore <backup_img>"

    local fb; fb=$(find_fastboot)
    check_device_in_fastboot "$fb"

    log "从 $img 恢复(刷写)"
    warn "这个操作会刷写 $img 对应的分区"
    read -rp "确认? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log "已取消"; exit 0; }
    "$fb" flash boot "$img"
    ok "恢复完成"
}

cmd_all() {
    local boot_img="${1:-}"
    [[ -n "$boot_img" && -f "$boot_img" ]] || die "用法: $0 all <boot_img>"

    local fb; fb=$(find_fastboot)
    check_device_in_fastboot "$fb"

    log "完整刷写流程: boot + vendor_dlkm + dtbo"

    # 1. 备份当前 boot
    cmd_backup boot

    # 2. 刷 boot
    log "[1/3] 刷 boot"
    "$fb" flash boot "$boot_img"

    # 3. 刷 vendor_dlkm(如果 out/vendor_dlkm/vendor.img 存在)
    local vendor_img="$PROJECT_ROOT/out/vendor_modules/vendor_dlkm.img"
    if [[ ! -f "$vendor_img" ]]; then
        # 备选: 仓库顶层 out/
        for cand in "$PROJECT_ROOT/out/dist/vendor_dlkm.img" \
                    "$PROJECT_ROOT/out/vendor_dlkm.img"; do
            [[ -f "$cand" ]] && { vendor_img="$cand"; break; }
        done
    fi
    if [[ -f "$vendor_img" ]]; then
        log "[2/3] 刷 vendor_dlkm"
        "$fb" flash vendor_dlkm "$vendor_img"
    else
        warn "[2/3] vendor_dlkm.img 未找到,跳过(复用系统原版 vendor_dlkm)"
    fi

    # 4. dtbo(如果有)
    local dtbo_img="$PROJECT_ROOT/out/dtbo.img"
    if [[ -f "$dtbo_img" ]]; then
        log "[3/3] 刷 dtbo"
        "$fb" flash dtbo "$dtbo_img"
    else
        log "[3/3] dtbo.img 未生成,跳过(默认使用 stock dtbo)"
    fi

    ok "完整刷写完成"
    log "备份在: $BACKUP_DIR"
    log "重启: $0 reboot"
}

cmd_reboot() {
    local target="${1:-system}"
    local fb; fb=$(find_fastboot)
    check_device_in_fastboot "$fb"

    case "$target" in
        system)       "$fb" reboot ;;
        bootloader)   "$fb" reboot-bootloader ;;
        recovery)     "$fb" reboot-recovery ;;
        *) die "未知目标: $target(system|bootloader|recovery)" ;;
    esac
}

cmd_help() {
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ============================================================
# 入口
# ============================================================
SUBCMD="${1:-help}"
shift || true

case "$SUBCMD" in
    boot|dry-run|backup|restore|all|reboot|help|-h|--help)
        cmd_"${SUBCMD//-/_}" "$@"
        ;;
    *)
        die "未知子命令: $SUBCMD(可用: boot|dry-run|backup|restore|all|reboot|help)"
        ;;
esac