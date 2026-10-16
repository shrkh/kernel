#!/usr/bin/env bash
#
# scripts/setup_env.sh — 检查本地编译环境
#
# 用法:
#   ./scripts/setup_env.sh           仅检查(不安装)
#   ./scripts/setup_env.sh install   自动 apt install(Ubuntu/Debian)
#   ./scripts/setup_env.sh fix        仅显示修复建议

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 颜色
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

MISSING=()
OS=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="$ID"
    elif [[ "$(uname)" == "Darwin" ]]; then
        OS="macos"
    elif [[ "$(uname -s" 2>/dev/null)" == *"MINGW"* ]] || [[ "$(uname)" == *"CYGWIN"* ]]; then
        OS="windows"
    fi
}

# 工具检测函数
# 用法: check_tool <name> <required_version_command> <fallback_generator>
check_tool() {
    local tool="$1"
    local version_cmd="${2:---version}"
    local apt_pkg="${3:-}"
    local brew_pkg="${4:-}"

    if command -v "$tool" >/dev/null 2>&1; then
        local ver
        ver=$("$tool" $version_cmd 2>&1 | head -n1)
        printf "  ${C_GREEN}✓${C_RESET} %-20s %s\n" "$tool" "$ver"
        return 0
    else
        printf "  ${C_RED}✗${C_RESET} %-20s ${C_RED}缺失${C_RESET}\n" "$tool"
        MISSING+=("$tool:$apt_pkg:$brew_pkg")
        return 1
    fi
}

# 检查 Python 模块
check_python_module() {
    local mod="$1"
    local apt_pkg="${2:-python3-$mod}"
    local pip_pkg="${3:-$mod}"

    if python3 -c "import $mod" >/dev/null 2>&1; then
        printf "  ${C_GREEN}✓${C_RESET} %-20s %s\n" "python:$mod" "$(python3 -c "import $mod; print($mod.__version__)" 2>/dev/null || echo 'OK')"
        return 0
    else
        printf "  ${C_RED}✗${C_RESET} %-20s ${C_RED}缺失${C_RESET}\n" "python:$mod"
        MISSING+=("py:$mod:$apt_pkg:$pip_pkg")
        return 1
    fi
}

# 检查命令行工具(模拟)
check_tool_redir() {
    # 用作 Windows 下的占位检测
    return 0
}

# ============================================================
# 主检查
# ============================================================
run_check() {
    echo ""
    echo "${C_BOLD}=== 系统信息 ===${C_RESET}"
    detect_os
    printf "  OS: %s\n" "${OS:-unknown}"
    printf "  内核: %s\n" "$(uname -r 2>/dev/null || echo 'N/A')"
    printf "  CPU 核心: %s\n" "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
    printf "  内存: %s\n" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo '?')"
    printf "  磁盘剩余: %s\n" "$(df -h "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo '?')"

    echo ""
    echo "${C_BOLD}=== 编译工具链 ===${C_RESET}"
    check_tool git
    check_tool make
    check_tool bc
    check_tool bison
    check_tool flex
    check_tool ccache
    check_tool python3 "--version"
    check_tool python2 "--version 2>&1 | head -n1" || \
        printf "  ${C_YELLOW}!${C_RESET} %-20s ${C_YELLOW}可选,但 build.sh 可能需要${C_RESET}\n" "python2"

    echo ""
    echo "${C_BOLD}=== 内核编译专用 ===${C_RESET}"
    check_tool aarch64-linux-gnu-gcc
    check_tool aarch64-linux-android-gcc || \
        printf "  ${C_YELLOW}!${C_RESET} %-20s ${C_YELLOW}build.sh 会从 AOSP 预构建仓库下载${C_RESET}\n" "aarch64-linux-android-gcc"

    echo ""
    echo "${C_BOLD}=== Python 模块 ===${C_RESET}"
    check_python_module zipfile
    check_python_module gzip
    check_python_module json

    echo ""
    echo "${C_BOLD}=== Android Platform Tools ===${C_RESET}"
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        printf "  ANDROID_HOME: %s\n" "$ANDROID_HOME"
        check_tool "$ANDROID_HOME/platform-tools/adb" "" || true
        check_tool "$ANDROID_HOME/platform-tools/fastboot" "" || true
    else
        check_tool adb || true
        check_tool fastboot || true
    fi

    echo ""
    echo "${C_BOLD}=== 镜像工具(extract_vendor.py 需要) ===${C_RESET}"
    check_tool simg2img 2>/dev/null || \
        printf "  ${C_YELLOW}!${C_RESET} %-20s ${C_YELLOW}脚本会自动从 GitHub 下载${C_RESET}\n" "simg2img"
    check_tool debugfs "" "e2fsprogs" || true
}

