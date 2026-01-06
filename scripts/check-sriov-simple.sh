#!/bin/bash
# Simple SR-IOV check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

SOCKET_PATH="/tmp/mock-sriov-simple.sock"
SSH_PORT=2227
SSH_USER="fedora"
SSH_PASS="test123"

cleanup() {
    pkill -f "qemu.*mock-sriov-simple" 2>/dev/null || true
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH" /tmp/qemu-sriov-simple.pid
}
trap cleanup EXIT

ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p $SSH_PORT $SSH_USER@localhost "$@" 2>/dev/null
}

wait_for_ssh() {
    for i in {1..60}; do
        if ssh_cmd "echo ok" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

echo "Starting server..."
cd "$VFIO_USER_DIR"
./mock-accel-server -u "SRIOV-SIMPLE" --total-vfs 4 "$SOCKET_PATH" 2>&1 | grep -E "(Writing|Header|Readback|TotalVFs|Loaded|Mock Accelerator)" &
cd - >/dev/null

sleep 1

echo "Starting QEMU..."
qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 2G -smp 1 -display none \
    -blockdev node-name=disk0,driver=qcow2,file.driver=file,file.filename="$IMAGE_DIR/fedora-cloud.qcow2" \
    -device virtio-blk-pci,drive=disk0,bus=pcie.0 \
    -blockdev node-name=disk1,driver=raw,file.driver=file,file.filename="$IMAGE_DIR/seed.iso",read-only=on \
    -device virtio-blk-pci,drive=disk1,bus=pcie.0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
    -device virtio-net-pci,netdev=net0,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pcie.0,chassis=1 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH"'", "type": "unix"}, "bus": "rp0"}' \
    -daemonize -pidfile /tmp/qemu-sriov-simple.pid >/dev/null 2>&1

wait_for_ssh || exit 1

echo "Reading config space at 0x100..."
ssh_cmd "sudo setpci -s 01:00.0 100.l"

echo "Reading config space at 0x10e (TotalVFs offset)..."
ssh_cmd "sudo setpci -s 01:00.0 10e.w"

echo "Loading driver..."
ssh_cmd "sudo dnf install -y kernel-devel-\$(uname -r) gcc make pciutils" >/dev/null 2>&1
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -P $SSH_PORT -r "$KERNEL_DRIVER_DIR" "$SSH_USER@localhost:" >/dev/null 2>&1
ssh_cmd "cd kernel-driver && make" >/dev/null 2>&1
ssh_cmd "cd kernel-driver && sudo insmod mock-accel.ko"

echo "Checking sriov_totalvfs..."
ssh_cmd "cat /sys/class/mock-accel/mock0/sriov_totalvfs"

echo "Done"
