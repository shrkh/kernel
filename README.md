# Pixel 4XL (coral) Android 13 内核

为 [Pixel 4XL (coral)](https://en.wikipedia.org/wiki/Pixel_4) 编译定制 Android 13 (Linux 5.10) 内核。

项目特性:

- ✅ **公开可用** — 完全基于 AOSP 公开仓库 + 工厂镜像,不依赖任何私有 device tree
- 🔐 **BakaSU + SUSFS 集成** — 工作流自动集成 KernelSU fork + SUSFS v2.3.0(可选)
- 📦 **AnyKernel3 卡刷包** — 编译完直接打包成 TWRP 卡刷包
- ⚡ **CI/CD** — GitHub Actions 单 job 完整 pipeline,PR 自动产生可下载的 boot.img
- 🔌 **vendor 模块自动拆解** — 从工厂镜像 `vendor_dlkm.img` 拆出 Qualcomm 内核模块
- 🛠 **本地脚本齐备** — 不依赖 CI,本地 Linux 主机也可一键构建刷机
- 📚 **完整文档** — 刷机、调试、内核模块示例、BakaSU 集成、CI 故障排查全覆盖

---

## 目录结构

```
.
├── .github/workflows/
│   └── build-coral.yml        # 完整 CI pipeline(BakaSU + SUSFS + AnyKernel3)
├── scripts/
│   ├── extract_vendor.py      # 从工厂镜像拆 vendor_dlkm 模块
│   ├── setup_env.sh           # 检查本地编译环境
│   ├── build.sh               # 本地构建入口
│   ├── flash.sh               # 一键刷机到 Pixel 4XL
│   └── list_processes.sh      # 设备进程查看工具
├── examples/
│   └── list_processes/        # 内核模块示例(遍历 task_struct)
├── patches/                   # 自定义内核 patch
├── docs/
│   ├── FLASHING.md            # 详细刷机指南
│   ├── TROUBLESHOOTING.md     # 常见问题排查
│   └── KERNELSU.md            # BakaSU + SUSFS 集成原理
├── .gitignore
├── Android_Kernel_Development_Guide.md
├── CONTRIBUTING.md
└── README.md
```

---

## 快速开始

### 方案 A:使用 GitHub Actions(推荐)

最省事。所有编译在云端跑,本地只需要浏览器下载产物。

**1. Fork 仓库**

Fork 本仓库到你的账号。

**2. 配置 Secrets(可选)**

Settings → Secrets and variables → Actions → 添加:

| Secret | 用途 | 默认值 |
|--------|------|--------|
| `CORAL_FACTORY_URL` | Pixel 4XL 工厂镜像 URL | 公开 stock URL |
| `BAKASU_REPO` | 自定义 BakaSU fork 仓库 | `https://github.com/tiann/KernelSU` |
| `BAKASU_BRANCH` | BakaSU 分支 | `main` |
| `SUSFS_REPO` | SUSFS 仓库 | `https://github.com/sidex15/susfs` |
| `ANYKERNEL3_REPO` | 自定义 AnyKernel3 模板 | `https://github.com/osm0sis/AnyKernel3` |

**3. 触发构建**

```bash
# 推 commit → 自动构建(PR 也算)
git push origin main

# 打 tag → 构建 + 创建 GitHub Release
git tag v0.1.0
git push origin v0.1.0

# 或 Actions 页面 → Run workflow → 选参数
```

**4. 下载产物**

- PR / push:Actions 页面底部 Artifacts 区域下载 `new-boot-<sha>` + `anykernel3-<sha>` + `build-info-<sha>`
- tag:GitHub Releases 页面下载

**5. 刷机**

- TWRP 刷 zip:用 `anykernel3-<sha>` 里的 `AnyKernel3-coral-*.zip`
- fastboot 刷 img:用 `new-boot.img` → `fastboot flash boot new-boot.img`

详见 [.github/workflows/build-coral.yml](.github/workflows/build-coral.yml)、[CONTRIBUTING.md](CONTRIBUTING.md)、[docs/KERNELSU.md](docs/KERNELSU.md)。

### 方案 B:本地 Linux 主机编译

适合反复修改 + 调试内核。

```bash
# 1. 检查本地环境
./scripts/setup_env.sh

# 2. 拉取 coral 内核源码(默认 ~700MB)
./scripts/build.sh fetch

# 3. 拆 vendor_dlkm(如果用了 GKI 模式)
python3 scripts/extract_vendor.py \
    ~/Downloads/coral-sp2a.220505.008-factory-*.zip \
    vendor_modules/

# 4. 编译内核(默认 ~25 分钟,ccache 命中后 ~5 分钟)
./scripts/build.sh compile

# 5. 刷机
./scripts/flash.sh dry-run kernel/google-coral/out/dist/boot.img  # 试启动
./scripts/flash.sh boot kernel/google-coral/out/dist/boot.img      # 永久刷入
```

更多细节见 [docs/FLASHING.md](docs/FLASHING.md)。

---

## 工作原理

### 内核来源

- 仓库: [`android.googlesource.com/kernel/google/coral`](https://android.googlesource.com/kernel/google/coral)
- 分支: `android13-d1-release`(Pixel 4XL Android 13 稳定分支)
- 配置: `arch/arm64/configs/coral_defconfig`

### 私有 device tree 问题

Google 的 `coral` 仓库里 `build/build.config.coral` 引用 `private/google-modules/`,**这个目录是私有的**。

本项目的解决方案是检测到私有引用时自动切换到 `build.config.gki`,这能编译出能在官方 Android 13 启动的内核镜像。`scripts/build.sh` 和 GitHub Actions 工作流都内置了这个 fallback。

### vendor_dlkm 模块来源

Pixel 4XL Android 13 把 Qualcomm 专有内核模块(GPU/WiFi/电池管理…)打包在 `vendor_dlkm.img` 里。

`scripts/extract_vendor.py` 把它们拆出来,产物适合作为 GitHub Actions 输入:

```
vendor_modules/
├── vendor/lib/modules/5.10.123-android13-2-.../   # 所有 .ko
├── load_order.txt                                  # 模块加载顺序(拓扑排序)
├── manifest.json                                 # 元信息
└── build.prop.txt                              # vendor build.prop 备份
```

`load_order.txt` 是由 `modules.dep` 反向拓扑排序得出的——Pixel factory 镜像里通常不带 `modules.load`,需要脚本推导。

### CI Pipeline(`build-coral.yml`)

单 job,14 个 step,完整流程:

```
[Set up job]
  检出 fork 仓库源码
  构建编译内核环境 & 创建工作目录
↓
下载 clang 11.0.1 工具链 (LLVM 官方 release)
↓
集成 BakaSU (KernelSU 分支, 内置 su)
集成 SUSFS v2.3.0 内核补丁 + 非 GKI inline hooks
↓
设置 ccache 缓存
清理 out 输出目录
↓
以原厂 stock .config 为基底,开启 BakaSU+SUSFS 配置
↓
编译 Image.gz-dtb (clang 11.0.1 + GNU binutils, 内置 BakaSU + SUSFS)
↓
打包 new-boot.img (保留原版 v2 DTB 区)
制作内核 AnyKernel3 卡刷包
↓
上传 new-boot.img
上传 AnyKernel Zip
↓
[Post]
  Post 设置 ccache 缓存
  Post 检出 fork 仓库源码
↓
tag 触发时:创建 GitHub Release(自动)
```

详细解释见 [docs/KERNELSU.md](docs/KERNELSU.md)。

---

## 常用命令速查

| 命令 | 作用 |
|------|------|
| `./scripts/setup_env.sh` | 检查编译环境 |
| `./scripts/setup_env.sh install` | 自动安装缺失依赖(Ubuntu) |
| `./scripts/build.sh fetch` | 拉取内核源码 |
| `./scripts/build.sh compile` | 编译内核 |
| `./scripts/build.sh clean` | 清理 out/ |
| `./scripts/build.sh rebuild` | clean + compile |
| `./scripts/build.sh info` | 显示工具链和源码信息 |
| `python3 scripts/extract_vendor.py <zip> <out>` | 拆 vendor 模块 |
| `./scripts/flash.sh boot <img>` | 刷 boot 分区 |
| `./scripts/flash.sh dry-run <img>` | 仅测试启动不刷写 |
| `./scripts/flash.sh backup boot` | 备份当前 boot |
| `./scripts/flash.sh restore <img>` | 从备份恢复 |
| `./scripts/list_processes.sh` | 设备进程查看 |
| `cd examples/list_processes && make` | 编译内核模块示例 |

---

## 文档索引

- [Android_Kernel_Development_Guide.md](Android_Kernel_Development_Guide.md) — 完整开发指南(环境、工具链、调试、FAQ)
- [docs/FLASHING.md](docs/FLASHING.md) — 详细刷机流程(解 bootloader、试启动、回退)
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 编译期 / 运行期 / CI 故障排查
- [docs/KERNELSU.md](docs/KERNELSU.md) — BakaSU + SUSFS 集成原理
- [CONTRIBUTING.md](CONTRIBUTING.md) — 如何提 PR
- [examples/list_processes/README.md](examples/list_processes/README.md) — 内核模块示例

---

## 兼容性

| 项目 | 要求 |
|------|------|
| 设备 | Pixel 4XL (coral) |
| 系统 | Android 13(SP2A.220505 系列) |
| 内核版本 | 5.10.x |
| 构建主机 | Ubuntu 20.04+ / 22.04 / WSL2 |
| Python | 3.6+(extract_vendor.py 需要) |
| clang(可选) | 11.0.1(工作流自动下载) |

理论兼容 Android 14(`android13-5.15`、`android14-d1-release` 分支),但需自己测试,本项目目前按 13 调优。

---

## 致谢

- Google AOSP 团队的内核 build.sh 通用脚本
- [LLVM](https://llvm.org/) 提供 clang 11.0.1
- [KernelSU](https://github.com/tiann/KernelSU) 团队
- [sidex15/susfs](https://github.com/sidex15/susfs) 提供 v2.3.0 集成
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) 卡刷包模板
- [anestisb/android-simg2img](https://github.com/anestisb/android-simg2img) 提供 prebuilt `simg2img`
- [nickel-jn/kernel_coral](https://github.com/nickel-jn/kernel_coral) 等社区 fork 提供思路

---

## 免责声明

刷内核有风险。误操作可能让设备变砖,需重新刷完整 factory 镜像恢复。

集成 BakaSU + SUSFS 等 root 方案可能:
- 违反 Google Play 服务条款(SafetyNet / Play Integrity 检测)
- 让部分 app(银行、Netflix HD)无法使用
- 让设备保修失效

本项目维护者不对使用本项目造成的任何损失负责。务必先备份原厂 `boot.img`、`dtbo.img`、`vendor_dlkm.img`。