#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Test mock-accel device in a VM
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="$PROJECT_DIR/test/images"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"

SOCKET_PATH="/tmp/mock-accel-test.sock"

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f "$SOCKET_PATH"
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

# Remove old socket
rm -f "$SOCKET_PATH"

# Start mock-accel-server
echo "Starting mock-accel-server..."
"$VFIO_USER_DIR/mock-accel-server" -v -u "MOCK-TEST-0001" "$SOCKET_PATH" &
SERVER_PID=$!
sleep 1

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Error: mock-accel-server failed to start"
    exit 1
fi

echo "Server running (PID: $SERVER_PID)"
echo ""

# Start QEMU
echo "Starting QEMU VM..."
echo "  - Login: fedora / test123"
echo "  - Once booted, run: lspci -nn | grep 1de5"
echo "  - To exit QEMU: Ctrl-A X"
echo ""

qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 2G \
    -smp 2 \
    -nographic \
    -drive file="$IMAGE_DIR/fedora-cloud.qcow2",format=qcow2,if=virtio \
    -drive file="$IMAGE_DIR/seed.iso",format=raw,if=virtio \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "'"$SOCKET_PATH"'", "type": "unix"}}' \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0

echo ""
echo "VM exited"
