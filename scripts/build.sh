#!/usr/bin/env bash
#
# scripts/build.sh — 本地构建 Pixel 4XL (coral) 内核
#
# 用法:
#   ./scripts/build.sh fetch     拉取内核源码
#   ./scripts/build.sh compile   编译(自动应用 patches/、ccache 加速)
#   ./scripts/build.sh clean     清理 out/
#   ./scripts/build.sh rebuild   clean + compile
#   ./scripts/build.sh apply-patches  只应用 patches/(不编译)
#   ./scripts/build.sh info      显示内核版本和编译工具链信息
#
# 兼容 Ubuntu 20.04+/22.04,WSL2 也可

set -euo pipefail

# ============================================================
# 配置(可用环境变量覆盖)
# ============================================================
# coral 内核在 AOSP 上没有公开的 kernel 树,官方遗留分支是
# `device/google/coral-kernel`(只含 device config,不含源码)。
# community 维护的镜像使用 "floral" 作设备代号(Pixel 4 / 4 XL 共用),
# 内置 KernelSU 集成。这里默认从社区维护的 msnx/KernelSU-Pixel4XL 拉取。
CORAL_REPO="${CORAL_REPO:-https://github.com/msnx/KernelSU-Pixel4XL}"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
KERNEL_DIR="${KERNEL_DIR:-kernel/google-coral}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 颜色(非交互环境下关闭)
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log()  { echo "${C_BLUE}[build.sh]${C_RESET} $*" >&2; }
ok()   { echo "${C_GREEN}[build.sh] ✓${C_RESET} $*" >&2; }
warn() { echo "${C_YELLOW}[build.sh] ⚠${C_RESET} $*" >&2; }
die()  { echo "${C_RED}[build.sh] ✗${C_RESET} $*" >&2; exit 1; }

# ============================================================
# 子命令
# ============================================================

cmd_fetch() {
    if [[ -d "$KERNEL_DIR" ]]; then
        log "$KERNEL_DIR 已存在,跳过 fetch(若要重拉请先 rm -rf)"
        return 0
    fi

    log "拉取 coral 内核源码"
    log "  仓库: $CORAL_REPO"
    log "  分支: $KERNEL_BRANCH"
    log "  路径: $KERNEL_DIR"

    mkdir -p "$(dirname "$KERNEL_DIR")"
    git clone --depth=1 --branch "$KERNEL_BRANCH" "$CORAL_REPO" "$KERNEL_DIR"
    ok "源码拉取完成"
}

cmd_apply_patches() {
    [[ -d "$KERNEL_DIR" ]] || die "源码不存在,先跑: $0 fetch"

    if [[ ! -d "$PROJECT_ROOT/patches" ]]; then
        log "patches/ 目录不存在,跳过"
        return 0
    fi

    local count=0
    while IFS= read -r -d '' p; do
        [[ "$p" == *.patch ]] || continue
        log "Apply: $p"
        (
            cd "$KERNEL_DIR"
            if git apply --check "$p" 2>/dev/null; then
                git apply "$p"
                ok "  -> applied"
                count=$((count + 1))
            else
                warn "  -> conflict,尝试 3-way merge"
                if git apply --3way "$p" 2>/dev/null; then
                    ok "  -> 3-way merged"
                    count=$((count + 1))
                else
                    die "  -> 失败,请手动处理: $p"
                fi
            fi
        )
    done < <(find "$PROJECT_ROOT/patches" -maxdepth 1 -type f -name '*.patch' \
             -print0 | sort -z)

    [[ $count -eq 0 ]] && log "patches/ 里没有 patch 文件" || ok "$count patch apply 成功"
}

cmd_compile() {
    [[ -d "$KERNEL_DIR" ]] || die "源码不存在,先跑: $0 fetch"

    # 1. ccache
    mkdir -p "$CCACHE_DIR"
    command -v ccache >/dev/null 2>&1 && ccache -M "$CCACHE_MAXSIZE"

    # 2. 应用 patches
    cmd_apply_patches

    # 3. 改写 build.config(去除私有 device tree 引用)
    (
        cd "$KERNEL_DIR"
        if [[ -f build/build.config.coral ]]; then
            if grep -q "private/google-modules" build/build.config.coral; then
                warn "build.config.coral 引用私有 device tree,改用 build.config.gki"
                cp build/build.config.coral build/build.config.coral.bak
            fi
        fi

        if [[ ! -e build.config ]]; then
            if [[ -f build/build.config.gki ]]; then
                ln -sf build/build.config.gki build.config
            else
                cat > build.config <<'EOF'
. ${ROOT_DIR}/build.config.common
. ${ROOT_DIR}/build.config.gki
DEFCONFIG=floral_defconfig
EOF
            fi
            ok "创建 build.config"
        fi

        log "build.config 内容:"
        cat build.config >&2
    )

    # 4. 调用 AOSP build.sh
    (
        cd "$KERNEL_DIR"
        log "BUILD_CONFIG=build.config ./build/build.sh (jobs=$JOBS)"
        BUILD_CONFIG=build.config ./build/build.sh 2>&1 | tee "$PROJECT_ROOT/build.log"
    )

    ok "编译完成"
    log "产物:"
    [[ -f "$KERNEL_DIR/out/arch/arm64/boot/Image.gz-dtb" ]] && \
        ls -lh "$KERNEL_DIR/out/arch/arm64/boot/Image.gz-dtb" >&2
    [[ -f "$KERNEL_DIR/out/dist/boot.img" ]] && \
        ls -lh "$KERNEL_DIR/out/dist/boot.img" >&2
}

cmd_clean() {
    [[ -d "$KERNEL_DIR/out" ]] || { log "out/ 不存在,无需清理"; return 0; }
    log "清理 out/"
    rm -rf "$KERNEL_DIR/out"
    ok "清理完成"
}

cmd_rebuild() {
    cmd_clean
    cmd_compile
}

cmd_info() {
    cat <<EOF
=== 构建环境 ===
  PROJECT_ROOT:   $PROJECT_ROOT
  KERNEL_DIR:     $KERNEL_DIR
  KERNEL_BRANCH:  $KERNEL_BRANCH
  CORAL_REPO:     $CORAL_REPO
  JOBS:           $JOBS
  CCACHE_DIR:     $CCACHE_DIR

=== 工具链检测 ===
EOF
    local t
    for t in git ccache clang aarch64-linux-android-gcc python3 make bc bison flex; do
        if command -v "$t" >/dev/null 2>&1; then
            local v
            v=$("$t" --version 2>&1 | head -n1)
            printf "  %-30s %s\n" "$t" "$v"
        else
            printf "  %-30s ${C_RED}缺失${C_RESET}\n" "$t"
        fi
    done

    if [[ -d "$KERNEL_DIR" ]]; then
        echo ""
        echo "=== 源码信息 ==="
        (
            cd "$KERNEL_DIR"
            printf "  HEAD:    %s\n" "$(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')"
            printf "  Branch:  %s\n" "$(git branch --show-current 2>/dev/null || echo 'N/A')"
            printf "  Version: %s\n" "$(make -s kernelversion 2>/dev/null || echo 'N/A')"
        )
    fi
}

cmd_help() {
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ============================================================
# 入口
# ============================================================
SUBCMD="${1:-help}"
shift || true

case "$SUBCMD" in
    fetch|compile|clean|rebuild|apply-patches|info|help|-h|--help)
        cmd_"${SUBCMD/-/_}" "$@"
        ;;
    *)
        die "未知子命令: $SUBCMD(可用: fetch|compile|clean|rebuild|apply-patches|info|help)"
        ;;
esac