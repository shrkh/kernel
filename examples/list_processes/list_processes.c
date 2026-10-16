// SPDX-License-Identifier: GPL-2.0
/*
 * list_processes.c — 内核模块示例:遍历内核 task_struct 链表,打印运行进程
 *
 * 这是学习 Linux 内核进程调度的入门示例。展示了:
 *   - 用 for_each_process() 遍历 task 链表
 *   - rcu_read_lock/unlock 保护并发访问
 *   - 从内核 log (dmesg) 输出
 *
 * 编译方法:参见 Makefile 和 README.md
 * 加载后:   dmesg | tail -200  可看到所有运行进程
 */

#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/sched/task.h>
#include <linux/pid.h>
#include <linux/rcupdate.h>
#include <linux/cred.h>
#include <linux/fs.h>

#define LIST_MAX     1024     // 最多列出进程数(防止日志爆炸)
#define LINE_FMT     "%6d  %-5d  %-16s  %-8s  %6ld  %s\n"

/*
 * 进程状态字符映射(task_state_array 顺序定义)
 * 注意:R = running, S = sleeping, D = uninterruptible sleep,
 *      T = stopped, t = tracing stop, Z = zombie, X = dead,
 *      I = idle
 */
static const char *task_state_str(long state)
{
    static const char * const names[] = {
        "R (running)",      /* 0 */
        "S (sleeping)",     /* 1 */
        "D (disk sleep)",   /* 2 */
        "T (stopped)",      /* 4 */
        "t (tracing stop)", /* 8 */
        "Z (zombie)",       /* 16 */
        "X (dead)",         /* 32 */
        "I (idle)",         /* 64 */
    };
    int i;

    for (i = 0; i < ARRAY_SIZE(names); i++) {
        if (state & (1UL << i))
            return names[i];
    }
    return "?";
}

/* 把进程状态位转成单字符(R/S/D/T/Z/I 等),类似 ps STAT 列 */
static char state_char(long state)
{
    if (state & 64) return 'I';   /* idle */
    if (state & 16) return 'Z';   /* zombie */
    if (state & 8)  return 't';   /* tracing stop */
    if (state & 4)  return 'T';   /* stopped */
    if (state & 2)  return 'D';   /* disk sleep */
    if (state & 1)  return 'S';   /* sleeping */
    if (state & 0)  return 'R';   /* running */
    return '?';
}

/* 获取 task 的用户命名空间 UID(简化版:取真实 uid) */
static uid_t task_uid(struct task_struct *p)
{
    const struct cred *cred;
    uid_t uid;

    task_lock(p);
    cred = __task_cred(p);
    uid = from_kuid_munged(&init_user_ns, cred->uid);
    task_unlock(p);
    return uid;
}

/*
 * 模块加载时执行:打印所有进程
 */
static int __init list_processes_init(void)
{
    struct task_struct *task;
    int count = 0;
    int total = 0;

    pr_info("=== list_processes: scanning all running processes ===\n");
    pr_info(LINE_FMT, "PID", "TGID", "COMM", "STATE", "UID", "CMD");
    pr_info("-----------------------------------------------------------------------\n");

    /*
     * rcu_read_lock:在内核 RCU 临界区里遍历链表。
     * for_each_process 是定义在 <linux/sched/signal.h> 的循环宏,等价于:
     *     for (p = &init_task; (p = next_task(p)) != &init_task; )
     *
     * 注意:这只能看到 init_task 所在 namespace 的进程。Android 默认每个 app
     * 一个 namespace,需要 setns() 或者看 /proc 才行——这里只演示普通遍历。
     */
    rcu_read_lock();
    for_each_process(task) {
        if (++total > LIST_MAX) {
            pr_info("... (truncated at %d, total > %d)\n", count, LIST_MAX);
            break;
        }

        /*
         * get_task_comm 复制 task->comm 到 buffer(线程名)。
         * 注意:task->comm 是 16 字节长,会被截断。
         */
        pr_info(LINE_FMT,
                task_pid_nr(task),                /* PID */
                task_tgid_nr(task),               /* TGID(主线程 ID) */
                task->comm,                       /* comm(短名) */
                task_state_str(task->state),      /* STATE 字符串 */
                (long)task_uid(task),             /* UID */
                task_state_str(task->state));     /* 占位:实际命令行需要 argv */

        count++;
    }
    rcu_read_unlock();

    pr_info("-----------------------------------------------------------------------\n");
    pr_info("list_processes: %d processes listed\n", count);

    return 0;
}

/*
 * 模块卸载时执行(可选)
 */
static void __exit list_processes_exit(void)
{
    pr_info("list_processes: unloaded\n");
}

module_init(list_processes_init);
module_exit(list_processes_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Pixel 4XL Kernel Project");
MODULE_DESCRIPTION("Traverse task_struct list and dump all running processes");
MODULE_VERSION("1.0");