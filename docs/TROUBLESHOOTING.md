# 常见问题排查 (TROUBLESHOOTING)

构建期、CI 期、运行期常见问题汇总。

---

## 编译期

### Q1: `build.sh fetch` 卡住 / 失败

**症状**:
```
fatal: unable to access 'https://github.com/msnx/KernelSU-Pixel4XL/'
```

**排查**:
```bash
# 测试连通性
curl -I https://github.com/msnx/KernelSU-Pixel4XL

# 如果连接超时,需要配 proxy
export https_proxy=http://127.0.0.1:7890
git config --global http.proxy $https_proxy
```

如果是自建 mirror:
```bash
CORAL_REPO=https://github.com/your-fork/coral-kernel.git ./scripts/build.sh fetch
```

> **历史**:`https://android.googlesource.com/kernel/google/coral` 路径在 AOSP 上不存在
> (官方遗留分支是 `device/google/coral-kernel`,只含 device config,没有 kernel 源码)。
> CI / `scripts/build.sh` 现已默认改用 community 镜像 `msnx/KernelSU-Pixel4XL`。
> 想用其他镜像,设置 `CORAL_REPO` / `KERNEL_BRANCH` 环境变量即可。

### Q2: `error: Cannot find a v5.10 or higher kernel`

**症状**: build.config 引用了过时的内核。

**解决**:
```bash
cd kernel/google-coral
# 检查 .config 是否包含过时选项
grep -i "deprecated\|obsolete" .config | head
make ARCH=arm64 olddefconfig
```

### Q3: `bison` / `flex` / `bc` 命令找不到

```bash
# Ubuntu/Debian
sudo apt install -y bison flex bc

# macOS
brew install bison flex bc

# 或自动检测并安装
./scripts/setup_env.sh install
```

### Q4: 编译时报 `scripts/basic/fixdep: Permission denied`

```bash
# 编译产物没有执行权限
cd kernel/google-coral
find . -name "fixdep" -exec chmod +x {} \;
find . -name "conf" -exec chmod +x {} \;

# 或彻底清理重编
./scripts/build.sh clean
./scripts/build.sh compile
```

### Q5: ccache 命中率低 / 编译还是很慢

```bash
# 检查 ccache 状态
ccache -s

# 增大缓存
ccache -M 50G

# 重新编译并充分填满 ccache
./scripts/build.sh rebuild
```

### Q6: `error: too few arguments to function 'dma_map_ops'`

内核版本冲突(大概率 patch 与上游代码不匹配)。

```bash
# 1. 确认 patch 是基于哪个 commit 生成的
cd kernel/google-coral
git log --oneline | head -5

# 2. patch 应当基于这个 commit 生成
# 3. 重新基于当前 commit 生成 patch
```

### Q7: `aarch64-linux-android-gcc: command not found`

build.sh 应该会自动下载,但如果失败:

```bash
# 手动安装
cd kernel/google-coral
./build/build.sh --download-prebuilts

# 或
make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- defconfig
```

---

## extract_vendor.py

### Q1: `simg2img: not found`

脚本会自动 `git clone --branch 1.1.5` 源码并 `make`,但如果 `git` / `gcc` / `make`
缺失会失败。可手动编译:

```bash
# 手动编译(从源码,避免 upstream prebuilt URL 404)
git clone --depth=1 --branch 1.1.5 https://github.com/anestisb/android-simg2img /tmp/simg2img
make -C /tmp/simg2img
sudo install -m 0755 /tmp/simg2img/simg2img /usr/local/bin/
```

> 历史提示: 之前用的是
> `https://github.com/anestisb/android-simg2img/releases/download/v1.1.0/simg2img`
> 这个 URL,因为 upstream 从未发布 GitHub Release,会返回 404。已统一切到 git tag 源码编译。

### Q2: `debugfs: 没有那个文件或目录`

```bash
sudo apt install -y e2fsprogs
```

### Q3: 脚本找不到 `vendor_dlkm.img`

可能 factory ZIP 路径变了。看下脚本支持三种输入:
1. 工厂 ZIP:`python3 scripts/extract_vendor.py coral-xxx-factory.zip out/`
2. 已解压目录:`python3 scripts/extract_vendor.py ./factory_extracted/ out/`
3. 直接传 img:`python3 scripts/extract_vendor.py ./vendor_dlkm.img out/`

### Q4: `load_order.txt` 是空的 / 模块数太少

factory 镜像可能不包含 `modules.dep`。脚本会 fallback 到字典序。

排查:
```bash
ls vendor_modules/vendor/lib/modules/*/
ls vendor_modules/vendor/lib/modules/*/modules.dep
cat vendor_modules/vendor/lib/modules/*/modules.dep | head
```

