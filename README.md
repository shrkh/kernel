# Pixel 4XL (coral) Android 13 内核

为 [Pixel 4XL (coral)](https://en.wikipedia.org/wiki/Pixel_4) 编译定制 Android 13 (Linux 5.10) 内核。

项目特性:

- ✅ **公开可用** — 完全基于 AOSP 公开仓库 + 工厂镜像,不依赖任何私有 device tree
- ⚡ **CI/CD** — GitHub Actions 自动构建,PR 自动产生可下载的 boot.img
- 🔌 **vendor 模块自动拆解** — 从工厂镜像 `vendor_dlkm.img` 拆出 Qualcomm 内核模块
- 🛠 **本地脚本齐备** — 不依赖 CI,本地 Linux 主机也可一键构建刷机

---

## 目录结构

```
.
├── .github/workflows/
│   └── build-coral.yml        # GitHub Actions CI(PR + tag release)
├── scripts/
│   ├── extract_vendor.py      # 从工厂镜像拆 vendor_dlkm 模块
│   ├── setup_env.sh           # 检查本地编译环境
│   ├── build.sh               # 本地构建入口
│   └── flash.sh               # 一键刷机到 Pixel 4XL
├── patches/                   # 自定义内核 patch(按 0001、0002 数字前缀排序)
│   └── README.md
├── docs/
│   ├── FLASHING.md            # 详细刷机指南(解 bootloader 等)
│   └── TROUBLESHOOTING.md     # 常见问题排查
├── .gitignore
├── Android_Kernel_Development_Guide.md   # 完整开发指南
├── CONTRIBUTING.md            # PR 流程
└── README.md                  # 你正在读的
```

---

## 快速开始

### 方案 A：使用 GitHub Actions(推荐)

最省事。所有编译在云端跑,本地只需要浏览器下载产物。

1. Fork 本仓库到你的账号
2. Settings → Secrets → 添加 `CORAL_FACTORY_URL`(工厂镜像 ZIP 链接,可选)
3. 编辑 `patches/` 里的 patch 文件,或修改 `scripts/` 里的脚本
4. 推 commit 到 main → Actions 自动构建
5. PR 触发 → Actions 构建并上传 artifact,维护者从 PR 页面底部下载 `coral-kernel-<sha>.zip`
6. 推 `v0.1.0` 之类的 tag → Actions 创建 GitHub Release,attach 完整产物

详见 [.github/workflows/build-coral.yml](.github/workflows/build-coral.yml) 和 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 方案 B：本地 Linux 主机编译

适合反复修改 + 调试内核。

```bash
# 1. 检查本地环境(Ubuntu 20.04/22.04 推荐)
./scripts/setup_env.sh

# 2. 拉取 coral 内核源码(默认 ~700MB)
./scripts/build.sh fetch

# 3. 从工厂镜像拆 vendor_dlkm 模块
python3 scripts/extract_vendor.py \
    ~/Downloads/coral-sp2a.220505.008-factory-*.zip \
    vendor_modules/

# 4. 编译内核(默认 ~25 分钟,ccache 命中后 ~5 分钟)
./scripts/build.sh compile

# 5. 刷机(确认设备已进入 fastboot)
./scripts/flash.sh boot out/dist/boot.img
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

---

## 常用命令速查

| 命令 | 作用 |
|------|------|
| `./scripts/setup_env.sh` | 检查编译环境 |
| `./scripts/build.sh fetch` | 拉取内核源码 |
| `./scripts/build.sh compile` | 编译内核 |
| `./scripts/build.sh clean` | 清理 out/ |
| `./scripts/build.sh rebuild` | clean + compile |
| `python3 scripts/extract_vendor.py <zip> <out>` | 拆 vendor 模块 |
| `./scripts/flash.sh boot <img>` | 刷 boot 分区 |
| `./scripts/flash.sh dry-run <img>` | 仅测试启动不刷写 |

---

## 文档索引

- [Android_Kernel_Development_Guide.md](Android_Kernel_Development_Guide.md) — 完整开发指南(环境、工具链、调试、FAQ)
- [docs/FLASHING.md](docs/FLASHING.md) — 详细刷机流程
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 常见问题排查
- [CONTRIBUTING.md](CONTRIBUTING.md) — 如何提 PR

---

## 兼容性

| 项目 | 要求 |
|------|------|
| 设备 | Pixel 4XL (coral) |
| 系统 | Android 13(SP2A.220505 系列) |
| 内核版本 | 5.10.x |
| 构建主机 | Ubuntu 20.04+ / 22.04 / WSL2 |
| Python | 3.6+(extract_vendor.py 需要) |

理论兼容 Android 14(`android13-5.15`、`android14-d1-release` 分支),但需自己测试,本项目目前按 13 调优。

---

## 致谢

- Google AOSP 团队的内核 build.sh 通用脚本
- [`anestisb/android-simg2img`](https://github.com/anestisb/android-simg2img) 提供 prebuilt `simg2img`
- [`nickel-jn/kernel_coral`](https://github.com/nickel-jn/kernel_coral) 等社区 fork 提供思路

---

## 免责声明

刷内核有风险。误操作可能让设备变砖,需重新刷完整 factory 镜像恢复。本项目维护者不对刷机导致的任何损失负责。务必先备份 `boot.img`、`dtbo.img`、`vendor_dlkm.img`。