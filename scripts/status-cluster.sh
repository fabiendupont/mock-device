#!/bin/bash

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Mock Device Cluster Status ===${NC}"
echo

# Check VMs
echo -e "${YELLOW}Virtual Machines:${NC}"
VM_STATUS=$(virsh -c qemu:///system list --name 2>/dev/null | grep mock-cluster)
if [ -n "$VM_STATUS" ]; then
    virsh -c qemu:///system list | grep -E "(mock-cluster|Id.*Name)"
    echo -e "${GREEN}✓ VMs running${NC}"
else
    echo -e "${RED}✗ No VMs running${NC}"
    echo -e "  Start with: ${YELLOW}./scripts/start-numa-cluster.sh${NC}"
fi
echo

# Check mock-accel servers
echo -e "${YELLOW}Mock Accel Servers:${NC}"
SERVER_COUNT=$(ps aux | grep -E "mock-accel-server.*numa-cluster" | grep -v grep | wc -l)
if [ "$SERVER_COUNT" -eq 12 ]; then
    echo -e "${GREEN}✓ $SERVER_COUNT servers running (expected: 12)${NC}"
elif [ "$SERVER_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}⚠ $SERVER_COUNT servers running (expected: 12)${NC}"
else
    echo -e "${RED}✗ No servers running${NC}"
fi
echo

# Check k3s cluster
echo -e "${YELLOW}Kubernetes:${NC}"
if [ -n "$VM_STATUS" ]; then
    NODE1_IP=$(virsh -c qemu:///system domifaddr mock-cluster-node1 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)
    if [ -n "$NODE1_IP" ]; then
        K3S_STATUS=$(sshpass -p "test123" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no \
            -o ConnectTimeout=2 fedora@$NODE1_IP "sudo k3s kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo "0")
        if [ "$K3S_STATUS" -ge 2 ]; then
            echo -e "${GREEN}✓ k3s cluster running ($K3S_STATUS nodes)${NC}"
        else
            echo -e "${RED}✗ k3s not running${NC}"
            echo -e "  Setup with: ${YELLOW}./scripts/setup-k3s-cluster.sh${NC}"
        fi
    else
        echo -e "${RED}✗ Cannot get node IP${NC}"
    fi
else
    echo -e "${RED}✗ VMs not running${NC}"
fi
echo

# Check devices (if VMs are accessible)
if [ -n "$VM_STATUS" ]; then
    echo -e "${YELLOW}Mock Devices (via SSH):${NC}"

    # Get VM IPs
    NODE1_IP=$(virsh -c qemu:///system domifaddr mock-cluster-node1 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)
    NODE2_IP=$(virsh -c qemu:///system domifaddr mock-cluster-node2 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1)

    DEVICE_NODE1=$(sshpass -p "test123" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o ConnectTimeout=2 fedora@$NODE1_IP \
        "ls /sys/class/mock-accel/ 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    DEVICE_NODE2=$(sshpass -p "test123" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o ConnectTimeout=2 fedora@$NODE2_IP \
        "ls /sys/class/mock-accel/ 2>/dev/null | wc -l" 2>/dev/null || echo "0")

    if [ "$DEVICE_NODE1" -eq 6 ] && [ "$DEVICE_NODE2" -eq 6 ]; then
        echo -e "${GREEN}✓ Node 1: $DEVICE_NODE1 devices, Node 2: $DEVICE_NODE2 devices${NC}"
    else
        echo -e "${YELLOW}⚠ Node 1: $DEVICE_NODE1 devices, Node 2: $DEVICE_NODE2 devices (expected: 6 each)${NC}"
        if [ "$DEVICE_NODE1" -eq 0 ] || [ "$DEVICE_NODE2" -eq 0 ]; then
            echo -e "  Deploy module: ${YELLOW}./scripts/deploy-kmm-module.sh${NC}"
        fi
    fi
fi
echo

# Summary
echo -e "${BLUE}=== Quick Commands ===${NC}"
echo -e "  ${YELLOW}Access cluster:${NC}     export KUBECONFIG=~/.kube/config-mock-cluster"
echo -e "  ${YELLOW}Console node1:${NC}      virsh -c qemu:///system console mock-cluster-node1"
echo -e "  ${YELLOW}Console node2:${NC}      virsh -c qemu:///system console mock-cluster-node2"
echo -e "  ${YELLOW}Stop cluster:${NC}       ./scripts/stop-numa-cluster.sh"
echo
