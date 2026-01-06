#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Stopping NUMA cluster...${NC}"

# Destroy VMs
echo -e "${YELLOW}Destroying VMs...${NC}"
virsh -c qemu:///system destroy mock-cluster-node1 2>/dev/null || true
virsh -c qemu:///system destroy mock-cluster-node2 2>/dev/null || true
virsh -c qemu:///system undefine mock-cluster-node1 2>/dev/null || true
virsh -c qemu:///system undefine mock-cluster-node2 2>/dev/null || true
echo -e "${GREEN}✓ VMs stopped${NC}"

# Kill mock-accel servers
echo -e "${YELLOW}Stopping mock-accel servers...${NC}"
pkill -f "mock-accel-server.*numa-cluster" 2>/dev/null || true
echo -e "${GREEN}✓ Servers stopped${NC}"

# Remove sockets
echo -e "${YELLOW}Removing sockets...${NC}"
rm -f /tmp/numa-cluster-*.sock
echo -e "${GREEN}✓ Sockets removed${NC}"

# Remove overlay disk images
echo -e "${YELLOW}Removing overlay disk images...${NC}"
sudo rm -f /var/lib/libvirt/images/node1.qcow2 /var/lib/libvirt/images/node2.qcow2
echo -e "${GREEN}✓ Disk images removed${NC}"

echo
echo -e "${GREEN}=== Cluster stopped successfully ===${NC}"
