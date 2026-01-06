#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Automated test for SR-IOV functionality
# Tests PF with 4 VFs on NUMA node 0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

# Socket paths
SOCKET_PF_0="/tmp/mock-pf-0.sock"
SOCKET_VF_0_0="/tmp/mock-vf-0-0.sock"
SOCKET_VF_0_1="/tmp/mock-vf-0-1.sock"
SOCKET_VF_0_2="/tmp/mock-vf-0-2.sock"
SOCKET_VF_0_3="/tmp/mock-vf-0-3.sock"

SSH_PORT=2224
SSH_USER="fedora"
SSH_PASS="test123"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    pkill -f "qemu.*mock-pf" 2>/dev/null || true
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PF_0" "$SOCKET_VF_0_0" "$SOCKET_VF_0_1" "$SOCKET_VF_0_2" "$SOCKET_VF_0_3"
    rm -f /tmp/qemu-sriov-test.pid
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

# SSH helpers
ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p $SSH_PORT $SSH_USER@localhost "$@"
}

scp_to_vm() {
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -P $SSH_PORT -r "$1" "$SSH_USER@localhost:$2"
}

wait_for_ssh() {
    echo -e "${YELLOW}Waiting for SSH...${NC}"
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o ConnectTimeout=1 -p $SSH_PORT $SSH_USER@localhost "echo ok" &>/dev/null; then
            echo -e "${GREEN}SSH available${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    echo -e "${RED}SSH timeout${NC}"
    return 1
}

# Check dependencies
if [[ ! -f "$IMAGE_DIR/fedora-cloud.qcow2" ]]; then
    echo -e "${RED}Error: VM image not found${NC}"
    exit 1
fi

if [[ ! -f "$VFIO_USER_DIR/mock-accel-server" ]]; then
    echo -e "${RED}Error: mock-accel-server not found${NC}"
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}Error: sshpass not installed${NC}"
    exit 1
fi

# Clean old sockets
rm -f "$SOCKET_PF_0" "$SOCKET_VF_0_0" "$SOCKET_VF_0_1" "$SOCKET_VF_0_2" "$SOCKET_VF_0_3"

echo -e "${GREEN}=== Starting SR-IOV Test ===${NC}"
echo

# Start PF server
echo -e "${YELLOW}Starting PF server (4 VFs)...${NC}"
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-PF-NUMA0" -m 16G --total-vfs 4 "$SOCKET_PF_0" &
PF_PID=$!
sleep 1

if ! kill -0 $PF_PID 2>/dev/null; then
    echo -e "${RED}PF server failed to start${NC}"
    exit 1
fi
echo -e "${GREEN}PF server running (PID: $PF_PID)${NC}"

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

# Start QEMU with multifunction device
echo -e "${YELLOW}Starting QEMU with SR-IOV topology...${NC}"
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 2 \
    -display none \
    -object memory-backend-ram,id=mem0,size=2G \
    -numa node,nodeid=0,memdev=mem0,cpus=0-1 \
    -blockdev node-name=disk0,driver=qcow2,file.driver=file,file.filename="$IMAGE_DIR/fedora-cloud.qcow2" \
    -device virtio-blk-pci,drive=disk0,bus=pcie.0 \
    -blockdev node-name=disk1,driver=raw,file.driver=file,file.filename="$IMAGE_DIR/seed.iso",read-only=on \
    -device virtio-blk-pci,drive=disk1,bus=pcie.0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
    -device virtio-net-pci,netdev=net0,bus=pcie.0 \
    -device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pci.10,chassis=1 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PF_0"'", "type": "unix"}, "bus": "rp0", "addr": "0.0", "multifunction": true}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_VF_0_0"'", "type": "unix"}, "bus": "rp0", "addr": "0.1"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_VF_0_1"'", "type": "unix"}, "bus": "rp0", "addr": "0.2"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_VF_0_2"'", "type": "unix"}, "bus": "rp0", "addr": "0.3"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_VF_0_3"'", "type": "unix"}, "bus": "rp0", "addr": "0.4"}' \
    -daemonize \
    -pidfile /tmp/qemu-sriov-test.pid

QEMU_PID=$(cat /tmp/qemu-sriov-test.pid)
echo -e "${GREEN}QEMU started (PID: $QEMU_PID)${NC}"
echo

# Wait for SSH
if ! wait_for_ssh; then
    exit 1
fi
echo

# Verify PCI devices
echo -e "${YELLOW}=== Verifying PCI devices ===${NC}"
ssh_cmd "lspci -nn | grep 1de5"
echo -e "${GREEN}✓ PCI devices found${NC}"
echo

# Install dependencies
echo -e "${YELLOW}=== Installing dependencies ===${NC}"
ssh_cmd "sudo dnf install -y kernel-devel-\$(uname -r) gcc make" >/dev/null 2>&1
echo -e "${GREEN}✓ Dependencies installed${NC}"
echo

