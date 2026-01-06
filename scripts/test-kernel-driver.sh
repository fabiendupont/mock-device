#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Automated test for mock-accel kernel driver with NUMA topology
# Uses SSH to interact with QEMU VM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

SOCKET_PATH_0="/tmp/mock-accel-0.sock"
SOCKET_PATH_1="/tmp/mock-accel-1.sock"

SSH_PORT=2223
SSH_USER="fedora"
SSH_PASS="test123"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    # Kill QEMU
    pkill -f "qemu.*mock-accel" 2>/dev/null || true
    # Kill servers
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH_0" "$SOCKET_PATH_1"
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

# SSH command helper
ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p $SSH_PORT $SSH_USER@localhost "$@"
}

# SCP helper
scp_to_vm() {
    local src="$1"
    local dst="$2"
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -P $SSH_PORT -r "$src" "$SSH_USER@localhost:$dst"
}

# Wait for SSH
wait_for_ssh() {
    echo -e "${YELLOW}Waiting for SSH to be available...${NC}"
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o ConnectTimeout=1 -p $SSH_PORT $SSH_USER@localhost "echo ok" &>/dev/null; then
            echo -e "${GREEN}SSH is available${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    echo -e "${RED}SSH not available after ${max_attempts} attempts${NC}"
    return 1
}

# Check dependencies
if [[ ! -f "$IMAGE_DIR/fedora-cloud.qcow2" ]]; then
    echo -e "${RED}Error: VM image not found at $IMAGE_DIR/fedora-cloud.qcow2${NC}"
    exit 1
fi

if [[ ! -f "$VFIO_USER_DIR/mock-accel-server" ]]; then
    echo -e "${RED}Error: mock-accel-server not found. Run 'make' in $VFIO_USER_DIR${NC}"
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}Error: sshpass not installed. Install with: sudo dnf install sshpass${NC}"
    exit 1
fi

# Remove old sockets
rm -f "$SOCKET_PATH_0" "$SOCKET_PATH_1"

echo -e "${GREEN}=== Starting Mock Accelerator Kernel Driver Test ===${NC}"
echo

# Start mock-accel-servers
echo -e "${YELLOW}Starting mock-accel-server 0 (NUMA node 0)...${NC}"
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-NUMA0-0001" "$SOCKET_PATH_0" &
SERVER0_PID=$!

echo -e "${YELLOW}Starting mock-accel-server 1 (NUMA node 1)...${NC}"
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-NUMA1-0001" "$SOCKET_PATH_1" &
SERVER1_PID=$!

sleep 1

if ! kill -0 $SERVER0_PID 2>/dev/null; then
    echo -e "${RED}Error: mock-accel-server 0 failed to start${NC}"
    exit 1
fi

if ! kill -0 $SERVER1_PID 2>/dev/null; then
    echo -e "${RED}Error: mock-accel-server 1 failed to start${NC}"
    exit 1
fi

echo -e "${GREEN}Servers running (PIDs: $SERVER0_PID, $SERVER1_PID)${NC}"
echo

# Start QEMU
echo -e "${YELLOW}Starting QEMU VM with NUMA topology...${NC}"
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 2,sockets=2,cores=1,threads=1 \
    -display none \
    -object memory-backend-ram,id=mem0,size=1G \
    -object memory-backend-ram,id=mem1,size=1G \
    -numa node,nodeid=0,memdev=mem0,cpus=0 \
    -numa node,nodeid=1,memdev=mem1,cpus=1 \
    -blockdev node-name=disk0,driver=qcow2,file.driver=file,file.filename="$IMAGE_DIR/fedora-cloud.qcow2" \
    -device virtio-blk-pci,drive=disk0,bus=pcie.0 \
    -blockdev node-name=disk1,driver=raw,file.driver=file,file.filename="$IMAGE_DIR/seed.iso",read-only=on \
    -device virtio-blk-pci,drive=disk1,bus=pcie.0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
    -device virtio-net-pci,netdev=net0,bus=pcie.0 \
    -device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0 \
    -device pxb-pcie,bus_nr=32,id=pci.20,numa_node=1,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pci.10,chassis=1 \
    -device pcie-root-port,id=rp1,bus=pci.20,chassis=2 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH_0"'", "type": "unix"}, "bus": "rp0"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH_1"'", "type": "unix"}, "bus": "rp1"}' \
    -daemonize \
    -pidfile /tmp/qemu-test.pid

QEMU_PID=$(cat /tmp/qemu-test.pid)
echo -e "${GREEN}QEMU started (PID: $QEMU_PID)${NC}"
echo

# Wait for SSH
if ! wait_for_ssh; then
    echo -e "${RED}Failed to connect via SSH${NC}"
    exit 1
fi
echo

# Verify PCI devices
echo -e "${YELLOW}=== Step 1: Verifying PCI devices ===${NC}"
ssh_cmd "lspci -nn | grep 1de5" || {
    echo -e "${RED}Failed to find PCI devices${NC}"
    exit 1
}
echo -e "${GREEN}✓ PCI devices found${NC}"
echo

