# patches/4.14/

4.14-specific manual hooks required by **backslashxx/KernelSU** for
non-GKI Pixel 4 XL (coral) Android 13 kernel.

These hooks are referenced from `backslashxx/KernelSU/Issue#5` (v2.3,
"scope-minimized manual hooks"). They patch the kernel source so the
`ksu_handle_*` C functions declared in `drivers/kernelsu/` can be called
during syscall entry.

## 为什么 non-GKI 4.14 需要 in-source hooks

Modern (5.10+ GKI) kernels let KSU register LSM hooks via `EXPORT_SYMBOL`,
so the kernel doesn't need source-level changes. 4.14 has neither:
- No `security_hook_heads` list-based LSM
- No generic `setprocattr` hooks
- No `path_umount` (older kernel API)
- `ksu_install_su_fd` semantics differ

So the only way to intercept `execve` / `faccessat` / `newfstatat` /
`reboot` on 4.14 is to **modify fs/exec.c, fs/open.c, fs/stat.c,
kernel/reboot.c directly** to call into the ksu functions.

## 文件清单

| 文件 | hook | 必需? |
|------|------|--------|
| `01-fs-exec-hook-do_execveat_common.patch` | `do_execveat_common` | ✓ 必需(sucompat path) |
| `02-fs-open-hook-sys_faccessat.patch`      | `sys_faccessat`    | ✓ 必需(sucompat gate) |
| `03-fs-stat-hook-sys_newfstatat.patch`     | `sys_newfstatat` + `sys_fstatat64` | ✓ 必需(sucompat redirect) |
| `04-kernel-reboot-hook-sys_reboot.patch`   | `sys_reboot`       | ⚠ 推荐(supercall 功能) |

## apply 顺序

由 `git apply` 自动按文件名字典序处理(数字前缀保证)。

build-coral.yml 在 BakaSU step 之前 apply 这些 patch。
build.sh 的 `cmd_apply_patches` 在 `cmd_compile` 之前 apply。

## 与 kprobes 互斥

patch 03/04 用 `#ifndef CONFIG_KSU_KPROBES_KSUD` 守护:
- 关 kprobes (CONFIG_KSU_KPROBES_KSUD=n,默认) → patch 生效
- 开 kprobes (CONFIG_KSU_KPROBES_KSUD=y) → patch 跳过,kprobes 接替

Pixel 4 XL 4.14 kernel 的 `.config` 通常 `CONFIG_KPROBES=y`,
`CONFIG_KPROBES_KSU=y` 也可开(kprobes 替代 manual hooks)。

## 来源

- backslashxx/KernelSU Issue #5 — https://github.com/backslashxx/KernelSU/issues/5
- backslashxx/KernelSU Issue #4 — https://github.com/backslashxx/KernelSU/issues/4
- backslashxx/KernelSU `kernel/kernel_compat.h` — `< KERNEL_VERSION(4, 14, 0)` shim

最后更新于 backslashxx/KernelSU commit `14fc0868a7ae073f96ae9ac549c87e8820f7634b`。