#!/bin/bash
# Test script for static VF configuration
# Launches 1 PF + 4 VFs as separate vfio-user devices

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

SSH_PORT=2230
SSH_USER="fedora"
SSH_PASS="test123"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    pkill -f "qemu.*static-vf-test" 2>/dev/null || true
    pkill -f "mock-accel-server.*static-vf" 2>/dev/null || true
    rm -f /tmp/mock-static-vf-*.sock
    rm -f /tmp/qemu-static-vf-test.pid
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p $SSH_PORT $SSH_USER@localhost "$@" 2>/dev/null
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

echo -e "${GREEN}=== Static VF Test ===${NC}"
echo

# Start PF
echo -e "${YELLOW}Starting PF (Physical Function)...${NC}"
cd "$VFIO_USER_DIR"
./mock-accel-server -u "STATIC-VF-PF" --total-vfs 4 /tmp/mock-static-vf-pf.sock &
PF_PID=$!
echo -e "${GREEN}PF running (PID: $PF_PID)${NC}"
cd - >/dev/null

sleep 1

# Start VFs
echo -e "${YELLOW}Starting VFs (Virtual Functions)...${NC}"
for i in {0..3}; do
    cd "$VFIO_USER_DIR"
    ./mock-accel-server --vf --vf-index $i -u "STATIC-VF-$i" /tmp/mock-static-vf-$i.sock &
    VF_PID=$!
    echo -e "${GREEN}VF $i running (PID: $VF_PID)${NC}"
    cd - >/dev/null
    sleep 0.5
done

sleep 2
echo

# Build QEMU command with all devices
echo -e "${YELLOW}Starting QEMU VM with PF + 4 VFs...${NC}"

# Base QEMU command
QEMU_CMD="qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 1 \
    -display none \
    -blockdev node-name=disk0,driver=qcow2,file.driver=file,file.filename=$IMAGE_DIR/fedora-cloud.qcow2 \
    -device virtio-blk-pci,drive=disk0,bus=pcie.0 \
    -blockdev node-name=disk1,driver=raw,file.driver=file,file.filename=$IMAGE_DIR/seed.iso,read-only=on \
    -device virtio-blk-pci,drive=disk1,bus=pcie.0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
    -device virtio-net-pci,netdev=net0,bus=pcie.0"

# Add single root port for all devices (PF + VFs on same bus)
# Use multifunction to place PF at function 0, VFs at functions 1-4
QEMU_CMD="$QEMU_CMD \
    -device pcie-root-port,id=rp_sriov,bus=pcie.0,chassis=1 \
    -device '{\"driver\": \"vfio-user-pci\", \"socket\": {\"path\": \"/tmp/mock-static-vf-pf.sock\", \"type\": \"unix\"}, \"bus\": \"rp_sriov\", \"addr\": \"0.0\", \"multifunction\": true}'"

for i in {0..3}; do
    QEMU_CMD="$QEMU_CMD \
    -device '{\"driver\": \"vfio-user-pci\", \"socket\": {\"path\": \"/tmp/mock-static-vf-$i.sock\", \"type\": \"unix\"}, \"bus\": \"rp_sriov\", \"addr\": \"0.$((i+1))\"}'"
done

QEMU_CMD="$QEMU_CMD \
    -daemonize \
    -pidfile /tmp/qemu-static-vf-test.pid"

eval $QEMU_CMD

QEMU_PID=$(cat /tmp/qemu-static-vf-test.pid)
echo -e "${GREEN}QEMU started (PID: $QEMU_PID)${NC}"
echo

wait_for_ssh || exit 1
echo

echo -e "${YELLOW}=== Checking PCI devices ===${NC}"
ssh_cmd "lspci -nn | grep 1de5"
echo

echo -e "${YELLOW}=== Building and loading kernel driver ===${NC}"
ssh_cmd "sudo dnf install -y kernel-devel-\$(uname -r) gcc make" >/dev/null 2>&1
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -P $SSH_PORT -r "$KERNEL_DRIVER_DIR" "$SSH_USER@localhost:" >/dev/null 2>&1
ssh_cmd "cd kernel-driver && make" >/dev/null 2>&1
ssh_cmd "cd kernel-driver && sudo insmod mock-accel.ko"
echo -e "${GREEN}✓ Driver loaded${NC}"
echo

echo -e "${YELLOW}=== Checking sysfs devices ===${NC}"
ssh_cmd "ls -1 /sys/class/mock-accel/"
echo

echo -e "${YELLOW}=== Device details ===${NC}"
for dev in $(ssh_cmd "ls -1 /sys/class/mock-accel/"); do
    echo -e "${GREEN}$dev:${NC}"
    echo -n "  UUID:   "
    ssh_cmd "cat /sys/class/mock-accel/$dev/uuid"
    echo -n "  Memory: "
    ssh_cmd "cat /sys/class/mock-accel/$dev/memory_size"
    echo -n "  PCI:    "
    ssh_cmd "basename \$(readlink /sys/class/mock-accel/$dev/device)"
    echo
done

echo -e "${YELLOW}=== Test complete ===${NC}"
echo -e "${GREEN}Static VF configuration working!${NC}"
echo
echo "Press Ctrl+C to shut down..."
wait