### Q5: 工厂镜像 SHA-256 怎么算?

```bash
sha256sum coral-xxx-factory-*.zip
```

---

## GitHub Actions

### Q1: PR 触发构建失败:`FACTORY_URL` 找不到

PR from fork 默认**无 secrets 访问权限**,这是 GitHub 设计。

解决方案:
1. **避免依赖 secret**:把工厂 URL 硬编码在工作流(已经做了)
2. **或者**:要求贡献者 push 到主仓库的 PR(默认 trusted)

### Q2: `cifs: not a valid image` 在 simg2img 阶段

`vendor_dlkm.img` 格式不对,通常是 sparse image 但 magic 不对。

排查:
```bash
xxd vendor_dlkm.img | head
# sparse magic: 3aff26ed
# gzip magic: 1f8b
```

如果是 raw ext4(魔数 `53ef` 在 0x438 处):
```bash
simg2img vendor_dlkm.img vendor_dlkm.ext4
# 应该报错,说明确实不是 sparse
# 那么不需要 simg2img,直接 debugfs
```

### Q3: 构建 OOM(Out of Memory)

GitHub Actions ubuntu-22.04 runner 有 7GB RAM,5.10 内核编译够了。但极端配置可能不够。

```yaml
# 在 workflow 里改用更大 runner
runs-on: ubuntu-22.04-4core-16gb  # 16GB
# 或
runs-on: ubuntu-22.04-8core-32gb  # 32GB(需开启)
```

### Q4: ccache 缓存超限

```bash
# 在 runner 上看 ccache 状态
ccache -s | head -10

# 增加 max size(默认 20G)
ccache -M 50G
```

### Q5: build 失败但 `build.log` 没显示完整错误

build.sh 输出大量 log,GitHub Actions 默认截断。改进方法:

```yaml
- name: Build
  run: |
    cd kernel/google-coral
    BUILD_CONFIG=build.config ./build/build.sh 2>&1 | tee ../build.log
    echo "=========== last 200 lines ==========="
    tail -n 200 ../build.log
```

---

## 运行期(刷机后)

### Q1: 设备循环重启 / 卡在启动动画

**排查**:
```bash
# 1. 强制重启到 bootloader
adb reboot bootloader

# 2. dry-run 测试新内核(不刷写)
fastboot boot boot.img

# 3. 看启动 logcat
adb logcat -d > logcat.txt
grep -i "kernel\|panic\|oops" logcat.txt | head -30
```

**常见原因**:
- vendor_dlkm 版本不匹配
- 内核 config 缺关键选项(比如 CPU governor)
- patch 与上游代码不匹配

**回退**:
```bash
./scripts/flash.sh restore backups/coral_boot_*.img
```

### Q2: 内核启动了但无法连 WiFi

```bash
# 检查 vendor 模块加载情况
adb shell lsmod | grep wlan

# 检查 dmesg
adb shell dmesg | grep -i wifi

# 检查 firmware 加载
adb shell ls /vendor/firmware/wlan/
```

通常 vendor_dlkm 没正确刷,或 vendor_dlkm.img 版本不对。

### Q3: 摄像头无法启动

```bash
adb shell dmesg | grep -i camera

# 检查 CAMERA 驱动模块
adb shell lsmod | grep -i cam
```

### Q4: 充电异常 / 电池校准问题

```bash
adb shell dumpsys battery
adb shell dmesg | grep -i battery
```

### Q5: 内核启动后屏幕显示异常

可能是 display 驱动配置问题。看 dmesg:

```bash
adb shell dmesg | grep -i "panel\|dsi\|display"
```

### Q6: 系统比原版更慢 / 更耗电

- 可能 patch 加了实验性功能
- 可能 cgroup / scheduler 配置改了
- 用 perf 分析:
  ```bash
  adb shell perf record -F 99 -g -p <PID> -- sleep 10
  adb shell perf report
  ```

---

## 调试技巧

### 拿到详细启动 logcat

```bash
adb logcat -b kernel -d   # kernel buffer
adb logcat -b main -d     # main buffer
adb logcat -d > full_logcat.txt
```

### 拿到完整 dmesg

```bash
# 重启保留 dmesg,需要内核支持 CONFIG_PRINTK_TIME
adb shell dmesg -T > dmesg.log
adb shell dmesg -w  # 实时跟踪
```

### 查看内核 build 信息

```bash
adb shell uname -a
adb shell cat /proc/version
adb shell cat /proc/config.gz | gunzip | grep -i MY_FEATURE
```

### 获取运行进程

