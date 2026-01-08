#!/bin/bash
# Test script for NUMA-aware 2-node cluster with mock devices using libvirt
# Each node has 2 NUMA nodes, each with 1 PF + 2 VFs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIBVIRT_DIR="$PROJECT_DIR/libvirt"
VFIO_USER_DIR="$PROJECT_DIR/vfio-user"
KERNEL_DRIVER_DIR="$PROJECT_DIR/kernel-driver"

# SSH ports for each node
SSH_PORT_NODE1=2240
SSH_PORT_NODE2=2241
SSH_USER="fedora"
SSH_PASS="test123"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"

    # Destroy VMs
    virsh -c qemu:///system destroy mock-cluster-node1 2>/dev/null || true
    virsh -c qemu:///system destroy mock-cluster-node2 2>/dev/null || true
    virsh -c qemu:///system undefine mock-cluster-node1 2>/dev/null || true
    virsh -c qemu:///system undefine mock-cluster-node2 2>/dev/null || true

    # Kill mock-accel servers
    pkill -f "mock-accel-server.*numa-cluster" 2>/dev/null || true

    # Remove sockets
    rm -f /tmp/numa-cluster-*.sock

    # Remove overlay disk images
    sudo rm -f /var/lib/libvirt/images/node1.qcow2 /var/lib/libvirt/images/node2.qcow2

    echo -e "${GREEN}Cleanup complete${NC}"
}
# Don't auto-cleanup on exit for start script
# trap cleanup EXIT

ssh_node1() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p $SSH_PORT_NODE1 $SSH_USER@localhost "$@" 2>/dev/null
}

ssh_node2() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p $SSH_PORT_NODE2 $SSH_USER@localhost "$@" 2>/dev/null
}

wait_for_ssh() {
    local port=$1
    local node_name=$2
    echo -e "${YELLOW}Waiting for SSH on $node_name (port $port)...${NC}"
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o ConnectTimeout=1 -p $port $SSH_USER@localhost "echo ok" &>/dev/null; then
            echo -e "${GREEN}SSH available on $node_name${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    echo -e "${RED}SSH timeout on $node_name${NC}"
    return 1
}

echo -e "${GREEN}=== NUMA-Aware Cluster Test (Libvirt) ===${NC}"
echo -e "${YELLOW}Topology: 2 K8s nodes × 2 NUMA nodes × (1 PF + 2 VFs)${NC}"
echo

# Start mock-accel-server processes
echo -e "${YELLOW}Starting mock-accel-server processes (12 total)...${NC}"
cd "$VFIO_USER_DIR"

# Node 1 - NUMA Node 0
echo -e "${GREEN}Node 1 - NUMA 0:${NC}"
./mock-accel-server -u "NODE1-NUMA0-PF" --total-vfs 2 \
    /tmp/numa-cluster-node1-numa0-pf.sock &>/dev/null &
echo "  PF:  PID $!"

./mock-accel-server --vf --vf-index 0 -u "NODE1-NUMA0-VF0" \
    /tmp/numa-cluster-node1-numa0-vf0.sock &>/dev/null &
echo "  VF0: PID $!"

./mock-accel-server --vf --vf-index 1 -u "NODE1-NUMA0-VF1" \
    /tmp/numa-cluster-node1-numa0-vf1.sock &>/dev/null &
echo "  VF1: PID $!"

# Node 1 - NUMA Node 1
echo -e "${GREEN}Node 1 - NUMA 1:${NC}"
./mock-accel-server -u "NODE1-NUMA1-PF" --total-vfs 2 \
    /tmp/numa-cluster-node1-numa1-pf.sock &>/dev/null &
echo "  PF:  PID $!"

./mock-accel-server --vf --vf-index 0 -u "NODE1-NUMA1-VF0" \
    /tmp/numa-cluster-node1-numa1-vf0.sock &>/dev/null &
echo "  VF0: PID $!"

./mock-accel-server --vf --vf-index 1 -u "NODE1-NUMA1-VF1" \
    /tmp/numa-cluster-node1-numa1-vf1.sock &>/dev/null &
echo "  VF1: PID $!"

