#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DRIVER_SRC="$PROJECT_ROOT/kernel-driver"

# SSH settings
SSH_USER="fedora"
SSH_PASS="test123"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Get VM IP addresses from libvirt
get_vm_ip() {
    local vm_name=$1
    virsh -c qemu:///system domifaddr "$vm_name" 2>/dev/null | \
        grep -oP '192\.168\.\d+\.\d+' | head -1
}

NODE1_IP=$(get_vm_ip "mock-cluster-node1")
NODE2_IP=$(get_vm_ip "mock-cluster-node2")

if [ -z "$NODE1_IP" ] || [ -z "$NODE2_IP" ]; then
    echo -e "${RED}✗ Could not get VM IP addresses${NC}"
    echo -e "  Make sure VMs are running"
    exit 1
fi

ssh_node1() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        $SSH_USER@$NODE1_IP "$@" 2>/dev/null
}

ssh_node2() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        $SSH_USER@$NODE2_IP "$@" 2>/dev/null
}

scp_node1() {
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$@" $SSH_USER@$NODE1_IP: 2>/dev/null
}

scp_node2() {
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$@" $SSH_USER@$NODE2_IP: 2>/dev/null
}

install_driver() {
    local node_num=$1
    local node_name="Node $node_num"
    local ssh_func="ssh_node$node_num"
    local scp_func="scp_node$node_num"

    echo -e "${YELLOW}Installing driver on $node_name...${NC}"

    # Install build dependencies
    echo -e "${YELLOW}  Installing kernel-devel...${NC}"
    $ssh_func "sudo dnf install -y kernel-devel make gcc" >/dev/null

    # Create remote directory
    $ssh_func "mkdir -p ~/mock-device/kernel-driver"

    # Copy driver source
    echo -e "${YELLOW}  Copying driver source...${NC}"
    $ssh_func "mkdir -p ~/mock-device/kernel-driver"
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$DRIVER_SRC/mock-accel.c" "$DRIVER_SRC/Makefile" \
        $SSH_USER@$([ $node_num -eq 1 ] && echo $NODE1_IP || echo $NODE2_IP):~/mock-device/kernel-driver/ 2>/dev/null

    # Copy firmware
    echo -e "${YELLOW}  Installing firmware...${NC}"
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$PROJECT_ROOT/vfio-user/mock-accel-wordlist.fw" \
        $SSH_USER@$([ $node_num -eq 1 ] && echo $NODE1_IP || echo $NODE2_IP):~/mock-device/ 2>/dev/null
    $ssh_func "sudo mkdir -p /lib/firmware && sudo cp ~/mock-device/mock-accel-wordlist.fw /lib/firmware/"

    # Build driver
    echo -e "${YELLOW}  Building driver...${NC}"
    $ssh_func "cd ~/mock-device/kernel-driver && make" >/dev/null

    # Load driver
    echo -e "${YELLOW}  Loading driver...${NC}"
    $ssh_func "cd ~/mock-device/kernel-driver && sudo insmod mock-accel.ko"

    # Verify devices
    DEVICE_COUNT=$($ssh_func "ls /sys/class/mock-accel/ | wc -l")
    if [ "$DEVICE_COUNT" -eq 6 ]; then
        echo -e "${GREEN}✓ Driver loaded on $node_name ($DEVICE_COUNT devices)${NC}"
    else
        echo -e "${RED}✗ Expected 6 devices, found $DEVICE_COUNT${NC}"
        return 1
    fi

    # Show device details
    echo -e "${GREEN}  Devices on $node_name:${NC}"
    $ssh_func "for d in /sys/class/mock-accel/mock*; do \
        name=\$(basename \$d); \
        numa=\$(cat \$d/device/numa_node); \
        uuid=\$(cat \$d/uuid); \
        echo \"    \$name: NUMA \$numa, UUID \$uuid\"; \
    done"
    echo
}

echo -e "${GREEN}=== Installing mock-accel Driver on Cluster ===${NC}"
echo

# Install on both nodes
install_driver 1
install_driver 2

echo -e "${GREEN}=== Driver Installation Complete ===${NC}"
echo -e "${YELLOW}Verify with:${NC}"
echo -e "  ${GREEN}kubectl get nodes -o wide${NC}"
echo -e "  ${GREEN}kubectl describe node mock-cluster-node1 | grep -A 10 'Allocated resources'${NC}"
