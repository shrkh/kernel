# KernelSU + SUSFS 集成说明

本项目工作流 (`build-coral.yml`) 默认集成 **BakaSU** (KernelSU 的 fork) 和 **SUSFS v2.3.0**,编译出带 root 隐藏功能的内核。

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

[SUSFS](https://github.com/sidex15/susfs) = **SU** (SuperUser) **S**ecure **F**ile **S**ystem,由 sidex15 开发。

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

非 GKI 内核(像 5.10 Pixel 内核)没法用 GKI 的 `EXPORT_SYMBOL` 接口做 module hook。

SUSFS 提供 inline hooks(直接修改内核函数),绕过 GKI 限制。这是 v2.3.0 最大的改进。

### 集成方式

```bash
# 1. clone SUSFS
git clone --depth=1 https://github.com/sidex15/susfs
# 或特定版本
git clone --depth=1 --branch v2.3.0 https://github.com/sidex15/susfs

# 2. 应用 patch(由 SUSFS 提供,针对特定内核版本)
git apply susfs/kernel_patches/*.patch

# 3. 复制 SUSFS 源码到内核
cp -r susfs/kernel_patches/fs/susfs fs/

# 4. 开启 Kconfig
./scripts/config --file .config --enable SUSFS
```

---

## Pixel 4XL (coral) Android 13 适配情况

### 内核版本
- 源码: [`msnx/KernelSU-Pixel4XL`](https://github.com/msnx/KernelSU-Pixel4XL) `main` 分支
- 内核基础: **Linux 5.10.123+**(`android-msm-coral-4.14-android13` legacy 树)
- 设备代号: `floral`(Pixel 4 / 4 XL 共用)
- KernelSU 0.7.x+ 支持 5.10
- SUSFS v2.3.0 适配 5.10

> **历史**:`android13-d1-release` 是 AOSP `kernel/manifest` 上的 repo manifest 分支名
> (用 `repo init -u .../kernel/manifest -b android13-d1-release` 拉整棵 manifest),
> 不是某个 git 仓库的分支名。`msnx/KernelSU-Pixel4XL` 的 `main` 分支就是该 manifest
> 在 coral 设备上的实际产出。

### GKI vs 非 GKI

| 模式 | 说明 | Pixel 4XL |
|------|------|-----------|
| **GKI** | Google 通用内核镜像 + vendor 装载 | 部分支持(只支持 bootloader 后的 vendor_dlkm) |
| **非 GKI** | 内核直接编译设备特定代码 | Pixel 4XL 默认走这个 |

Pixel 4XL 在 5.10+ 介于两者之间:有 GKI 接口,但 dtbo/display 部分走 vendor 路径。

**SUSFS v2.3.0 的 inline hooks** 主要解决这个过渡期的 hook 缺失问题。

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

### 用特定 SUSFS 版本

工作流默认 v2.3.0。要改版本,在 `.github/workflows/build-coral.yml` 里改:

```yaml
env:
  SUSFS_VERSION: '2.3.0'  # 改成你想要的版本
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
- [SUSFS README](https://github.com/sidex15/susfs)
- [BakaSU 原仓库](https://github.com/yourname/KernelSU)(占位,请用真实仓库)
- [Play Integrity Fix](https://github.com/chiteroman/PlayIntegrityFix)
- [MagiskHide 替代:Shamiko](https://github.com/LSPosed/LSPosed.github.io/releases)