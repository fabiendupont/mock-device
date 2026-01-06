#!/bin/bash
set -e

# SSH settings
SSH_USER="fedora"
SSH_PASS="test123"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Get VM IP
NODE1_IP=$(virsh -c qemu:///system domifaddr mock-cluster-node1 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)

if [ -z "$NODE1_IP" ]; then
    echo -e "${RED}✗ Could not get Node 1 IP address${NC}"
    exit 1
fi

echo -e "${GREEN}=== Installing Kernel Module Management (KMM) ===${NC}"
echo

# Install git-core on node1 (required for kubectl apply -k)
echo -e "${YELLOW}Installing git-core on node1...${NC}"
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    $SSH_USER@$NODE1_IP "sudo dnf install -y git-core" 2>&1 | grep -E "(Installing|Complete)" || true
echo -e "${GREEN}✓ git-core installed${NC}"
echo

# Install KMM operator
echo -e "${YELLOW}Installing KMM operator (v2.4.1)...${NC}"
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    $SSH_USER@$NODE1_IP "sudo k3s kubectl apply -k 'https://github.com/kubernetes-sigs/kernel-module-management/config/default?ref=v2.4.1'" 2>&1 | grep -v "Warning:"

echo
echo -e "${YELLOW}Waiting for KMM operator to be ready...${NC}"
for i in {1..30}; do
    READY=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        $SSH_USER@$NODE1_IP "sudo k3s kubectl get pods -n kmm-operator-system --no-headers 2>&1 | grep -c Running" || echo "0")
    if [ "$READY" -ge 1 ] 2>/dev/null; then
        echo -e "${GREEN}✓ KMM operator ready${NC}"
        break
    fi
    sleep 2
done

echo
echo -e "${GREEN}=== KMM Installation Complete ===${NC}"
echo -e "${YELLOW}Verify with:${NC}"
echo -e "  ${GREEN}ssh fedora@$NODE1_IP 'sudo k3s kubectl get pods -n kmm-operator-system'${NC}"
