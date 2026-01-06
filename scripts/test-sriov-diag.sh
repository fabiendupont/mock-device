#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Diagnostic test for SR-IOV capability issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

SOCKET_PATH="/tmp/mock-accel-sriov-diag.sock"

SSH_PORT=2226
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
    pkill -f "qemu.*mock-accel-sriov-diag" 2>/dev/null || true
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH"
    rm -f /tmp/qemu-sriov-diag-test.pid
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

echo -e "${GREEN}=== SR-IOV Diagnostic Test ===${NC}"
echo

# Start mock-accel-server with SR-IOV
echo -e "${YELLOW}Starting mock-accel-server with SR-IOV (4 VFs)...${NC}"
cd "$VFIO_USER_DIR"
./mock-accel-server -v -u "SRIOV-DIAG-PF" --total-vfs 4 "$SOCKET_PATH" &
SERVER_PID=$!
cd - > /dev/null

sleep 1

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}Server failed to start${NC}"
    exit 1
fi

echo -e "${GREEN}Server running (PID: $SERVER_PID)${NC}"
echo

# Start QEMU
echo -e "${YELLOW}Starting QEMU VM...${NC}"
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 1 \
    -display none \
    -blockdev node-name=disk0,driver=qcow2,file.driver=file,file.filename="$IMAGE_DIR/fedora-cloud.qcow2" \
    -device virtio-blk-pci,drive=disk0,bus=pcie.0 \
    -blockdev node-name=disk1,driver=raw,file.driver=file,file.filename="$IMAGE_DIR/seed.iso",read-only=on \
    -device virtio-blk-pci,drive=disk1,bus=pcie.0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
    -device virtio-net-pci,netdev=net0,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pcie.0,chassis=1 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH"'", "type": "unix"}, "bus": "rp0"}' \
    -daemonize \
    -pidfile /tmp/qemu-sriov-diag-test.pid

QEMU_PID=$(cat /tmp/qemu-sriov-diag-test.pid)
echo -e "${GREEN}QEMU started (PID: $QEMU_PID)${NC}"
echo

wait_for_ssh || exit 1
echo

echo -e "${YELLOW}=== Step 1: Checking PCI device ===${NC}"
ssh_cmd "lspci -nn | grep 1de5"
echo

echo -e "${YELLOW}=== Step 2: Installing setpci ===${NC}"
ssh_cmd "sudo dnf install -y pciutils" >/dev/null 2>&1
echo

echo -e "${YELLOW}=== Step 3: Reading SR-IOV capability directly ===${NC}"
echo "Searching for SR-IOV Extended Capability (ID=0x10)..."
ssh_cmd '
PCI_DEV="01:00.0"
# Extended capabilities start at 0x100
for offset in $(seq 256 4 4095); do
    hex_offset=$(printf "0x%x" $offset)
    val=$(sudo setpci -s $PCI_DEV ${hex_offset}.l)
    cap_id=$((0x${val:6:2}${val:4:2} & 0xFFFF))
    cap_ver=$((0x${val:2:2}${val:0:2} >> 16 & 0xF))

    if [ $cap_id -eq 16 ]; then  # SR-IOV capability ID = 0x10
        echo "Found SR-IOV capability at offset $hex_offset"
        echo "  Capability header: 0x$val"

        # Read TotalVFs (offset + 0x0e, 2 bytes)
        total_vfs_offset=$((offset + 0x0e))
        total_vfs_hex=$(printf "0x%x" $total_vfs_offset)
        total_vfs_val=$(sudo setpci -s $PCI_DEV ${total_vfs_hex}.w)
        echo "  TotalVFs (offset $total_vfs_hex): 0x$total_vfs_val = $((0x$total_vfs_val))"

        # Read InitialVFs (offset + 0x0c, 2 bytes)
        initial_vfs_offset=$((offset + 0x0c))
        initial_vfs_hex=$(printf "0x%x" $initial_vfs_offset)
        initial_vfs_val=$(sudo setpci -s $PCI_DEV ${initial_vfs_hex}.w)
        echo "  InitialVFs (offset $initial_vfs_hex): 0x$initial_vfs_val = $((0x$initial_vfs_val))"

        # Read NumVFs (offset + 0x10, 2 bytes)
        num_vfs_offset=$((offset + 0x10))
        num_vfs_hex=$(printf "0x%x" $num_vfs_offset)
        num_vfs_val=$(sudo setpci -s $PCI_DEV ${num_vfs_hex}.w)
        echo "  NumVFs (offset $num_vfs_hex): 0x$num_vfs_val = $((0x$num_vfs_val))"

        break
    fi
done
'
echo

echo -e "${YELLOW}=== Step 4: Loading kernel driver ===${NC}"
ssh_cmd "sudo dnf install -y kernel-devel-\$(uname -r) gcc make" >/dev/null 2>&1
scp_to_vm "$KERNEL_DRIVER_DIR" "/home/$SSH_USER/" >/dev/null 2>&1
ssh_cmd "cd kernel-driver && make" >/dev/null 2>&1
ssh_cmd "cd kernel-driver && sudo insmod mock-accel.ko"
echo -e "${GREEN}✓ Driver loaded${NC}"
echo

echo -e "${YELLOW}=== Step 5: Checking dmesg for SR-IOV detection ===${NC}"
ssh_cmd "sudo dmesg | grep -i sriov | tail -10"
echo

echo -e "${YELLOW}=== Step 6: Checking sysfs SR-IOV attributes ===${NC}"
ssh_cmd "ls -la /sys/class/mock-accel/mock0/ | grep sriov" || echo "No sriov attributes found"
echo

echo -e "${YELLOW}=== Step 7: Reading sriov_totalvfs ===${NC}"
TOTAL_VFS=$(ssh_cmd "cat /sys/class/mock-accel/mock0/sriov_totalvfs 2>/dev/null" || echo "ERROR")
echo "sriov_totalvfs: $TOTAL_VFS"

if [ "$TOTAL_VFS" = "4" ]; then
    echo -e "${GREEN}✓ SR-IOV totalvfs correct!${NC}"
elif [ "$TOTAL_VFS" = "0" ]; then
    echo -e "${RED}✗ SR-IOV totalvfs is 0 (BUG)${NC}"
else
    echo -e "${RED}✗ Unexpected value: $TOTAL_VFS${NC}"
fi
echo

echo -e "${YELLOW}Shutting down...${NC}"
kill $QEMU_PID 2>/dev/null || true
echo -e "${GREEN}Diagnostic complete${NC}"
