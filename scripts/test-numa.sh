#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Test mock-accel devices with NUMA topology in a VM
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"

SOCKET_PATH_0="/tmp/mock-accel-0.sock"
SOCKET_PATH_1="/tmp/mock-accel-1.sock"

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH_0" "$SOCKET_PATH_1"
}
trap cleanup EXIT

# Check dependencies
if [[ ! -f "$IMAGE_DIR/fedora-cloud.qcow2" ]]; then
    echo "Error: VM image not found at $IMAGE_DIR/fedora-cloud.qcow2"
    exit 1
fi

if [[ ! -f "$VFIO_USER_DIR/mock-accel-server" ]]; then
    echo "Error: mock-accel-server not found. Run 'make' in $VFIO_USER_DIR"
    exit 1
fi

# Remove old sockets
rm -f "$SOCKET_PATH_0" "$SOCKET_PATH_1"

# Start mock-accel-servers for two devices
echo "Starting mock-accel-server 0 (NUMA node 0)..."
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-NUMA0-0001" "$SOCKET_PATH_0" &
SERVER0_PID=$!

echo "Starting mock-accel-server 1 (NUMA node 1)..."
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-NUMA1-0001" "$SOCKET_PATH_1" &
SERVER1_PID=$!

sleep 1

if ! kill -0 $SERVER0_PID 2>/dev/null; then
    echo "Error: mock-accel-server 0 failed to start"
    exit 1
fi

if ! kill -0 $SERVER1_PID 2>/dev/null; then
    echo "Error: mock-accel-server 1 failed to start"
    exit 1
fi

echo "Servers running (PIDs: $SERVER0_PID, $SERVER1_PID)"
echo ""

# Start QEMU with NUMA topology
# 2 NUMA nodes with 1GB each, 1 CPU per node
# PCIe Expander Bridges (pxb-pcie) for each NUMA node
#
# IMPORTANT: Device ordering matters! All pxb-pcie devices must be defined
# before pcie-root-ports, which must be defined before vfio-user-pci devices.
echo "Starting QEMU VM with NUMA topology..."
echo "  - Login: fedora / test123"
echo "  - Once booted, run:"
echo "      lspci -nn | grep 1de5"
echo "      for d in /sys/bus/pci/devices/*/device; do"
echo "        grep -q 0x0001 \"\\\$d\" 2>/dev/null && echo \"\\\$(dirname \\\$d): NUMA \\\$(cat \\\$(dirname \\\$d)/numa_node)\""
echo "      done"
echo "  - To exit QEMU: Ctrl-A X"
echo ""

qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 2,sockets=2,cores=1,threads=1 \
    -nographic \
    -object memory-backend-ram,id=mem0,size=1G \
    -object memory-backend-ram,id=mem1,size=1G \
    -numa node,nodeid=0,memdev=mem0,cpus=0 \
    -numa node,nodeid=1,memdev=mem1,cpus=1 \
    -blockdev node-name=disk0,driver=qcow2,file.driver=file,file.filename="$IMAGE_DIR/fedora-cloud.qcow2" \
    -device virtio-blk-pci,drive=disk0,bus=pcie.0 \
    -blockdev node-name=disk1,driver=raw,file.driver=file,file.filename="$IMAGE_DIR/seed.iso",read-only=on \
    -device virtio-blk-pci,drive=disk1,bus=pcie.0 \
    -netdev user,id=net0,hostfwd=tcp::2223-:22 \
    -device virtio-net-pci,netdev=net0,bus=pcie.0 \
    -device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0 \
    -device pxb-pcie,bus_nr=32,id=pci.20,numa_node=1,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pci.10,chassis=1 \
    -device pcie-root-port,id=rp1,bus=pci.20,chassis=2 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH_0"'", "type": "unix"}, "bus": "rp0"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH_1"'", "type": "unix"}, "bus": "rp1"}'

echo ""
echo "VM exited"
