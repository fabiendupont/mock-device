#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Automated test for firmware management functionality
# Tests loading the wordlist firmware via request_firmware()

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

SOCKET_PATH="/tmp/mock-accel-firmware.sock"

SSH_PORT=2225
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
    pkill -f "qemu.*mock-accel-firmware" 2>/dev/null || true
    # Kill servers
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH"
    rm -f /tmp/qemu-firmware-test.pid
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

if [[ ! -f "$VFIO_USER_DIR/mock-accel-wordlist.fw" ]]; then
    echo -e "${RED}Error: Firmware file not found at $VFIO_USER_DIR/mock-accel-wordlist.fw${NC}"
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}Error: sshpass not installed. Install with: sudo dnf install sshpass${NC}"
    exit 1
fi

# Remove old socket
rm -f "$SOCKET_PATH"

echo -e "${GREEN}=== Starting Firmware Management Test ===${NC}"
echo

# Start mock-accel-server
echo -e "${YELLOW}Starting mock-accel-server...${NC}"
cd "$VFIO_USER_DIR"
./mock-accel-server -v -u "FIRMWARE-TEST-001" "$SOCKET_PATH" &
SERVER_PID=$!
cd - > /dev/null

sleep 1

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}Error: mock-accel-server failed to start${NC}"
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
    -pidfile /tmp/qemu-firmware-test.pid

QEMU_PID=$(cat /tmp/qemu-firmware-test.pid)
echo -e "${GREEN}QEMU started (PID: $QEMU_PID)${NC}"
echo

# Wait for SSH
if ! wait_for_ssh; then
    echo -e "${RED}Failed to connect via SSH${NC}"
    exit 1
fi
echo

# Verify PCI device
echo -e "${YELLOW}=== Step 1: Verifying PCI device ===${NC}"
ssh_cmd "lspci -nn | grep 1de5" || {
    echo -e "${RED}Failed to find PCI device${NC}"
    exit 1
}
echo -e "${GREEN}✓ PCI device found${NC}"
echo

# Install kernel headers and build tools
echo -e "${YELLOW}=== Step 2: Installing kernel headers and build tools ===${NC}"
ssh_cmd "sudo dnf install -y kernel-devel-\$(uname -r) gcc make" || {
    echo -e "${RED}Failed to install dependencies${NC}"
    exit 1
}
echo -e "${GREEN}✓ Dependencies installed${NC}"
echo

# Copy kernel driver and firmware to VM
echo -e "${YELLOW}=== Step 3: Copying kernel driver and firmware to VM ===${NC}"
scp_to_vm "$KERNEL_DRIVER_DIR" "/home/$SSH_USER/" || {
    echo -e "${RED}Failed to copy kernel driver${NC}"
    exit 1
}
scp_to_vm "$VFIO_USER_DIR/mock-accel-wordlist.fw" "/home/$SSH_USER/" || {
    echo -e "${RED}Failed to copy firmware${NC}"
    exit 1
}
echo -e "${GREEN}✓ Files copied${NC}"
echo