# Node 2 - NUMA Node 0
echo -e "${GREEN}Node 2 - NUMA 0:${NC}"
./mock-accel-server -u "NODE2-NUMA0-PF" --total-vfs 2 \
    /tmp/numa-cluster-node2-numa0-pf.sock &>/dev/null &
echo "  PF:  PID $!"

./mock-accel-server --vf --vf-index 0 -u "NODE2-NUMA0-VF0" \
    /tmp/numa-cluster-node2-numa0-vf0.sock &>/dev/null &
echo "  VF0: PID $!"

./mock-accel-server --vf --vf-index 1 -u "NODE2-NUMA0-VF1" \
    /tmp/numa-cluster-node2-numa0-vf1.sock &>/dev/null &
echo "  VF1: PID $!"

# Node 2 - NUMA Node 1
echo -e "${GREEN}Node 2 - NUMA 1:${NC}"
./mock-accel-server -u "NODE2-NUMA1-PF" --total-vfs 2 \
    /tmp/numa-cluster-node2-numa1-pf.sock &>/dev/null &
echo "  PF:  PID $!"

./mock-accel-server --vf --vf-index 0 -u "NODE2-NUMA1-VF0" \
    /tmp/numa-cluster-node2-numa1-vf0.sock &>/dev/null &
echo "  VF0: PID $!"

./mock-accel-server --vf --vf-index 1 -u "NODE2-NUMA1-VF1" \
    /tmp/numa-cluster-node2-numa1-vf1.sock &>/dev/null &
echo "  VF1: PID $!"

cd - >/dev/null

# Wait for all socket files to be created
echo -e "${YELLOW}Waiting for socket files to be created...${NC}"
EXPECTED_SOCKETS=12
MAX_WAIT=30
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    SOCKET_COUNT=$(ls /tmp/numa-cluster-*.sock 2>/dev/null | wc -l)
    if [ "$SOCKET_COUNT" -eq "$EXPECTED_SOCKETS" ]; then
        echo -e "${GREEN}✓ All $EXPECTED_SOCKETS sockets created${NC}"
        break
    fi
    echo -e "  Waiting... ($SOCKET_COUNT/$EXPECTED_SOCKETS sockets ready)"
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ "$SOCKET_COUNT" -ne "$EXPECTED_SOCKETS" ]; then
    echo -e "${RED}✗ Timeout waiting for sockets (found $SOCKET_COUNT/$EXPECTED_SOCKETS)${NC}"
    exit 1
fi
echo

# Set socket permissions for libvirt/QEMU access
echo -e "${YELLOW}Setting socket permissions...${NC}"
for sock in /tmp/numa-cluster-*.sock; do
    chmod 666 "$sock"
done
echo -e "${GREEN}✓ Socket permissions set${NC}"
echo

# Create overlay disk images for each VM
echo -e "${YELLOW}Creating overlay disk images...${NC}"
sudo qemu-img create -f qcow2 -F qcow2 -b fedora-cloud.qcow2 \
    /var/lib/libvirt/images/node1.qcow2 >/dev/null
sudo qemu-img create -f qcow2 -F qcow2 -b fedora-cloud.qcow2 \
    /var/lib/libvirt/images/node2.qcow2 >/dev/null
echo -e "${GREEN}✓ Overlay images created${NC}"
echo

# Define and start VMs
echo -e "${YELLOW}Defining libvirt VMs...${NC}"
virsh -c qemu:///system define "$LIBVIRT_DIR/node1.xml"
virsh -c qemu:///system define "$LIBVIRT_DIR/node2.xml"
echo -e "${GREEN}✓ VMs defined${NC}"
echo

echo -e "${YELLOW}Starting VMs...${NC}"
virsh -c qemu:///system start mock-cluster-node1
echo -e "${GREEN}✓ Node 1 started${NC}"

virsh -c qemu:///system start mock-cluster-node2
echo -e "${GREEN}✓ Node 2 started${NC}"
echo

