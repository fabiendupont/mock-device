# SPDX-License-Identifier: GPL-2.0
#
# Makefile for mock-accel kernel module

obj-m += mock-accel.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
VERSION ?= $(shell cat ../VERSION 2>/dev/null || echo "dev")

all:
	@# Inject version into source
	@sed -i.bak 's/#define DRV_VERSION ".*"/#define DRV_VERSION "$(VERSION)"/' mock-accel.c
	$(MAKE) -C $(KDIR) M=$(PWD) modules
	@# Restore original
	@mv mock-accel.c.bak mock-accel.c

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	@rm -f mock-accel.c.bak

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

load:
	sudo insmod mock-accel.ko

unload:
	sudo rmmod mock-accel

reload: unload load

.PHONY: all clean install load unload reload