# Build kernel module
echo -e "${YELLOW}=== Step 4: Building kernel module ===${NC}"
ssh_cmd "cd kernel-driver && make" || {
    echo -e "${RED}Failed to build kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module built${NC}"
echo

# Install firmware in system firmware directory
echo -e "${YELLOW}=== Step 5: Installing firmware ===${NC}"
ssh_cmd "sudo mkdir -p /lib/firmware"
ssh_cmd "sudo cp mock-accel-wordlist.fw /lib/firmware/" || {
    echo -e "${RED}Failed to install firmware${NC}"
    exit 1
}
ssh_cmd "ls -lh /lib/firmware/mock-accel-wordlist.fw"
echo -e "${GREEN}✓ Firmware installed${NC}"
echo

# Load kernel module
echo -e "${YELLOW}=== Step 6: Loading kernel module ===${NC}"
ssh_cmd "cd kernel-driver && sudo insmod mock-accel.ko" || {
    echo -e "${RED}Failed to load kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module loaded${NC}"
echo

# Check dmesg for firmware loading
echo -e "${YELLOW}=== Step 7: Checking firmware loading in dmesg ===${NC}"
ssh_cmd "sudo dmesg | grep -i 'wordlist firmware' | tail -5"
echo

# Verify firmware attributes
echo -e "${YELLOW}=== Step 8: Verifying firmware sysfs attributes ===${NC}"
ssh_cmd "ls -la /sys/class/mock-accel/mock0/ | grep -E '(fw_version|wordlist)'" || {
    echo -e "${RED}Firmware attributes not found${NC}"
    exit 1
}
echo -e "${GREEN}✓ Firmware attributes exist${NC}"
echo

# Read firmware version
echo -e "${YELLOW}=== Step 9: Reading firmware version ===${NC}"
FW_VERSION=$(ssh_cmd "cat /sys/class/mock-accel/mock0/fw_version")
echo -e "${GREEN}Firmware version: $FW_VERSION${NC}"
if [ "$FW_VERSION" != "1.0.0" ]; then
    echo -e "${YELLOW}Warning: Expected version 1.0.0, got $FW_VERSION${NC}"
fi
echo

# Check if wordlist was loaded automatically
echo -e "${YELLOW}=== Step 10: Checking automatic firmware loading ===${NC}"
WORDLIST_LOADED=$(ssh_cmd "cat /sys/class/mock-accel/mock0/wordlist_loaded")
WORDLIST_SIZE=$(ssh_cmd "cat /sys/class/mock-accel/mock0/wordlist_size")
echo -e "${YELLOW}Wordlist loaded: $WORDLIST_LOADED${NC}"
echo -e "${YELLOW}Wordlist size: $WORDLIST_SIZE bytes${NC}"

if [ "$WORDLIST_LOADED" = "1" ]; then
    echo -e "${GREEN}✓ Firmware loaded automatically${NC}"
    if [ "$WORDLIST_SIZE" -gt 0 ]; then
        echo -e "${GREEN}✓ Firmware size is valid${NC}"
    else
        echo -e "${RED}✗ Firmware size is 0${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ Firmware not loaded${NC}"
    exit 1
fi
echo

# Test manual firmware reload
echo -e "${YELLOW}=== Step 11: Testing manual firmware reload ===${NC}"
echo -e "${YELLOW}Triggering firmware reload...${NC}"
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/load_wordlist > /dev/null" || {
    echo -e "${RED}Failed to trigger firmware reload${NC}"
    exit 1
}

WORDLIST_LOADED=$(ssh_cmd "cat /sys/class/mock-accel/mock0/wordlist_loaded")
if [ "$WORDLIST_LOADED" = "1" ]; then
    echo -e "${GREEN}✓ Firmware reloaded successfully${NC}"
else
    echo -e "${RED}✗ Firmware reload failed${NC}"
    exit 1
fi
echo

# Test that passphrase generation still works with firmware-loaded wordlist
echo -e "${YELLOW}=== Step 12: Testing passphrase generation with firmware wordlist ===${NC}"
ssh_cmd "echo 6 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null"
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"
STATUS=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase_status")
PASSPHRASE=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")

echo -e "${YELLOW}Passphrase status: $STATUS${NC}"
echo -e "${GREEN}Generated passphrase: $PASSPHRASE${NC}"

if [ "$STATUS" = "ready" ]; then
    WORD_COUNT=$(echo "$PASSPHRASE" | wc -w)
    if [ "$WORD_COUNT" -eq 6 ]; then
        echo -e "${GREEN}✓ Passphrase generation works with firmware${NC}"
    else
        echo -e "${RED}✗ Expected 6 words, got $WORD_COUNT${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ Passphrase generation failed${NC}"
    exit 1
fi
echo

# Unload module
echo -e "${YELLOW}=== Step 13: Unloading kernel module ===${NC}"
ssh_cmd "sudo rmmod mock_accel" || {
    echo -e "${RED}Failed to unload kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module unloaded${NC}"
echo

echo -e "${GREEN}=== All Firmware Tests Passed! ===${NC}"
echo

echo -e "${YELLOW}Shutting down VM...${NC}"
kill $QEMU_PID 2>/dev/null || true

echo -e "${GREEN}Test complete!${NC}"
