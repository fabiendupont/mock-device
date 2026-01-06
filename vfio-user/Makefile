# Makefile for mock-accel-server
#
# SPDX-License-Identifier: Apache-2.0

CC ?= gcc
CFLAGS = -Wall -Wextra -O2 -g
LDFLAGS =
VERSION ?= $(shell cat ../VERSION 2>/dev/null || echo "dev")
GIT_COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# libvfio-user paths
LIBVFIO_USER_DIR ?= ../libvfio-user
LIBVFIO_USER_INC = $(LIBVFIO_USER_DIR)/include
LIBVFIO_USER_LIB = $(LIBVFIO_USER_DIR)/build/lib

CFLAGS += -I$(LIBVFIO_USER_INC)
LDFLAGS += -L$(LIBVFIO_USER_LIB) -lvfio-user -Wl,-rpath,$(shell realpath $(LIBVFIO_USER_LIB))

.PHONY: all clean

all: mock-accel-server

version.h:
	@echo "#ifndef MOCK_ACCEL_VERSION_H" > version.h
	@echo "#define MOCK_ACCEL_VERSION_H" >> version.h
	@echo "" >> version.h
	@echo "#define MOCK_ACCEL_VERSION \"$(VERSION)\"" >> version.h
	@echo "#define MOCK_ACCEL_GIT_COMMIT \"$(GIT_COMMIT)\"" >> version.h
	@echo "" >> version.h
	@echo "#endif /* MOCK_ACCEL_VERSION_H */" >> version.h

mock-accel-server: version.h mock-accel-server.c
	$(CC) $(CFLAGS) -o $@ mock-accel-server.c $(LDFLAGS)

clean:
	rm -f mock-accel-server version.h
