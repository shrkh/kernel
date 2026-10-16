# KernelSU + SUSFS 集成说明

本项目工作流 (`build-coral.yml`) 默认集成 **BakaSU** (KernelSU 的 fork) 和 **SUSFS** (simonpunk/susfs4ksu 的 `kernel-4.14` 分支,内含 SUSFS v1.5.5),编译出带 root 隐藏功能的内核。

> ⚠️ **警告**:root 内核**违反 Android 安全模型**,可能导致:
> - 银行类 app 检测到 root 后拒绝运行(SafetyNet/Play Integrity fail)
> - 部分 DRM 内容无法播放(Netflix HD、L1 Widevine)
> - 保修失效

> SUSFS 通过伪装 root 痕迹缓解以上问题,但不是 100% 有效。

---

## 什么是 BakaSU?

[BakaSU](https://github.com/yourname/KernelSU) 是 [KernelSU](https://github.com/tiann/KernelSU) 的 fork 版,内置 `su` 二进制(用户态 root 工具)。

### KernelSU vs Magisk

| 项目 | Magisk | KernelSU |
|------|--------|----------|
| 实现方式 | 修改 `boot.img`,bootloader 解锁后 patch | 内核模块驱动,内核直接接管 su 权限 |
| 系统完整性 | 通过 Zygisk 注入 | 内核层强制 |
| 模块系统 | Magisk Module | 不完整,需额外配置 |
| Root 隐藏 | MagiskHide / Shamiko / Play Integrity Fix | 配合 SUSFS 实现 |

**KernelSU 优势**:不修改 boot.img(只替换 kernel),理论更安全。

### 集成方式

工作流里:
```yaml
# 1. clone BakaSU 仓库
git clone https://github.com/tiann/KernelSU  # 默认 upstream

# 2. 应用 patch 到内核源码
git apply KernelSU/kernel/*.patch

# 3. 开启 Kconfig
./scripts/config --file .config --enable KSU
```

集成后,内核会自带 su 能力:
- 用户态 `ksu` 命令行工具
- 内核级 hook(`prctl` 系统调用扩展)
- `/proc/ksu` 等调试接口

---

## 什么是 SUSFS?

[SUSFS](https://gitlab.com/simonpunk/susfs4ksu) = **SU** (SuperUser) **S**ecure **F**ile **S**ystem,由 simonpunk 开发,sidex15 等社区维护非 GKI fork。

KernelSU 给了 root 权限,但 root 痕迹会被检测:
- `/proc/mounts` 暴露挂载点
- `mount` 命令列出 tmpfs/proc overlay
- `getprop` 显示 `ro.debuggable=1`
- `/system/bin/su` 文件存在

SUSFS 通过**内核级 hook**伪装这些痕迹。

### 关键特性

| 特性 | 作用 |
|------|------|
| **SUSFS_SUS_MAP** | 隐藏 su 进程的内存映射(`/proc/<pid>/maps`) |
| **SUSFS_SUS_SU** | 让 `/system/bin/su` 不可见 |
| **SUSFS_SUS_OVERLAYFS** | 隐藏 overlay mount |
| **SUSFS_HIDE_BOOTPROGS** | 自定义 `ro.boot.*` 属性 |
| **SUSFS_HIDE_PROPS** | 自定义 `ro.*` 系统属性 |
| **SUSFS_HIDE_APKS** | 隐藏特定 APK |

### 非 GKI inline hooks

非 GKI 内核(像 4.14 Pixel 内核)没法用 GKI 的 `EXPORT_SYMBOL` 接口做 module hook。

SUSFS 提供 inline hooks(直接修改内核函数),绕过 GKI 限制。这是 v1.5.x 系列起持续在做的事。

### 集成方式

```bash
# 1. clone SUSFS(注意:upstream 是 GitLab,不是 GitHub)
#    Pixel 4 XL 用 kernel-4.14 分支(对应 v1.5.5)
git clone --depth=1 --branch kernel-4.14 https://gitlab.com/simonpunk/susfs4ksu.git
#    其他设备如需 v2.x(GKI 5.10+),用 master / gki-android12-5.10 等

# 2. 应用 patch(由 SUSFS 提供,针对特定内核版本)
git apply susfs/kernel_patches/*.patch
#    注意:50_add_susfs_in_kernel-4.14.patch 是给 4.14 内核专用的

# 3. 复制 SUSFS 源码到内核
cp -rv susfs/kernel_patches/fs/susfs fs/
cp -rv susfs/kernel_patches/include/linux/* include/linux/

# 4. 开启 Kconfig
./scripts/config --file .config --enable KSU_SUSFS
```

> **重要**:SUSFS 的"版本"(v1.5.5 / v2.3.0)是 patch 内部的字符串,不是 git tag/branch。
> upstream 只按**内核树**分分支(kernel-4.14 / gki-android12-5.10 / ...)。
> 想升 SUSFS,先看 upstream 哪个分支还在维护,然后切到那个分支。

---

## Pixel 4XL (coral) Android 13 适配情况

### 内核版本
- 源码: [`msnx/KernelSU-Pixel4XL`](https://github.com/msnx/KernelSU-Pixel4XL) `main` 分支
- 内核基础: **Linux 4.14.276**(`android-msm-coral-4.14-android13` legacy 树)
- 设备代号: `floral`(Pixel 4 / 4 XL 共用)
- KernelSU 0.7.x+ 支持 4.14
- SUSFS **v1.5.5**(从 `kernel-4.14` 分支)

> **历史**:`android13-d1-release` 是 AOSP `kernel/manifest` 上的 repo manifest 分支名
> (用 `repo init -u .../kernel/manifest -b android13-d1-release` 拉整棵 manifest),
> 不是某个 git 仓库的分支名。`msnx/KernelSU-Pixel4XL` 的 `main` 分支就是该 manifest
> 在 coral 设备上的实际产出。

### GKI vs 非 GKI

| 模式 | 说明 | Pixel 4XL |
|------|------|-----------|
| **GKI** | Google 通用内核镜像 + vendor 装载 | 不支持(4.14 太老,不是 GKI) |
| **非 GKI** | 内核直接编译设备特定代码 | Pixel 4XL 走这个 |

Pixel 4XL 在 4.14 是纯非 GKI:所有 hook 都在内核源码里做,无 `EXPORT_SYMBOL` for modules 路径。

**SUSFS 的 inline hooks**(配合 `#if defined(CONFIG_KPROBES) && 0` 关闭 KSU 自带 kprobe)是这个
唯一可行的非 GKI 集成方式。

---

## 自定义集成

### 用自己的 BakaSU fork

工作流输入 `kernelsu_repo` 或 secret `BAKASU_REPO`:

```yaml
# workflow_dispatch 触发时输入
kernelsu_repo: https://github.com/yourname/BakaSU
kernelsu_branch: my-feature
```

或 GitHub repo → Settings → Secrets → 添加:
- `BAKASU_REPO`: `https://github.com/<yourname>/BakaSU`
- `BAKASU_BRANCH`: `main`

### 用特定 SUSFS 分支/版本

SUSFS upstream (`simonpunk/susfs4ksu`) 按**内核树**分分支,**没有版本 tag**。
想换分支,在 workflow input `susfs_branch` 或 secret `SUSFS_BRANCH` 里指定:

- `kernel-4.14` — Pixel 4 / 4 XL(默认,v1.5.5)
- `kernel-4.19` — Pixel 4a (5G) / Pixel 5
- `kernel-5.4` — OnePlus 8 系列
- `gki-android12-5.10` / `gki-android13-5.10` / ... — GKI 内核(5.10+)

或在 `.github/workflows/build-coral.yml` 里改默认:

```yaml
env:
  SUSFS_VERSION: '1.5.5'  # 仅用作日志/显示;真正生效的是 susfs_branch
```

### 用自定义 AnyKernel3 模板

项目可以自己维护 AnyKernel3 仓库(比如固定机型参数、proprietary 模块),通过 `ANYKERNEL3_REPO` secret 配置。

---

## 验证集成是否成功

刷入 new-boot.img 后:

```bash
# 1. 内核版本(应显示新版本,带 BakaSU 标识)
adb shell uname -r
adb shell cat /proc/version

# 2. KernelSU 接口
adb shell ls /proc/ksu  # 不存在说明未集成

# 3. 测试 su
adb shell su -c id
# 应返回 "uid=0(root) gid=0(root) groups=0(root)"

# 4. SUSFS 状态
adb shell ls /proc/susfs  # SUSFS 的调试接口
# 或
adb shell cat /sys/module/susfs/parameters/susfs_version

# 5. 验证 root 隐藏
adb shell ls /system/bin/su
# 集成 SUSFS 后应该 ls 不到

# 6. 验证属性伪装
adb shell getprop ro.debuggable
# 应该显示 0(即使 build.prop 是 1)
```

---

## 常见集成问题

### Q1:KernelSU 加载失败 "disagrees about symbol"

```bash
# KSU 头文件与内核不匹配
# 通常是 patch 没 apply 成功
# 查看 build.log: 应该有 "CONFIG_KSU=y"

# 重新跑
./scripts/build.sh clean
./scripts/build.sh compile
```

### Q2:SUSFS 编译时报错 "undefined reference to `susfs_'"

```bash
# 源码没复制到内核
ls $KERNEL_DIR/fs/susfs/
# 应该是空的或缺失

# 工作流会自动 copy,确认后重新编译
```

### Q3:集成后无法启动

参考 [docs/FLASHING.md](FLASHING.md) 的"回退"章节。

常见原因:
- DTB 区丢失(已保留 stock v2 DTB)
- 内核模块版本不匹配
- SUSFS 钩子 crash(罕见,先关掉 SUSFS 测试)

---

## 安全性 / 合规性

- Google 对 root 内核的态度:Pixel 设备的 Verified Boot 在 boot.img 替换后会显示"黄色警告",这是正常的。
- Play Integrity API 检测:SUSFS + Play Integrity Fix (PIF) 模块通常能过 basicIntegrity。
- 银行类 app:即使有 SUSFS,部分 app 仍可能检测到内核签名校验失败,需要 Magisk + PIF 组合方案。

---

## 替代方案

如果不需要 KernelSU,只想要轻度 root:

1. **Magisk** — 修改 boot.img 的传统方案(本项目不支持,需要单独 patch boot.img)
2. **Pure root via adb** — `adb root`(只对 userdebug build 有效,user build 不行)
3. **厂商 root** — Pixel 不支持

如果不需要 root,只要性能优化:用本项目原始的 GKI 内核方案就行,KernelSU 步骤可以跳过。

---

## 资源链接

- [KernelSU 官方文档](https://kernelsu.org/)
- [SUSFS upstream](https://gitlab.com/simonpunk/susfs4ksu)
- [BakaSU 原仓库](https://github.com/yourname/KernelSU)(占位,请用真实仓库)
- [Play Integrity Fix](https://github.com/chiteroman/PlayIntegrityFix)
- [MagiskHide 替代:Shamiko](https://github.com/LSPosed/LSPosed.github.io/releases)