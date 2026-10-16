# list_processes — 内核模块 Makefile
#
# 默认 KDIR 指向项目内 fetch 的 coral 内核源码。可通过 KDIR= 覆盖。
#
# 用法:
#   make                    # 编译模块
#   make load               # 加载到当前运行的内核(慎用,通常需要烧 root 内核)
#   make unload             # 卸载
#   make dmesg              # 查看模块输出
#   make clean              # 清理

KDIR ?= ../../../kernel/google-coral
PWD := $(shell pwd)

obj-m := list_processes.o

EXTRA_CFLAGS += -Wall -Wno-unused-function

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# 加载 / 卸载 / 看输出(仅在你已经在跑对应内核的设备上用)
load:
	insmod list_processes.ko

unload:
	rmmod list_processes

dmesg:
	dmesg | grep -E 'list_processes' | tail -200

.PHONY: all clean load unload dmesg