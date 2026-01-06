#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Automated test for passphrase generator functionality
# Tests the passphrase generation feature via sysfs interface

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

SOCKET_PATH="/tmp/mock-accel-passphrase.sock"

SSH_PORT=2224
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
    pkill -f "qemu.*mock-accel-passphrase" 2>/dev/null || true
    # Kill servers
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH"
    rm -f /tmp/qemu-passphrase-test.pid
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

if [[ ! -f "$VFIO_USER_DIR/eff_large_wordlist.txt" ]]; then
    echo -e "${RED}Error: EFF wordlist not found at $VFIO_USER_DIR/eff_large_wordlist.txt${NC}"
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}Error: sshpass not installed. Install with: sudo dnf install sshpass${NC}"
    exit 1
fi

# Remove old socket
rm -f "$SOCKET_PATH"

echo -e "${GREEN}=== Starting Passphrase Generator Test ===${NC}"
echo

# Start mock-accel-server
echo -e "${YELLOW}Starting mock-accel-server...${NC}"
cd "$VFIO_USER_DIR"
./mock-accel-server -v -u "PASSPHRASE-TEST-001" "$SOCKET_PATH" &
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
    -pidfile /tmp/qemu-passphrase-test.pid

QEMU_PID=$(cat /tmp/qemu-passphrase-test.pid)
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

# Verify passphrase sysfs attributes exist
echo -e "${YELLOW}=== Step 6: Verifying passphrase sysfs attributes ===${NC}"
ssh_cmd "ls -la /sys/class/mock-accel/mock0/ | grep passphrase" || {
    echo -e "${RED}Passphrase attributes not found${NC}"
    exit 1
}
echo -e "${GREEN}✓ Passphrase attributes exist${NC}"
echo

# Test passphrase generation with 6 words
echo -e "${YELLOW}=== Step 7: Testing passphrase generation (6 words) ===${NC}"
echo -e "${YELLOW}Setting passphrase length to 6...${NC}"
ssh_cmd "echo 6 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null"
LENGTH=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase_length")
echo -e "${YELLOW}Length set to: $LENGTH${NC}"

echo -e "${YELLOW}Triggering passphrase generation...${NC}"
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"

# Check status
STATUS=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase_status")
echo -e "${YELLOW}Passphrase status: $STATUS${NC}"

if [ "$STATUS" != "ready" ]; then
    echo -e "${RED}✗ Expected status 'ready', got '$STATUS'${NC}"
    exit 1
fi

# Read passphrase
PASSPHRASE=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")
echo -e "${GREEN}Generated passphrase: $PASSPHRASE${NC}"

# Count words in passphrase
WORD_COUNT=$(echo "$PASSPHRASE" | wc -w)
if [ "$WORD_COUNT" -ne 6 ]; then
    echo -e "${RED}✗ Expected 6 words, got $WORD_COUNT${NC}"
    exit 1
fi

# Verify count register
COUNT=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase_count")
echo -e "${YELLOW}Passphrase count: $COUNT${NC}"
if [ "$COUNT" -ne 6 ]; then
    echo -e "${RED}✗ Expected count 6, got $COUNT${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Passphrase generation successful (6 words)${NC}"
echo

# Test with 4 words
echo -e "${YELLOW}=== Step 8: Testing passphrase generation (4 words - minimum) ===${NC}"
ssh_cmd "echo 4 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null"
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"
PASSPHRASE=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")
WORD_COUNT=$(echo "$PASSPHRASE" | wc -w)
if [ "$WORD_COUNT" -ne 4 ]; then
    echo -e "${RED}✗ Expected 4 words, got $WORD_COUNT${NC}"
    exit 1
fi
echo -e "${GREEN}Generated passphrase (4 words): $PASSPHRASE${NC}"
echo -e "${GREEN}✓ Minimum length test passed${NC}"
echo

# Test with 12 words
echo -e "${YELLOW}=== Step 9: Testing passphrase generation (12 words - maximum) ===${NC}"
ssh_cmd "echo 12 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null"
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"
PASSPHRASE=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")
WORD_COUNT=$(echo "$PASSPHRASE" | wc -w)
if [ "$WORD_COUNT" -ne 12 ]; then
    echo -e "${RED}✗ Expected 12 words, got $WORD_COUNT${NC}"
    exit 1
fi
echo -e "${GREEN}Generated passphrase (12 words): $PASSPHRASE${NC}"
echo -e "${GREEN}✓ Maximum length test passed${NC}"
echo

# Test invalid length (should fail)
echo -e "${YELLOW}=== Step 10: Testing invalid length handling ===${NC}"
if ssh_cmd "echo 3 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null" 2>/dev/null; then
    echo -e "${RED}✗ Should have rejected length 3 (too small)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Rejected invalid length 3${NC}"

if ssh_cmd "echo 13 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null" 2>/dev/null; then
    echo -e "${RED}✗ Should have rejected length 13 (too large)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Rejected invalid length 13${NC}"
echo

# Test multiple generations produce different passphrases
echo -e "${YELLOW}=== Step 11: Testing randomness (multiple generations) ===${NC}"
ssh_cmd "echo 8 | sudo tee /sys/class/mock-accel/mock0/passphrase_length > /dev/null"
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"
PASSPHRASE1=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"
PASSPHRASE2=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")
ssh_cmd "echo 1 | sudo tee /sys/class/mock-accel/mock0/passphrase_generate > /dev/null"
PASSPHRASE3=$(ssh_cmd "cat /sys/class/mock-accel/mock0/passphrase")

echo -e "${YELLOW}Passphrase 1: $PASSPHRASE1${NC}"
echo -e "${YELLOW}Passphrase 2: $PASSPHRASE2${NC}"
echo -e "${YELLOW}Passphrase 3: $PASSPHRASE3${NC}"

# Check if at least 2 out of 3 are different (very unlikely to be the same by chance)
UNIQUE_COUNT=$(echo -e "$PASSPHRASE1\n$PASSPHRASE2\n$PASSPHRASE3" | sort -u | wc -l)
if [ "$UNIQUE_COUNT" -lt 2 ]; then
    echo -e "${RED}✗ All passphrases are the same, randomness issue?${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Passphrases are different (randomness verified)${NC}"
echo

# Unload module
echo -e "${YELLOW}=== Step 12: Unloading kernel module ===${NC}"
ssh_cmd "sudo rmmod mock_accel" || {
    echo -e "${RED}Failed to unload kernel module${NC}"
    exit 1
}
echo -e "${GREEN}✓ Kernel module unloaded${NC}"
echo

echo -e "${GREEN}=== All Passphrase Tests Passed! ===${NC}"
echo

echo -e "${YELLOW}Shutting down VM...${NC}"
kill $QEMU_PID 2>/dev/null || true

echo -e "${GREEN}Test complete!${NC}"