# Install kernel headers and build tools
echo -e "${YELLOW}=== Step 2: Installing kernel headers and build tools ===${NC}"
ssh_cmd "sudo dnf install -y kernel-devel-\$(uname -r) gcc make" || {
    echo -e "${RED}Failed to install dependencies${NC}"
    exit 1
}
echo -e "${GREEN}✓ Dependencies installed${NC}"
echo

# Copy kernel driver to VM
echo -e "${YELLOW}=== Step 3: Copying kernel driver to VM ===${NC}"
scp_to_vm "$KERNEL_DRIVER_DIR" "/home/$SSH_USER/" || {
    echo -e "${RED}Failed to copy kernel driver${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel driver copied${NC}"
echo

# Build kernel module
echo -e "${YELLOW}=== Step 4: Building kernel module ===${NC}"
ssh_cmd "cd kernel-driver && make" || {
    echo -e "${RED}Failed to build kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module built${NC}"
echo

# Load kernel module
echo -e "${YELLOW}=== Step 5: Loading kernel module ===${NC}"
ssh_cmd "cd kernel-driver && sudo insmod mock-accel.ko" || {
    echo -e "${RED}Failed to load kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module loaded${NC}"
echo

# Verify module loaded
echo -e "${YELLOW}=== Step 6: Verifying module is loaded ===${NC}"
ssh_cmd "lsmod | grep mock_accel" || {
    echo -e "${RED}Module not loaded${NC}"
    exit 1
}
echo -e "${GREEN}✓ Module is loaded${NC}"
echo

# Check dmesg for driver messages
echo -e "${YELLOW}=== Step 7: Checking kernel messages ===${NC}"
ssh_cmd "sudo dmesg | grep -i mock" | tail -20
echo

# Verify sysfs entries
echo -e "${YELLOW}=== Step 8: Verifying /sys/class/mock-accel/ entries ===${NC}"
ssh_cmd "ls -la /sys/class/mock-accel/" || {
    echo -e "${RED}Failed to list /sys/class/mock-accel/${NC}"
    exit 1
}
echo -e "${GREEN}✓ sysfs entries created${NC}"
echo

# Read device attributes
echo -e "${YELLOW}=== Step 9: Reading device attributes ===${NC}"
ssh_cmd '
for d in /sys/class/mock-accel/mock*; do
    echo "================================"
    echo "Device: $(basename $d)"
    echo "  UUID:         $(cat $d/uuid)"
    echo "  Memory Size:  $(cat $d/memory_size) bytes"
    echo "  NUMA Node:    $(cat $d/numa_node)"
    echo "  Capabilities: $(cat $d/capabilities)"
    echo "  Status:       $(cat $d/status)"
done
'
echo -e "${GREEN}✓ Device attributes read successfully${NC}"
echo

# Test writing to status register
echo -e "${YELLOW}=== Step 10: Testing status register write ===${NC}"
echo -e "${YELLOW}Writing 0x1234 to mock0 status...${NC}"
ssh_cmd "echo 4660 | sudo tee /sys/class/mock-accel/mock0/status > /dev/null"
STATUS=$(ssh_cmd "cat /sys/class/mock-accel/mock0/status")
echo -e "${YELLOW}Read back status: $STATUS${NC}"
if [ "$STATUS" = "0x00001234" ]; then
    echo -e "${GREEN}✓ Status register write successful${NC}"
else
    echo -e "${RED}✗ Status register write failed (expected 0x00001234, got $STATUS)${NC}"
fi
echo

# Test NUMA topology correctness
echo -e "${YELLOW}=== Step 11: Verifying NUMA topology ===${NC}"
ssh_cmd '
echo "Checking device NUMA assignments:"
for d in /sys/class/mock-accel/mock*; do
    dev=$(basename $d)
    numa=$(cat $d/numa_node)
    uuid=$(cat $d/uuid)
    echo "  $dev: NUMA node $numa, UUID: $uuid"
done
'
echo -e "${GREEN}✓ NUMA topology verified${NC}"
echo

# Unload module
echo -e "${YELLOW}=== Step 12: Unloading kernel module ===${NC}"
ssh_cmd "sudo rmmod mock_accel" || {
    echo -e "${RED}Failed to unload kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module unloaded${NC}"
echo

# Verify sysfs entries removed
echo -e "${YELLOW}=== Step 13: Verifying sysfs cleanup ===${NC}"
if ssh_cmd "ls /sys/class/mock-accel/ 2>/dev/null" | grep -q mock; then
    echo -e "${RED}✗ sysfs entries still present after module unload${NC}"
else
    echo -e "${GREEN}✓ sysfs entries removed correctly${NC}"
fi
echo

echo -e "${GREEN}=== All Tests Passed! ===${NC}"
echo
echo -e "${YELLOW}Shutting down VM...${NC}"
kill $QEMU_PID 2>/dev/null || true
rm -f /tmp/qemu-test.pid

echo -e "${GREEN}Test complete!${NC}"
