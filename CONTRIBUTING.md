# Contributing to Pixel 4XL Kernel Project

感谢你愿意贡献!本文档解释如何提 PR、构建流程、review 标准。

---

## 工作流一览

```
改 patch / 脚本 → push 分支 → 提 PR → CI 自动构建 → maintainer 测试 → merge → tag → release
```

---

## 提 PR 的步骤

### 1. Fork & clone

```bash
git clone https://github.com/<your>/<this-repo>.git
cd <this-repo>
```

### 2. 创建分支

```bash
git checkout -b feat/your-feature-name
```

分支名建议:
- `feat/<feature>` — 新功能
- `fix/<bug>` — bug fix
- `docs/<topic>` — 文档
- `patches/<kernel-patch-name>` — 新增内核 patch

### 3. 提交修改

修改的内容最好控制在单一目标:
- **patch**: 加在 `patches/0001-my-feature.patch` 这种格式
- **脚本**: 改 `scripts/build.sh` 或 `scripts/flash.sh`
- **CI**: 改 `.github/workflows/build-coral.yml`
- **文档**: 改 `README.md` 或 `docs/*.md`

**注意**: 不要 commit 构建产物(`out/`、`.work/`、`.ccache/`、`.zip`)— 它们都已在 `.gitignore` 里。

### 4. 推分支

```bash
git add -A
git commit -m "feat: 加 XX patch 让 XX 在 5.10 内核可用"
git push origin feat/your-feature-name
```

### 5. 提 PR

在 GitHub 上点 "New Pull Request",填:
- **Title**: 简短描述
- **Body**:
  - 改了什么
  - 为什么
  - 测试方法(怎么验证构建产物能启动)
  - 截图或日志(如有)

### 6. 等 CI

PR 触发 GitHub Actions 构建。会:
1. 拉工厂镜像
2. 拆 vendor_dlkm 模块
3. 编译内核
4. 上传 `coral-kernel-<sha>` artifact

PR 页面底部 "Artifacts" 区域可以下载。**maintainer 会从这里下载测试**。

### 7. Review & merge

Reviewer 会:
- 在设备上 `fastboot boot <boot.img>` 试启动
- 检查内核版本(`adb shell uname -r`)
- 检查 dmesg 是否有错误
- 跑 30 分钟基本测试(WiFi/相机/充电)

merge 后:
- PR 会自动产生新的 commit 到 main
- 当维护者想发版时,打 tag 触发 release job

---

## Patch 编写规范

放在 `patches/` 下的 patch 必须能被 `git apply` 处理。

### 文件名约定

```
patches/
├── 0001-enable-ipv6-nat.patch
├── 0002-fix-wifi-power-save.patch
├── 0003-bbr-v3-congestion-control.patch
└── README.md
```

- **数字前缀**: 保证 apply 顺序(0001 在 0002 之前)
- **简短描述**: 描述这个 patch 干了什么
- **.patch 后缀**: build.sh 只 apply .patch 文件

### Patch 格式

```bash
# 在已 commit 的 coral 内核源码里:
cd kernel/google-coral
git checkout -b my-patches

# 改代码
vim drivers/net/wireless/...

# 提交
git add .
git commit -m "wifi: fix power save crash on suspend"

# 生成 patch
git format-patch HEAD~1 -o ../../patches/
# 移动到 patches/,重命名为 0002-xxx.patch(取决于顺序)
```

### 重复 apply

`scripts/build.sh` 用 `git apply --check` 检测冲突。如果 patch 已经 apply 过或产生冲突,会尝试 `git apply --3way` 三路合并。

如果 patch 已经被 commit 进上游 AOSP 仓库,优先删除本地 patch(用 AOSP 的版本)。

---

## 内核 patch 测试清单

每个新 patch 提交时,请在 PR body 里写:

```markdown
## 测试
- [ ] 内核编译成功(本地或 CI)
- [ ] 设备能正常启动到 home
- [ ] 相关功能验证(说明具体验证了哪项)
- [ ] dmesg | grep -i error 无新增错误
```

---

## 脚本修改规范

`scripts/` 下的脚本必须:
- **POSIX 兼容或 bash** — 顶部 `#!/usr/bin/env bash`
- **set -euo pipefail** — 任何错误立即退出
- **彩色日志** — 使用 `log/ok/warn/die` 函数风格
- **跨平台** — 至少 Linux 上能跑
- **可重入** — 跑两遍不出问题

提交前本地测试:
```bash
shellcheck scripts/*.sh  # 如果装了 shellcheck
bash -n scripts/build.sh  # 语法检查
./scripts/build.sh info
```

---

## Review 准则

| 项 | 标准 |
|----|------|
| 编译 | CI 必须绿 |
| 测试 | Reviewer 在真机验证 |
| patch 风格 | 符合 AOSP 内核 coding style(参见 Documentation/process/coding-style.rst) |
| 文档 | 改 patch 必须更新对应 docs/*.md |
| commit message | 简洁,动词开头:`feat:` / `fix:` / `docs:` / `refactor:` |

---

## Release 流程(仅 maintainer)

1. 合并所有待发版 commit
2. 打 tag:`git tag v0.1.0 && git push origin v0.1.0`
3. GitHub Actions 自动:
   - 跑构建
   - 创建 GitHub Release(attach 产物)
4. 在 release 描述里填写 changelog
5. 在 XDA / 相关社区发帖

tag 命名:
- `v0.1.0` — 首发
- `v0.1.1` — bug fix
- `v0.2.0` — 加新 patch
- `v1.0.0-rc1` — 1.0 候选

---

## 沟通

- **Bug 报告**: GitHub Issues
- **功能请求**: GitHub Issues + `enhancement` label
- **紧急问题**: 不支持紧急通道,但维护者会尽量在 48 小时内回应

---

## 许可证

提交 PR 即代表同意按本仓库的 LICENSE 文件发布贡献。

非 trival 的 patch(>50 行),请在 commit 里加 `Signed-off-by:` 行(DCO):

```
feat: add XXX

Signed-off-by: Your Name <your@email.com>
```

---

感谢贡献!