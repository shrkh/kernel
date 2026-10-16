# patches/

把自定义内核 patch 放这里,会在 `./scripts/build.sh compile` 时自动 `git apply`。

## 命名规则

```
0001-enable-bbr-v3.patch
0002-fix-wifi-suspend-crash.patch
0003-add-perf-harden-v4.patch
```

- **数字前缀** — 必须 4 位零填充,保证 apply 顺序
- **简短描述** — 用小写 + 连字符
- **必须 .patch 后缀** — build.sh 只 apply .patch 文件

## 如何生成 patch

```bash
cd kernel/google-coral

# 1. 切到干净分支
git checkout -b my-patches android13-d1-release

# 2. 改代码
vim drivers/net/wireless/...

# 3. 提交
git add .
git commit -m "wifi: fix power save crash"

# 4. 生成 patch
git format-patch -1 HEAD

# 5. 移到 patches/ 并重命名
mv 0001-wifi-fix-power-save-crash.patch ../../patches/
```

## apply 逻辑

`scripts/build.sh` 用 `git apply --check` 检测冲突,如果失败会回退到 `git apply --3way` 三路合并。两次都失败会报错停止构建。

所以 patch 应当:
- **基于某个稳定的 AOSP commit** 生成(不是基于其他未合并的 patch)
- **独立可测试**(不要依赖另一个 patch 的中间状态)
- **如果上游 AOSP 已合并** — 优先删本地 patch,跟 AOSP 版本

## 调试 patch apply 失败

```bash
cd kernel/google-coral
git apply --verbose ../patches/0001-some-patch.patch  # 看具体冲突位置
```

或者强制三路合并(需要 git config):
```bash
git apply --3way ../patches/0001-some-patch.patch
```

## 撤销已 apply 的 patch

```bash
cd kernel/google-coral
git apply -R ../patches/0001-some-patch.patch
```

## 不放这里的内容

- **vendor/Qualcomm 模块修改** — 这些由 `scripts/extract_vendor.py` 拆出来的模块决定,不在源码里改
- **dtb/dtbo 修改** — 需要不同的工具链(不是 git apply 能处理)
- **kernel config 改动** — 应通过修改 `arch/arm64/configs/coral_defconfig` 后重新生成 patch

## 例子

一个真实的可用 patch 模板:

```diff
From abc123def456 Mon Sep 17 00:00:00 2001
Subject: [PATCH] net: tcp: add BBR v3 congestion control support

Add support for BBR v3 (bbr_v3) module to enable modern congestion
control on Pixel 4XL Android 13. Useful for improving throughput
on high-latency networks.

Signed-off-by: Your Name <you@example.com>
---
 net/ipv4/Kconfig  |   8 ++++++++
 net/ipv4/Makefile |   1 +
 2 files changed, 9 insertions(+)

diff --git a/net/ipv4/Kconfig b/net/ipv4/Kconfig
index abcdef..123456 100644
--- a/net/ipv4/Kconfig
+++ b/net/ipv4/Kconfig
@@ -100,6 +100,14 @@ config TCP_CONG_CUBIC
        select TCP_CONG_SLOW_START
        default y
 
+config TCP_CONG_BBR_V3
+       tristate "TCP BBR v3"
+       depends on EXPERIMENTAL
+       default n
+       help
+         BBR v3 congestion control.
+
 config DEFAULT_CUBIC
        bool
        default y
diff --git a/net/ipv4/Makefile b/net/ipv4/Makefile
index abcdef..123456 100644
--- a/net/ipv4/Makefile
+++ b/net/ipv4/Makefile
@@ -10,6 +10,7 @@ obj-y     := af_inet.o arp.o devinet.o ...
 obj-$(CONFIG_TCP_CONG_BBR)       += tcp_bbr.o
 obj-$(CONFIG_TCP_CONG_BBR_V3)    += tcp_bbr_v3.o
 
 obj-$(CONFIG_TCP_CONG_CUBIC)     += tcp_cubic.o
--
2.34.1
```

apply 后跑:
```bash
cd kernel/google-coral
./scripts/config --file .config --enable TCP_CONG_BBR_V3
make ARCH=arm64 olddefconfig
```

这样才能让 Kconfig 改动生效。