# ============================================================
# 自动安装(Ubuntu/Debian)
# ============================================================
do_install() {
    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        die "auto-install 仅支持 Ubuntu/Debian($OS 不支持)
  macOS: brew install ${MISSING[*]/*:/}
  Windows: WSL2 + Ubuntu"
    fi

    echo ""
    log "自动安装缺失工具(sudo apt install)..."

    local apt_pkgs=()
    for entry in "${MISSING[@]}"; do
        IFS=':' read -r tool apt_pkg brew_pkg <<<"$entry"
        [[ -n "$apt_pkg" ]] && apt_pkgs+=("$apt_pkg")
    done

    # 必装集合
    apt_pkgs+=(
        build-essential bc bison ccache flex
        libssl-dev libelf-dev dwarves rsync cpio
        unzip xz-utils curl git
        e2fsprogs
        python3 python2 python3-pip
        android-tools-adb android-tools-fastboot
    )
    # 去重
    local unique_pkgs
    unique_pkgs=($(printf '%s\n' "${apt_pkgs[@]}" | sort -u))

    log "将安装 ${#unique_pkgs[@]} 个包: ${unique_pkgs[*]}"
    sudo apt-get update
    sudo apt-get install -y "${unique_pkgs[@]}"

    log "simg2img 不在 apt,正在下载..."
    sudo curl -fsSL https://github.com/anestisb/android-simg2img/releases/download/v1.1.0/simg2img \
        -o /usr/local/bin/simg2img
    sudo chmod +x /usr/local/bin/simg2img

    ok "安装完成,请重新运行 $0 验证"
}

# ============================================================
# 修复建议
# ============================================================
do_fix() {
    echo ""
    echo "${C_BOLD}=== 修复建议 ===${C_RESET}"
    if [[ ${#MISSING[@]} -eq 0 ]]; then
        ok "环境完好,无需修复"
        return 0
    fi

    case "$OS" in
        ubuntu|debian)
            echo "  Ubuntu/Debian:"
            echo "    sudo apt install -y build-essential bc bison ccache flex \\"
            echo "      libssl-dev libelf-dev dwarves rsync cpio unzip xz-utils curl \\"
            echo "      e2fsprogs python3 python2 android-tools-adb android-tools-fastboot"
            echo "    # simg2img 从 GitHub 下载 prebuilt"
            echo "    sudo curl -L https://github.com/anestisb/android-simg2img/releases/download/v1.1.0/simg2img \\"
            echo "      -o /usr/local/bin/simg2img && sudo chmod +x /usr/local/bin/simg2img"
            ;;
        macos)
            echo "  macOS:"
            echo "    brew install git make ccache bison flex"
            echo "    brew install --cask android-platform-tools"
            echo "    # macOS 内核编译需要额外安装 aarch64 cross-compiler:"
            echo "    brew install --cask gcc-arm-embedded  # 或自己编译"
            echo "    # 注意: macOS 内核交叉编译到 Android 兼容性差,建议 Ubuntu/WSL2"
            ;;
        windows)
            echo "  Windows:"
            echo "    推荐使用 WSL2 + Ubuntu 22.04(在 Microsoft Store 安装)"
            echo "    或在 PowerShell 安装 scoop: scoop install git python make"
            echo "    注意: 内核编译强烈建议在 Linux 上跑"
            ;;
        *)
            echo "  未知 OS,请根据发行版手册安装:"
            echo "    - git, make, bc, bison, flex, ccache"
            echo "    - libssl-dev, libelf-dev, dwarves, rsync, cpio"
            echo "    - python3 >= 3.6, e2fsprogs"
            echo "    - platform-tools (adb, fastboot)"
            ;;
    esac
}

# ============================================================
# 入口
# ============================================================
SUBCMD="${1:-check}"

case "$SUBCMD" in
    check|info|"")
        run_check
        echo ""
        if [[ ${#MISSING[@]} -eq 0 ]]; then
            echo "${C_GREEN}环境检查通过!可以开始构建内核。${C_RESET}"
        else
            echo "${C_YELLOW}有 ${#MISSING[@]} 个项目缺失。运行 '$0 fix' 查看修复建议,或 '$0 install' 自动安装(Ubuntu/Debian)。${C_RESET}"
        fi
        ;;
    install)
        run_check
        do_install
        ;;
    fix)
        run_check
        do_fix
        ;;
    -h|--help|help)
        sed -n '3,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "用法: $0 [check|install|fix|help]" >&2
        exit 1
        ;;
esac