# 刷机指南

本文档详细介绍 Pixel 4XL (coral) 内核刷机的完整步骤,包括:
1. 解锁 bootloader
2. 安装 platform-tools
3. 编译内核
4. 刷入 boot.img
5. 验证启动
6. 回退方法

> ⚠️ **风险提示**: 刷内核会让设备在极少数情况下无法启动。务必先备份原 boot.img,且保证手机有 ≥40% 电量。

---

## 目录

- [前置准备](#前置准备)
- [1. 解锁 bootloader](#1-解锁-bootloader)
- [2. 安装 Platform Tools](#2-安装-platform-tools)
- [3. 编译内核](#3-编译内核)
- [4. 备份当前 boot.img](#4-备份当前-bootimg)
- [5. 试启动(dry-run)](#5-试启动-dry-run)
- [6. 永久刷入](#6-永久刷入)
- [7. 验证](#7-验证)
- [8. 常见刷机场景](#8-常见刷机场景)
- [9. 回退](#9-回退)

---

## 前置准备

### 硬件
- Pixel 4XL 一台
- USB Type-C 数据线(确保是数据线,**不是纯充电线**)
- 能联网的 Windows / Linux / macOS 主机

### 软件
- Android SDK Platform Tools(`adb` + `fastboot`)
- 一个能跑 Linux 内核构建的环境(Ubuntu 22.04 推荐)

### Pixel 4XL 上的设置
1. 进入 **设置 → 关于手机**,连点 **版本号** 7 次开启开发者模式
2. 进入 **设置 → 系统 → 开发者选项**,开启:
   - **USB 调试**
   - **OEM 解锁**(解锁 bootloader 需要)

---

## 1. 解锁 bootloader

> ⚠️ **解锁 bootloader 会清除手机所有数据**(符合 Android 安全设计)。

1. 用数据线连接手机到电脑
2. 手机弹出 USB 调试授权,点 **允许**
3. 主机终端:
   ```bash
   adb devices
   # 应该看到设备列表

   adb reboot bootloader
   # 手机重启到 bootloader(屏幕显示 Android 机器人)

   fastboot devices
   # 应该看到设备 ID + "fastboot"
   ```
4. 解锁:
   ```bash
   fastboot flashing unlock
   ```
5. 手机屏幕显示确认界面,**音量键调到 "Yes"**,**电源键确认**
6. 手机自动重启并恢复出厂设置

### 验证解锁

```bash
# 启动到 bootloader
adb reboot bootloader

# 查看 bootloader 状态
fastboot getvar unlocked
# 应该显示 "unlocked: yes"
```

---

## 2. 安装 Platform Tools

### Linux (Ubuntu/Debian)

```bash
sudo apt install -y android-tools-adb android-tools-fastboot
```

或手动安装最新版:

```bash
mkdir -p ~/android-sdk
cd ~/android-sdk
wget https://dl.google.com/android/repository/platform-tools_r36-linux.zip
unzip platform-tools_r36-linux.zip
echo 'export PATH=$HOME/android-sdk/platform-tools:$PATH' >> ~/.bashrc
exec $SHELL  # 重载
```

### macOS

```bash
brew install --cask android-platform-tools
```

或手动:从 [Android 开发者站](https://developer.android.com/studio/releases/platform-tools) 下载 dmg。

---

## 3. 编译内核

### A. 下载预编译产物(GitHub Releases)

从本仓库的 [Releases 页面](../../releases) 找到最新版,下载:
- `boot.img` — 直接刷
- 或 `Image.gz-dtb` — 自己打包 boot.img(进阶)

### B. 本地编译

```bash
# 检查环境
./scripts/setup_env.sh

# 拉源码
./scripts/build.sh fetch

# 拆 vendor 模块(从工厂 ZIP)
python3 scripts/extract_vendor.py \
    ~/Downloads/coral-tp1a.220624.014-factory-*.zip \
    vendor_modules/

# 编译
./scripts/build.sh compile

# 产物在
ls kernel/google-coral/out/arch/arm64/boot/Image.gz-dtb
ls kernel/google-coral/out/dist/boot.img    # 如果 build.sh 自动打包
```

---

## 4. 备份当前 boot.img

**永远先备份!** 出问题能立即恢复。

```bash
./scripts/flash.sh backup boot
```

或手动:
```bash
adb reboot bootloader
mkdir -p backups
fastboot fetch backups/coral_boot_$(date +%Y%m%d).img boot
```

> 也可以从官方 factory 镜像直接提取原版 boot.img:
> ```bash
> unzip coral-tp1a.220624.014-factory-*.zip -d factory/
> cp factory/*/boot.img backups/stock_boot.img
> ```

---

## 5. 试启动(dry-run)

**强烈推荐先用 dry-run 测试**!这一步不刷写,只是临时启动新内核,断电后恢复原 boot。

```bash
./scripts/flash.sh dry-run kernel/google-coral/out/dist/boot.img
```

或手动:
```bash
adb reboot bootloader
fastboot boot kernel/google-coral/out/dist/boot.img
# 手机会从 boot.img 启动,显示 logo / Pixel 启动动画
```

启动后立刻验证:

```bash
adb shell uname -r
# 应该显示新内核版本,例如:5.10.123-android13-2-...

adb shell dmesg | grep -i "error\|fail" | head -n 20
# 查看启动日志,不应有严重错误
```

### 如果 dry-run 失败(设备卡住、循环重启)

- **手机完全黑屏**:拔数据线,长按电源键 10 秒强制关机,再 `adb reboot bootloader`。
- **循环重启**:同上,断电后重启回 bootloader。
- **不能进入 fastboot**:需要进入 recovery 或 fastbootd 模式:
  ```bash
  adb reboot recovery
  # 或
  fastboot reboot recovery
  # 然后在 recovery 里通过 sideload 刷原版 boot.img
  ```

### 如果 dry-run 成功

继续第 6 步永久刷入。

---

## 6. 永久刷入

```bash
./scripts/flash.sh boot kernel/google-coral/out/dist/boot.img
```

或手动:
```bash
adb reboot bootloader
fastboot flash boot kernel/google-coral/out/dist/boot.img
fastboot reboot
```

设备重启,会用新内核启动。

---

## 7. 验证

启动后:

```bash
# 1. 确认内核版本
adb shell uname -r
# 应显示新内核版本

# 2. 确认内核编译时间
adb shell cat /proc/version
# Linux version 5.10.123-android13-2-... (builder@host) (clang version ...) ...

# 3. 启动日志
adb shell dmesg | head -n 50

# 4. 检查模块加载
adb shell lsmod

# 5. 检查 GPU / WiFi / 摄像头等关键驱动是否正常
adb shell dumpsys SurfaceFlinger | grep "GLES"   # GPU
adb shell dumpsys wifi                            # WiFi
adb shell pm list features | grep camera          # 摄像头
```

如果一切正常,刷机完成!

---

## 8. 常见刷机场景

### 场景 A:刷 boot + vendor_dlkm(内核模块改过)

```bash
./scripts/flash.sh all kernel/google-coral/out/dist/boot.img
```

会自动:
1. 备份 boot
2. 刷 boot
3. 找 `vendor_modules/vendor_dlkm.img` 刷写 vendor_dlkm 分区
4. 找 dtbo.img 刷写 dtbo 分区(如果有)

### 场景 B:从 GitHub Release 刷

```bash
# 下载 release 的 boot.img
wget https://github.com/<owner>/<repo>/releases/download/v0.1.0/boot.img

adb reboot bootloader
fastboot flash boot boot.img
fastboot reboot
```

### 场景 C:多设备刷同一镜像

不同 Pixel 4XL 可能 dtbo 不同。先确认 dtbo:

```bash
adb shell getprop ro.boot.dtbo
# 或从 stock 工厂镜像里 grep
```

---

## 9. 回退

### 9.1 从备份恢复

```bash
./scripts/flash.sh restore backups/coral_boot_20260101_120000.img
```

### 9.2 从官方工厂镜像恢复(终极方案)

如果备份丢了 / boot 分区损坏 / 设备卡住:

```bash
# 1. 下载对应版本的 factory 镜像
# https://developers.google.com/android/images#coral

# 2. 解压
unzip coral-tp1a.220624.014-factory-*.zip -d factory/
cd factory/coral-tp1a.220624.014/

# 3. 重新刷 boot.img(以及 vendor_dlkm,如果之前也改过)
./flash-all.sh    # macOS/Linux
# 或
flash-all.bat     # Windows
```

### 9.3 强制进 EDL 模式(变砖救援)

如果连 fastboot 都不行:

1. 关机
2. 按住 **音量下 + 电源键** 直到屏幕显示 Fastboot
3. 进入 EDL 模式(如果支持):`fastboot oem edl`
4. 用 `QPST` / `QFIL` 工具刷回官方固件

---

## 常见问题

### Q:fastboot 找不到设备

```bash
# 检查 USB 连接
lsusb | grep -i "google\|qualcomm"

# 试切换 USB 端口(优先 USB 2.0,部分 USB 3.0 端口有兼容问题)
# 试换数据线

# 确认 USB 调试已开
adb devices
# 应该看到设备

# Windows:可能需要 Google USB Driver
# https://developer.android.com/studio/run/win-usb
```

### Q:boot.img 刷完后变砖

执行上面"9.3 强制进 EDL 模式"或者"9.2 工厂镜像恢复"。

### Q:内核启动了但某些功能不正常(WiFi / 相机)

通常是 vendor_dlkm 模块版本不匹配。需要确保 `vendor_modules/` 是从相同 Android 版本的工厂镜像拆出的:

```bash
# 查看本机 vendor_dlkm 信息
adb shell getprop ro.vendor.build.version.release

# 查看脚本拆出的 vendor 信息
cat vendor_modules/manifest.json | jq .
```

版本不一致 → 重新跑 `extract_vendor.py`。

### Q:如何查看当前 boot.img 是哪个版本编译的

```bash
adb shell cat /proc/version
```

会显示 `Linux version <ver> (builder@host) (clang ...)` 等信息,builder@host 对应 GitHub Actions 的 `ubuntu-22.04`。

---

## 进阶

- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — 编译期和运行期常见问题
- **[Android_Kernel_Development_Guide.md](../Android_Kernel_Development_Guide.md)** — 完整开发指南