# Copy and build kernel driver
echo -e "${YELLOW}=== Building kernel driver ===${NC}"
scp_to_vm "$KERNEL_DRIVER_DIR" "/home/$SSH_USER/" >/dev/null 2>&1 || {
    echo -e "${RED}✗ Failed to copy kernel driver to VM${NC}"
    exit 1
}

echo -e "${YELLOW}Building kernel module...${NC}"
if ! ssh_cmd "cd kernel-driver && make"; then
    echo -e "${RED}✗ Kernel driver build failed${NC}"
    echo -e "${YELLOW}Build output:${NC}"
    ssh_cmd "cd kernel-driver && make 2>&1" || true
    exit 1
fi
echo -e "${GREEN}✓ Kernel driver built${NC}"
echo

# Load module
echo -e "${YELLOW}=== Loading kernel module ===${NC}"
ssh_cmd "cd kernel-driver && sudo insmod mock-accel.ko"
echo -e "${GREEN}✓ Module loaded${NC}"
echo

# Check initial state - all PF and VF devices should be visible (static SR-IOV)
echo -e "${YELLOW}=== Checking initial state ===${NC}"
ssh_cmd "ls /sys/class/mock-accel/"
INITIAL_COUNT=$(ssh_cmd "ls /sys/class/mock-accel/ | wc -l")
if [ "$INITIAL_COUNT" != "5" ]; then
    echo -e "${RED}✗ Expected 5 devices (1 PF + 4 VFs), found $INITIAL_COUNT${NC}"
    exit 1
fi
echo -e "${GREEN}✓ All PF and VF devices visible (static SR-IOV)${NC}"
echo

# Check SR-IOV attributes
echo -e "${YELLOW}=== Checking SR-IOV attributes ===${NC}"
TOTAL_VFS=$(ssh_cmd "cat /sys/class/mock-accel/mock0/sriov_totalvfs")
NUM_VFS=$(ssh_cmd "cat /sys/class/mock-accel/mock0/sriov_numvfs")
echo "  Total VFs: $TOTAL_VFS"
echo "  Num VFs:   $NUM_VFS"

if [ "$TOTAL_VFS" != "4" ]; then
    echo -e "${RED}✗ Expected sriov_totalvfs=4, got $TOTAL_VFS${NC}"
    exit 1
fi

if [ "$NUM_VFS" != "0" ]; then
    echo -e "${RED}✗ Expected sriov_numvfs=0, got $NUM_VFS${NC}"
    exit 1
fi
echo -e "${GREEN}✓ SR-IOV attributes correct${NC}"
echo

# Enable 2 VFs
echo -e "${YELLOW}=== Enabling 2 VFs ===${NC}"
ssh_cmd "echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs > /dev/null"
sleep 2

# Check VF devices appeared
DEVICE_COUNT=$(ssh_cmd "ls /sys/class/mock-accel/ | wc -l")
echo "  Devices: $(ssh_cmd 'ls /sys/class/mock-accel/')"

if [ "$DEVICE_COUNT" != "3" ]; then
    echo -e "${RED}✗ Expected 3 devices (1 PF + 2 VFs), found $DEVICE_COUNT${NC}"
    exit 1
fi

# Verify VF naming
if ! ssh_cmd "ls /sys/class/mock-accel/mock0_vf0" >/dev/null 2>&1; then
    echo -e "${RED}✗ VF mock0_vf0 not found${NC}"
    exit 1
fi

if ! ssh_cmd "ls /sys/class/mock-accel/mock0_vf1" >/dev/null 2>&1; then
    echo -e "${RED}✗ VF mock0_vf1 not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ VF devices created with correct naming${NC}"
echo

# Check VF attributes
echo -e "${YELLOW}=== Checking VF attributes ===${NC}"
ssh_cmd '
for d in /sys/class/mock-accel/mock0_vf*; do
    echo "$(basename $d):"
    echo "  UUID:        $(cat $d/uuid)"
    echo "  Memory:      $(cat $d/memory_size) bytes"
    echo "  NUMA node:   $(cat $d/numa_node)"
done
'
echo -e "${GREEN}✓ VF attributes readable${NC}"
echo

# Disable VFs
echo -e "${YELLOW}=== Disabling VFs ===${NC}"
ssh_cmd "echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs > /dev/null"
sleep 2

FINAL_COUNT=$(ssh_cmd "ls /sys/class/mock-accel/ | wc -l")
if [ "$FINAL_COUNT" != "1" ]; then
    echo -e "${RED}✗ Expected 1 device after disabling VFs, found $FINAL_COUNT${NC}"
    exit 1
fi
echo -e "${GREEN}✓ VFs disabled successfully${NC}"
echo

# Unload module
echo -e "${YELLOW}=== Unloading kernel module ===${NC}"
ssh_cmd "sudo rmmod mock_accel"
echo -e "${GREEN}✓ Module unloaded${NC}"
echo

echo -e "${GREEN}=== All SR-IOV Tests Passed! ===${NC}"
echo

echo -e "${YELLOW}Shutting down VM...${NC}"
kill $QEMU_PID 2>/dev/null || true

echo -e "${GREEN}SR-IOV test complete!${NC}"
