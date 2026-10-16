# list_processes — 内核模块示例

遍历内核 `task_struct` 链表,把所有运行进程通过 `dmesg` 打印出来。

适合作为内核进程调度学习的入门例子,也展示了:
- `rcu_read_lock()` / `rcu_read_unlock()` 的并发保护
- `for_each_process()` 宏的内部原理(双向链表遍历)
- `task_struct` 关键字段(PID、TGID、comm、state、cred)

## 文件

```
examples/list_processes/
├── list_processes.c    # 内核模块源码
├── Makefile            # 编译入口
└── README.md           # 你正在读的
```

## 编译

```bash
# 1. 确认内核源码已拉
./scripts/build.sh fetch

# 2. 编译模块(Makefile 默认 KDIR=../../../kernel/google-coral)
cd examples/list_processes
make

# 产物
ls list_processes.ko
```

如果你的内核源码在不同位置:

```bash
make KDIR=/path/to/kernel/google-coral
```

## 加载到内核

> ⚠️ 这需要 **设备当前运行的就是你编译的内核**,否则模块会因为 vermagic 不匹配拒绝加载。

```bash
# (可选)推到设备
adb push list_processes.ko /data/local/tmp/

# 在设备上加载(需要 root 或 permissive SELinux)
adb shell su -c "insmod /data/local/tmp/list_processes.ko"

# 查看输出
adb shell dmesg | grep -A 200 "scanning all running"
```

或者用 Makefile 的 target:

```bash
make load        # insmod list_processes.ko
make dmesg       # 看最近 200 行模块输出
make unload      # rmmod list_processes
```

## 预期输出

```
[   28.314572] list_processes: === scanning all running processes ===
[   28.314575] list_processes:    PID  TGID  COMM              STATE      UID  CMD
[   28.314576] list_processes: -----------------------------------------------------------
[   28.314582] list_processes:       1     1  init              S (sleeping)  0  ...
[   28.314584] list_processes:       2     2  kthreadd          S (sleeping)  0  ...
[   28.314586] list_processes:     123   123  system_server     S (sleeping) 1000  ...
[   28.314588] list_processes:     456   456  com.android.phone S (sleeping) 1001  ...
[   28.314590] list_processes: -----------------------------------------------------------
[   28.314592] list_processes: list_processes: 87 processes listed
```

## 关键代码解读

### 1. 遍历 task_struct 链表

```c
rcu_read_lock();
for_each_process(task) {
    /* task 指向当前遍历到的 task_struct */
    pr_info("%d: %s\n", task_pid_nr(task), task->comm);
}
rcu_read_unlock();
```

`for_each_process` 宏展开大致是:

```c
for (task = &init_task; (task = next_task(task)) != &init_task; )
```

——即从 `init_task` 这个进程开始,沿着 `tasks` 字段构成的双向循环链表绕一圈。

### 2. RCU 锁

`task_struct` 的 `tasks` 链表字段是 RCU-protected 的(进程创建/销毁时用 `list_add_rcu` / `list_del_rcu`)。

读取时必须:
```c
rcu_read_lock();
/* 遍历 */
rcu_read_unlock();
```

否则会触发 `CONFIG_DEBUG_LIST` 的告警,或者更糟,读到已释放内存。

### 3. PID vs TGID

- **PID** (`task_pid_nr(task)`):线程 ID。Linux 里每个线程(包括主线程)都有 PID。
- **TGID** (`task_tgid_nr(task)`):线程组 ID,等于主线程的 PID,用户态 `ps` 显示的就是 TGID。

Android 一个 app 通常有几十个线程,所以遍历 PID 看到几百条,但 TGID 只有几十。

### 4. comm 字段

`task->comm` 是 16 字节的进程短名,**不包括命令行参数**。

完整命令行要从:
- 用户的 `/proc/<pid>/cmdline`(用户态读)
- 或者 `mm->arg_start` / `mm->arg_end`(内核态读,要持有 task 的 mm 锁)

```c
static int read_cmdline(struct task_struct *p, char *buf, int len)
{
    int ret = 0;
    struct mm_struct *mm = p->mm;

    if (!mm) return 0;  /* 内核线程 */
    down_read(&mm->mmap_lock);
    if (mm->arg_end > mm->arg_start && mm->arg_end - mm->arg_start < len) {
        ret = access_process_vm(p, mm->arg_start, buf,
                                mm->arg_end - mm->arg_start, FOLL_FORCE);
    }
    up_read(&mm->mmap_lock);
    return ret;
}
```

这是个进阶话题,留给 patch 来做。

## 进阶改进

要把它变成实际可用的工具,可以加:

1. **显示完整命令行**:用 `mm->arg_start` / `mm->arg_end` 读 `/proc/<pid>/cmdline`
2. **命名空间隔离**:`setns()` 到目标 namespace 再遍历(否则只能看 init namespace 的进程)
3. **CPU/内存使用率**:`task->utime` + `task->stime` + `task->nvcsw` / `task->nivcsw`
4. **proc 文件系统**:不只 print,可以挂个 `/proc/list_processes`,用户 `cat` 就能看
5. **过滤特定 UID**:只看 uid >= 1000(普通 app)

具体 patch 可以参考 `patches/` 目录规范加在项目里。

## 调试

### Q:模块加载时报 "disagrees about version of symbol module_layout"

你的内核源码版本和设备上跑的内核不一致。

```bash
adb shell uname -r           # 设备上跑的版本
# 必须跟你编译时的内核版本完全一致

# 重新编译
cd kernel/google-coral
git checkout <正确版本tag>
./scripts/build.sh clean
./scripts/build.sh compile
```

### Q:报 "Required key not available"

模块签名问题。两种方案:
1. 关闭模块签名要求:在 `coral_defconfig` 改 `CONFIG_MODULES=n` 或者开启 `CONFIG_MODULE_SIG_FORCE=n`
2. 自己签名:用自己生成的私钥签模块

### Q:报 "Operation not permitted"

SELinux 阻止了。

```bash
# 临时降级 SELinux(不推荐生产环境)
adb shell setenforce 0

# 或放 permissive 模式
adb shell su -c "setenforce 0"
```

## 延伸阅读

- [`kernel/sched/core.c`](https://elixir.bootlin.com/linux/v5.10/source/kernel/sched/core.c) — 进程调度核心
- [`include/linux/sched/signal.h`](https://elixir.bootlin.com/linux/v5.10/source/include/linux/sched/signal.h) — `for_each_process` 宏定义
- [`Documentation/scheduler/sched-design-CFS.rst`](https://www.kernel.org/doc/html/latest/scheduler/sched-design-CFS.html) — CFS 调度器设计
- [`Robert Love, Linux Kernel Development, 3rd Ed.`](https://lwn.net/KernelReview/) — 第 3 章进程管理