调试内核时经常需要列出所有运行进程。两个角度:**用户态** 用 `/proc`/`ps`,**内核态** 写模块遍历 `task_struct`。

### 用户态:`/proc` + `ps`

```bash
# 列出所有进程
adb shell ps -A

# 列出带详细列
adb shell ps -A -o PID,USER,PPID,VSZ,RSS,WCHAN,STAT,NAME

# 找特定进程
adb shell ps -A | grep -i com.android

# 看 CPU 占用 top 10
adb shell top -b -n 1 | head -20

# 找某进程的线程
adb shell ps -T -p <PID>

# 看某进程的命令行(完整)
adb shell cat /proc/<PID>/cmdline

# 找僵尸进程
adb shell ps -A -o PID,STAT,NAME | awk '$2 ~ /Z/'

# 看加载的内核模块
adb shell cat /proc/modules

# 看某个进程的状态(详细)
adb shell cat /proc/<PID>/status
```

项目内已封装:`./scripts/list_processes.sh`,支持 adb / 本地两种模式:

```bash
./scripts/list_processes.sh                    # 全部
./scripts/list_processes.sh 1000               # 按 UID 过滤
./scripts/list_processes.sh surfaceflinger     # 按名字过滤
./scripts/list_processes.sh --zombies          # 僵尸进程
./scripts/list_processes.sh --top 15           # CPU top 15
./scripts/list_processes.sh --threads 123      # PID 123 的所有线程
./scripts/list_processes.sh --kernel-modules   # 内核模块
./scripts/list_processes.sh --local 1000       # 在本地主机跑(非 adb)
```

### 内核态:遍历 task_struct

写内核模块遍历 `for_each_process()` 链表:

```c
#include <linux/sched/signal.h>

struct task_struct *p;
int count = 0;

rcu_read_lock();
for_each_process(p) {
    pr_info("PID %d  TGID %d  comm=%s  state=%lx\n",
            task_pid_nr(p), task_tgid_nr(p), p->comm, p->state);
    if (++count > 100) break;  // 限制输出
}
rcu_read_unlock();
```

完整示例: [`examples/list_processes/`](../examples/list_processes/README.md) — 编译后 `insmod list_processes.ko`,`dmesg` 里能看到所有进程。包含了:

- `for_each_process()` 遍历逻辑
- `rcu_read_lock/unlock` 并发保护
- `task_state_str()` 把状态位转字符串(R/S/D/T/Z/I)
- `task_uid()` 拿 UID(需要 `task_lock` 保护)
- Makefile + 加载/卸载 target

### 进阶:显示命令行

`task->comm` 只是 16 字节短名。要看完整命令行(`/proc/<pid>/cmdline`):

```c
#include <linux/mm.h>

static int read_cmdline(struct task_struct *p, char *buf, int len)
{
    struct mm_struct *mm = p->mm;
    int ret = 0;

    if (!mm) return 0;  /* 内核线程没有 mm */

    down_read(&mm->mmap_lock);
    if (mm->arg_end > mm->arg_start &&
        mm->arg_end - mm->arg_start < len) {
        ret = access_process_vm(p, mm->arg_start, buf,
                                mm->arg_end - mm->arg_start, FOLL_FORCE);
    }
    up_read(&mm->mmap_lock);
    return ret;
}
```

### Android namespace 隔离

Android 默认每个 app 一个 mount + PID namespace。`for_each_process` 只看到 init namespace 里的进程(主要是系统服务 + native 进程)。

要看所有 namespace 的进程,**只能从 `/proc/<pid>/...` 走**——遍历 `/proc/[0-9]+` 目录,readlink 看 `/proc/<pid>/ns/pid`,拿所有命名空间。

---

## 远程调试内核(KGDB)

内核需要开启 `CONFIG_KGDB`。本项目默认不开启,要自己 patch。

```bash
# 配置内核开启 KGDB
cd kernel/google-coral
./scripts/config --file .config --enable KGDB
./scripts/config --file .config --enable KGDB_SERIAL_CONSOLE
make ARCH=arm64 olddefconfig
```

---

## 仍有问题?

1. 在仓库提 [Issue](https://github.com/<owner>/<repo>/issues)
2. 附上:
   - 完整报错信息(`build.log` / `logcat.txt`)
   - `vendor_modules/manifest.json` 内容
   - 设备信息:`adb shell getprop | grep -E "ro\.build|ro\.board"`
3. 注明 commit hash / PR 编号

---

## 延伸阅读

- [Android Kernel Building 官方文档](https://source.android.com/docs/setup/build/building-kernels)
- [Linux Kernel 文档](https://www.kernel.org/doc/)
- [XDA Developers Kernel 板块](https://xdaforums.com/c/development.53/)