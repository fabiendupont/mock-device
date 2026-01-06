#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

NODE1_IP=""
NODE2_IP=""

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

wait_for_ssh() {
    local ip=$1
    local node_name=$2
    echo -e "${YELLOW}Waiting for SSH on $node_name ($ip)...${NC}"
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o ConnectTimeout=1 $SSH_USER@$ip "echo ok" &>/dev/null; then
            echo -e "${GREEN}✓ SSH available on $node_name${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    echo -e "${RED}✗ SSH timeout on $node_name${NC}"
    return 1
}

echo -e "${GREEN}=== Setting up k3s Cluster ===${NC}"
echo

# Get VM IP addresses from libvirt
echo -e "${YELLOW}Getting VM IP addresses...${NC}"
NODE1_IP=$(get_vm_ip "mock-cluster-node1")
NODE2_IP=$(get_vm_ip "mock-cluster-node2")

if [ -z "$NODE1_IP" ] || [ -z "$NODE2_IP" ]; then
    echo -e "${RED}✗ Could not get VM IP addresses${NC}"
    echo -e "  Make sure VMs are running and have network connectivity"
    exit 1
fi
echo -e "${GREEN}✓ Node 1: $NODE1_IP${NC}"
echo -e "${GREEN}✓ Node 2: $NODE2_IP${NC}"
echo

# Wait for both nodes to be accessible
wait_for_ssh $NODE1_IP "Node 1" || exit 1
wait_for_ssh $NODE2_IP "Node 2" || exit 1
echo

# Set SELinux to permissive mode on both nodes (required for KMM module loading)
echo -e "${YELLOW}Configuring SELinux to permissive mode...${NC}"
ssh_node1 "sudo setenforce 0"
ssh_node2 "sudo setenforce 0"
echo -e "${GREEN}✓ SELinux set to permissive${NC}"
echo

# Install k3s on Node 1 (server) with crun as default runtime
echo -e "${YELLOW}Installing k3s server on Node 1 with crun runtime...${NC}"
ssh_node1 "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.2+k3s1 sh -s - server \
    --disable=traefik \
    --node-name=mock-cluster-node1 \
    --advertise-address=$NODE1_IP \
    --flannel-iface=enp1s0 \
    --default-runtime crun"

# Wait for k3s to be ready
echo -e "${YELLOW}Waiting for k3s server to be ready...${NC}"
for i in {1..30}; do
    if ssh_node1 "sudo k3s kubectl get nodes 2>/dev/null" &>/dev/null; then
        echo -e "${GREEN}✓ k3s server ready${NC}"
        break
    fi
    sleep 2
done
echo

# Get the join token
echo -e "${YELLOW}Getting k3s join token...${NC}"
K3S_TOKEN=$(ssh_node1 "sudo cat /var/lib/rancher/k3s/server/node-token")
if [ -z "$K3S_TOKEN" ]; then
    echo -e "${RED}✗ Could not get k3s token${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Got join token${NC}"
echo

# Install k3s on Node 2 (agent) with crun as default runtime
echo -e "${YELLOW}Installing k3s agent on Node 2 with crun runtime...${NC}"
ssh_node2 "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.2+k3s1 K3S_URL=https://$NODE1_IP:6443 K3S_TOKEN='$K3S_TOKEN' sh -s - agent \
    --node-name=mock-cluster-node2 \
    --default-runtime crun"

# Wait for node 2 to join
echo -e "${YELLOW}Waiting for Node 2 to join cluster...${NC}"
for i in {1..30}; do
    NODE_COUNT=$(ssh_node1 "sudo k3s kubectl get nodes --no-headers 2>/dev/null | wc -l")
    if [ "$NODE_COUNT" = "2" ]; then
        echo -e "${GREEN}✓ Node 2 joined cluster${NC}"
        break
    fi
    sleep 2
done
echo

# Show cluster status
echo -e "${GREEN}=== Cluster Status ===${NC}"
ssh_node1 "sudo k3s kubectl get nodes -o wide"

echo
echo -e "${GREEN}=== k3s Cluster Ready! ===${NC}"
echo -e "${YELLOW}Access cluster from Node 1:${NC}"
echo -e "  ${GREEN}ssh fedora@$NODE1_IP${NC}"
echo -e "  ${GREEN}sudo k3s kubectl get nodes${NC}"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Install mock-accel kernel driver on both nodes"
echo -e "  2. Deploy mock-device-dra-driver"
echo -e "  3. Deploy k8s-dra-driver-nodepartition"
