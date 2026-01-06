#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Simple SR-IOV test - manual verification
# Starts PF + VFs, launches QEMU, provides instructions for manual testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"

# Socket paths
SOCKET_PF_0="/tmp/mock-pf-0.sock"
SOCKET_VF_0_0="/tmp/mock-vf-0-0.sock"
SOCKET_VF_0_1="/tmp/mock-vf-0-1.sock"
SOCKET_VF_0_2="/tmp/mock-vf-0-2.sock"
SOCKET_VF_0_3="/tmp/mock-vf-0-3.sock"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PF_0" "$SOCKET_VF_0_0" "$SOCKET_VF_0_1" "$SOCKET_VF_0_2" "$SOCKET_VF_0_3"
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

# Clean old sockets
rm -f "$SOCKET_PF_0" "$SOCKET_VF_0_0" "$SOCKET_VF_0_1" "$SOCKET_VF_0_2" "$SOCKET_VF_0_3"

echo -e "${GREEN}=== Starting SR-IOV Mock Devices ===${NC}"
echo

# Start PF server
echo -e "${YELLOW}Starting PF server (4 VFs)...${NC}"
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-PF-NUMA0" -m 16G --total-vfs 4 "$SOCKET_PF_0" &
PF_PID=$!
sleep 1

echo -e "${GREEN}PF server running (PID: $PF_PID)${NC}"
echo

# Start VF servers
echo -e "${YELLOW}Starting VF servers...${NC}"
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-VF-0-NUMA0" -m 2G --vf "$SOCKET_VF_0_0" &
VF0_PID=$!
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-VF-1-NUMA0" -m 2G --vf "$SOCKET_VF_0_1" &
VF1_PID=$!
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-VF-2-NUMA0" -m 2G --vf "$SOCKET_VF_0_2" &
VF2_PID=$!
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-VF-3-NUMA0" -m 2G --vf "$SOCKET_VF_0_3" &
VF3_PID=$!
sleep 1

echo -e "${GREEN}VF servers running (PIDs: $VF0_PID, $VF1_PID, $VF2_PID, $VF3_PID)${NC}"
echo

echo -e "${GREEN}=== Servers Ready! ===${NC}"
echo
echo "You can now start QEMU manually with this command:"
echo
cat << 'QEMUCMD'
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 2 \
    -nographic \
    -object memory-backend-ram,id=mem0,size=2G \
    -numa node,nodeid=0,memdev=mem0,cpus=0-1 \
    -drive file=test/images/fedora-cloud.qcow2,if=virtio \
    -drive file=test/images/seed.iso,if=virtio,media=cdrom \
    -netdev user,id=net0,hostfwd=tcp::2224-:22 \
    -device virtio-net-pci,netdev=net0 \
    -device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pci.10,chassis=1 \
    -device vfio-user-pci,socket=/tmp/mock-pf-0.sock,bus=rp0,addr=0.0,multifunction=on \
    -device vfio-user-pci,socket=/tmp/mock-vf-0-0.sock,bus=rp0,addr=0.1 \
    -device vfio-user-pci,socket=/tmp/mock-vf-0-1.sock,bus=rp0,addr=0.2 \
    -device vfio-user-pci,socket=/tmp/mock-vf-0-2.sock,bus=rp0,addr=0.3 \
    -device vfio-user-pci,socket=/tmp/mock-vf-0-3.sock,bus=rp0,addr=0.4
QEMUCMD
echo
echo "Inside the VM, run these commands to test SR-IOV:"
echo
cat << 'VMCMDS'
# Build and load kernel module
cd /path/to/kernel-driver
make
sudo insmod mock-accel.ko

# Check initial state - only PF visible
ls /sys/class/mock-accel/
# Should show: mock0

# Check SR-IOV attributes
cat /sys/class/mock-accel/mock0/sriov_totalvfs
# Should show: 4

cat /sys/class/mock-accel/mock0/sriov_numvfs
# Should show: 0

# Enable 2 VFs
echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs

# Check VFs appeared
ls /sys/class/mock-accel/
# Should show: mock0  mock0_vf0  mock0_vf1

# Check VF attributes
cat /sys/class/mock-accel/mock0_vf0/uuid
cat /sys/class/mock-accel/mock0_vf0/memory_size

# Disable VFs
echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs

# Unload module
sudo rmmod mock_accel
VMCMDS
echo
echo -e "${YELLOW}Servers will keep running until you press Ctrl+C${NC}"
echo

# Wait for interrupt
wait $PF_PID
