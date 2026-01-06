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

# Get VM IP
NODE1_IP=$(virsh -c qemu:///system domifaddr mock-cluster-node1 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)

if [ -z "$NODE1_IP" ]; then
    echo -e "${RED}✗ Could not get Node 1 IP address${NC}"
    exit 1
fi

echo -e "${GREEN}=== Deploying mock-accel Module via KMM ===${NC}"
echo

# Check if cert-manager is installed (required by KMM)
echo -e "${YELLOW}Checking cert-manager...${NC}"
if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "sudo k3s kubectl get namespace cert-manager 2>/dev/null" &>/dev/null; then
    echo -e "${GREEN}✓ cert-manager already installed${NC}"
else
    echo -e "${YELLOW}cert-manager not found, installing...${NC}"
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        $SSH_USER@$NODE1_IP "sudo k3s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml" 2>/dev/null

    # Wait for cert-manager to be ready
    echo -e "${YELLOW}Waiting for cert-manager to be ready...${NC}"
    for i in {1..30}; do
        READY=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            $SSH_USER@$NODE1_IP "sudo k3s kubectl get pods -n cert-manager 2>/dev/null | grep -c Running" 2>/dev/null | tr -d '\r\n' || echo "0")
        if [ "$READY" -ge 3 ] 2>/dev/null; then
            echo -e "${GREEN}✓ cert-manager pods ready${NC}"
            break
        fi
        sleep 2
    done

    # Wait for cert-manager webhook to be ready
    echo -e "${YELLOW}Waiting for cert-manager webhook to be ready...${NC}"
    for i in {1..30}; do
        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            $SSH_USER@$NODE1_IP "sudo k3s kubectl get endpoints -n cert-manager cert-manager-webhook 2>/dev/null | grep -q cert-manager-webhook" 2>/dev/null; then
            echo -e "${GREEN}✓ cert-manager webhook ready${NC}"
            sleep 5  # Additional grace period for webhook to stabilize
            break
        fi
        sleep 2
    done
fi
echo

# Check if KMM is installed
echo -e "${YELLOW}Checking KMM operator...${NC}"
if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "sudo k3s kubectl get crd modules.kmm.sigs.x-k8s.io 2>/dev/null" &>/dev/null; then
    KMM_INSTALLED=1
else
    KMM_INSTALLED=0
fi

if [ "$KMM_INSTALLED" -eq 0 ]; then
    echo -e "${YELLOW}KMM operator not found, installing...${NC}"

    # Install git-core if not present
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        $SSH_USER@$NODE1_IP "sudo dnf install -y git-core" 2>/dev/null

    # Install KMM operator
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        $SSH_USER@$NODE1_IP "sudo k3s kubectl apply -k 'https://github.com/kubernetes-sigs/kernel-module-management/config/default?ref=v2.4.1'" 2>/dev/null

    # Wait for KMM to be ready (both controller and webhook)
    echo -e "${YELLOW}Waiting for KMM operator to be ready...${NC}"
    for i in {1..30}; do
        READY=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            $SSH_USER@$NODE1_IP "sudo k3s kubectl get pods -n kmm-operator-system 2>/dev/null | grep -c Running" 2>/dev/null | tr -d '\r\n' || echo "0")
        if [ "$READY" -ge 2 ] 2>/dev/null; then
            echo -e "${GREEN}✓ KMM operator ready${NC}"
            break
        fi
        sleep 2
    done
else
    echo -e "${GREEN}✓ KMM operator already installed${NC}"
fi
echo

# Create mock-device namespace with privileged label
echo -e "${YELLOW}Creating mock-device namespace...${NC}"
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "sudo k3s kubectl create namespace mock-device --dry-run=client -o yaml | \
        sudo k3s kubectl apply -f -" 2>/dev/null || true

sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "sudo k3s kubectl label namespace mock-device \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged \
        kmm.node.k8s.io/contains-modules='' --overwrite" 2>/dev/null

echo -e "${GREEN}✓ mock-device namespace ready${NC}"
echo

# Get kernel version from node1
echo -e "${YELLOW}Getting kernel version from cluster...${NC}"
KERNEL_VERSION=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "uname -r" 2>/dev/null | tr -d '\r\n')
echo -e "${GREEN}✓ Kernel version: $KERNEL_VERSION${NC}"
echo

# Build container image locally
echo -e "${YELLOW}Building container image for kernel $KERNEL_VERSION...${NC}"
cd "$PROJECT_ROOT"
podman build --build-arg KERNEL_VERSION=$KERNEL_VERSION -t mock-accel-module:latest -f Containerfile .
echo -e "${GREEN}✓ Image built${NC}"
echo

# Save and import image to both nodes
echo -e "${YELLOW}Importing image to k3s nodes...${NC}"
rm -f /tmp/mock-accel-module.tar
podman save mock-accel-module:latest -o /tmp/mock-accel-module.tar

# Import to node1
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    /tmp/mock-accel-module.tar $SSH_USER@$NODE1_IP:/tmp/ 2>/dev/null
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "sudo k3s ctr images import /tmp/mock-accel-module.tar && sudo k3s ctr image tag localhost/mock-accel-module:latest docker.io/library/mock-accel-module:latest && rm /tmp/mock-accel-module.tar" 2>/dev/null

# Import to node2
NODE2_IP=$(virsh -c qemu:///system domifaddr mock-cluster-node2 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    /tmp/mock-accel-module.tar $SSH_USER@$NODE2_IP:/tmp/ 2>/dev/null
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE2_IP "sudo k3s ctr images import /tmp/mock-accel-module.tar && sudo k3s ctr image tag localhost/mock-accel-module:latest docker.io/library/mock-accel-module:latest && rm /tmp/mock-accel-module.tar" 2>/dev/null

rm /tmp/mock-accel-module.tar
echo -e "${GREEN}✓ Image imported to both nodes${NC}"
echo

# Apply Module CR
echo -e "${YELLOW}Applying Module CR...${NC}"
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "mkdir -p ~/mock-device-kmm" 2>/dev/null

sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "$PROJECT_ROOT/kmm/module.yaml" \
    $SSH_USER@$NODE1_IP:~/mock-device-kmm/ 2>/dev/null

sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    $SSH_USER@$NODE1_IP "sudo k3s kubectl apply -f ~/mock-device-kmm/module.yaml"

echo -e "${GREEN}✓ Module CR applied${NC}"
echo

echo -e "${GREEN}=== Module Deployment Initiated ===${NC}"
echo -e "${YELLOW}Check status with:${NC}"
echo -e "  ${GREEN}ssh $SSH_USER@$NODE1_IP 'sudo k3s kubectl get module mock-accel -o wide'${NC}"
echo -e "  ${GREEN}ssh $SSH_USER@$NODE1_IP 'sudo k3s kubectl get pods -l kmm.node.kubernetes.io/module.name=mock-accel'${NC}"