echo -e "${GREEN}=== Cluster Started Successfully! ===${NC}"
echo -e "${YELLOW}VMs are running. Access them via:${NC}"
echo -e "  Node 1 console: ${GREEN}virsh -c qemu:///system console mock-cluster-node1${NC}"
echo -e "  Node 2 console: ${GREEN}virsh -c qemu:///system console mock-cluster-node2${NC}"
echo
echo -e "${YELLOW}To stop the cluster:${NC}"
echo -e "  ${GREEN}./scripts/stop-numa-cluster.sh${NC}"
echo

# Don't wait for SSH or run tests - just leave VMs running
exit 0

# Install driver on both nodes
echo -e "${YELLOW}=== Installing kernel driver on both nodes ===${NC}"
for node in 1 2; do
    echo -e "${GREEN}Node $node:${NC}"
    if [ $node -eq 1 ]; then
        ssh_func=ssh_node1
        port=$SSH_PORT_NODE1
    else
        ssh_func=ssh_node2
        port=$SSH_PORT_NODE2
    fi

    echo "  Installing build dependencies..."
    $ssh_func "sudo dnf install -y kernel-devel-\$(uname -r) gcc make" >/dev/null 2>&1

    echo "  Copying kernel driver..."
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -P $port -r "$KERNEL_DRIVER_DIR" "$SSH_USER@localhost:" >/dev/null 2>&1

    echo "  Building driver..."
    $ssh_func "cd kernel-driver && make" >/dev/null 2>&1

    echo "  Loading driver..."
    $ssh_func "cd kernel-driver && sudo insmod mock-accel.ko"
    echo -e "  ${GREEN}✓ Driver loaded${NC}"
done
echo

# Verify NUMA topology on both nodes
echo -e "${YELLOW}=== Verifying NUMA Topology ===${NC}"
for node in 1 2; do
    echo -e "${GREEN}Node $node:${NC}"
    if [ $node -eq 1 ]; then
        ssh_func=ssh_node1
    else
        ssh_func=ssh_node2
    fi

    # Check NUMA nodes
    numa_count=$($ssh_func "ls -1d /sys/devices/system/node/node* 2>/dev/null | wc -l")
    echo "  NUMA nodes: $numa_count"

    # Check PCI devices
    pci_count=$($ssh_func "lspci -nn | grep 1de5 | wc -l")
    echo "  PCI devices (1de5): $pci_count"

    # Check mock-accel devices
    dev_count=$($ssh_func "ls -1 /sys/class/mock-accel/ 2>/dev/null | wc -l")
    echo "  Mock-accel devices: $dev_count"

    if [ "$numa_count" = "2" ] && [ "$pci_count" = "6" ] && [ "$dev_count" = "6" ]; then
        echo -e "  ${GREEN}✓ Topology verified${NC}"
    else
        echo -e "  ${RED}✗ Topology mismatch${NC}"
    fi
    echo
done

# Show detailed device topology
echo -e "${YELLOW}=== Device NUMA Topology Details ===${NC}"
for node in 1 2; do
    echo -e "${GREEN}Node $node:${NC}"
    if [ $node -eq 1 ]; then
        ssh_func=ssh_node1
    else
        ssh_func=ssh_node2
    fi

    $ssh_func 'for dev in /sys/class/mock-accel/mock*; do
        devname=$(basename $dev)
        pci=$(basename $(readlink $dev/device))
        numa=$(cat $dev/device/numa_node 2>/dev/null || echo "N/A")
        mem=$(cat $dev/memory_size)
        uuid=$(cat $dev/uuid)
        echo "  $devname: PCI=$pci NUMA=$numa Memory=$mem UUID=$uuid"
    done'
    echo
done

echo -e "${GREEN}=== Cluster Ready ===${NC}"
echo
echo "Libvirt management commands:"
echo "  virsh console mock-cluster-node1  - Console to node 1"
echo "  virsh console mock-cluster-node2  - Console to node 2"
echo "  virsh list                         - List running VMs"
echo
echo "SSH access:"
echo "  Node 1: ssh -p $SSH_PORT_NODE1 $SSH_USER@localhost (password: $SSH_PASS)"
echo "  Node 2: ssh -p $SSH_PORT_NODE2 $SSH_USER@localhost (password: $SSH_PASS)"
echo
echo "Press Ctrl+C to shut down..."
wait
