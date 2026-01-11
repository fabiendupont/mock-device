# Multi-stage build for mock-accel kernel module
# Build stage: compile the kernel module
FROM registry.fedoraproject.org/fedora:43 AS builder

ARG KERNEL_VERSION

# Install build dependencies
# If KERNEL_VERSION is "latest" or empty, install latest kernel-devel
# Otherwise, install specific version
RUN if [ "${KERNEL_VERSION}" = "latest" ] || [ -z "${KERNEL_VERSION}" ]; then \
        dnf install -y kernel-devel gcc make && dnf clean all; \
    else \
        dnf install -y kernel-devel-${KERNEL_VERSION} gcc make && dnf clean all; \
    fi

# Auto-detect kernel version if not specified or set to "latest"
RUN if [ "${KERNEL_VERSION}" = "latest" ] || [ -z "${KERNEL_VERSION}" ]; then \
        DETECTED_VERSION=$(ls -1 /usr/src/kernels/ | head -n1); \
        echo "export KERNEL_VERSION=${DETECTED_VERSION}" > /tmp/kernel_version.sh; \
    else \
        echo "export KERNEL_VERSION=${KERNEL_VERSION}" > /tmp/kernel_version.sh; \
    fi

# Copy source files
WORKDIR /build
COPY kernel-driver/mock-accel.c kernel-driver/Makefile ./

# Build the kernel module
RUN . /tmp/kernel_version.sh && make KDIR=/usr/src/kernels/${KERNEL_VERSION}

# Final stage: minimal image with only runtime dependencies
FROM registry.fedoraproject.org/fedora-minimal:43

ARG KERNEL_VERSION

# Install only kmod (provides modprobe)
RUN microdnf install -y kmod && microdnf clean all

# Copy kernel version detection from builder
COPY --from=builder /tmp/kernel_version.sh /tmp/kernel_version.sh

# Create module directory (KMM expects /opt/lib/modules)
RUN . /tmp/kernel_version.sh && mkdir -p /opt/lib/modules/${KERNEL_VERSION}/extra

# Copy kernel module from builder
COPY --from=builder /build/mock-accel.ko /tmp/mock-accel.ko

# Move module to correct location based on detected version
RUN . /tmp/kernel_version.sh && \
    mv /tmp/mock-accel.ko /opt/lib/modules/${KERNEL_VERSION}/extra/

# Copy firmware into the container image
COPY charts/mock-device/firmware/mock-accel-wordlist.txt /lib/firmware/

# Run depmod to update module dependencies
RUN . /tmp/kernel_version.sh && depmod -a -b /opt ${KERNEL_VERSION}

# Load module and sleep
CMD ["sh", "-c", "modprobe mock-accel && sleep infinity"]
