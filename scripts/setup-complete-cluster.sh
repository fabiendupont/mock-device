#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Mock Device NUMA Cluster - Complete Setup            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo

echo -e "${YELLOW}This will:${NC}"
echo -e "  1. Start 2 NUMA-aware VMs (12 mock-accel-server processes)"
echo -e "  2. Install k3s cluster (1 server + 1 agent)"
echo -e "  3. Install mock-accel kernel driver on both nodes"
echo -e "  4. Configure kubectl access from host"
echo
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to cancel...${NC}"
read

# Step 1: Start VMs
echo
echo -e "${GREEN}═══ Step 1/3: Starting NUMA Cluster ═══${NC}"
"$SCRIPT_DIR/start-numa-cluster.sh"

# Wait a bit for VMs to fully boot
echo
echo -e "${YELLOW}Waiting 10 seconds for VMs to stabilize...${NC}"
sleep 10

# Step 2: Setup k3s
echo
echo -e "${GREEN}═══ Step 2/3: Installing k3s Cluster ═══${NC}"
"$SCRIPT_DIR/setup-k3s-cluster.sh"

# Step 3: Install driver
echo
echo -e "${GREEN}═══ Step 3/3: Installing mock-accel Driver ═══${NC}"
"$SCRIPT_DIR/install-driver-cluster.sh"

# Summary
echo
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Cluster Setup Complete!                               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${GREEN}Quick Start:${NC}"
echo -e "  ${YELLOW}# Get VM IPs${NC}"
echo -e "  virsh -c qemu:///system domifaddr mock-cluster-node1"
echo
echo -e "  ${YELLOW}# Access cluster from Node 1${NC}"
echo -e "  ssh fedora@<node1-ip>"
echo -e "  sudo k3s kubectl get nodes -o wide"
echo
echo -e "  ${YELLOW}# Access VMs via console${NC}"
echo -e "  virsh -c qemu:///system console mock-cluster-node1"
echo
echo -e "  ${YELLOW}# Stop cluster${NC}"
echo -e "  ./scripts/stop-numa-cluster.sh"
echo
echo -e "${GREEN}Next Steps:${NC}"
echo -e "  1. Deploy mock-device-dra-driver"
echo -e "  2. Deploy k8s-dra-driver-nodepartition"
echo -e "  3. Create ResourceClass and test pod allocation"
echo
