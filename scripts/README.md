# Scripts Reference

This directory contains scripts for managing mock-device test environments.

## Kubernetes Cluster Scripts

### Complete Setup (Recommended)

```bash
./setup-complete-cluster.sh
```

**What it does:**
- Starts 2 NUMA-aware VMs with libvirt
- Installs k3s (1 server + 1 agent)
- Installs mock-accel driver on both nodes
- Configures kubectl access

**Result:** Ready-to-use 2-node k3s cluster with mock devices

---

### Individual Components

#### 1. VM Management

```bash
# Start VMs only (no k3s)
./start-numa-cluster.sh

# Stop VMs and cleanup
./stop-numa-cluster.sh
```

**VMs:** 2 nodes, 2 NUMA nodes each, 6 devices per VM (1 PF + 2 VFs per NUMA node)

#### 2. k3s Installation

```bash
./setup-k3s-cluster.sh
```

**Prerequisites:** VMs must be running (use `start-numa-cluster.sh` first)

**What it does:**
- Installs k3s server on node1
- Installs k3s agent on node2
- Copies kubeconfig to `~/.kube/config-mock-cluster`

**Usage:**
```bash
export KUBECONFIG=~/.kube/config-mock-cluster
kubectl get nodes
```

#### 3. Driver Installation

```bash
./install-driver-cluster.sh
```

**Prerequisites:** VMs must be running

**What it does:**
- Copies driver source to both nodes
- Installs kernel-devel on both nodes
- Builds and loads mock-accel.ko
- Copies firmware to /lib/firmware/
- Verifies 6 devices per node

---

## Legacy Test Scripts

### Single Device Test

```bash
./test-vm.sh
```

Simple QEMU test with 1 device (no libvirt).

### NUMA Test

```bash
./test-numa.sh
```

QEMU test with 2 NUMA nodes, 2 devices (no libvirt).

### Static VF Test

```bash
./test-static-vfs.sh
```

QEMU test with 1 PF + 4 VFs on same bus (no libvirt).

### Full Integration Test

```bash
./test-numa-cluster.sh
```

**What it does:**
- Starts VMs
- Waits for SSH
- Installs driver
- Runs verification tests
- Auto-cleanup on exit

**Use case:** CI/CD testing

---

## Quick Reference

| Goal | Command |
|------|---------|
| **Full k3s cluster** | `./setup-complete-cluster.sh` |
| **Start VMs only** | `./start-numa-cluster.sh` |
| **Stop cluster** | `./stop-numa-cluster.sh` |
| **Add k3s to running VMs** | `./setup-k3s-cluster.sh` |
| **Install driver** | `./install-driver-cluster.sh` |
| **Test single device** | `./test-vm.sh` |
| **CI/CD test** | `./test-numa-cluster.sh` |

---

## Environment Variables

All scripts use these defaults (can be modified in scripts):

```bash
SSH_USER="fedora"
SSH_PASS="fedora"
SSH_PORT_NODE1=2240
SSH_PORT_NODE2=2241
```

---

## Dependencies

### For VM Scripts
- libvirt with qemu:///system access
- sshpass
- Base image: `/var/lib/libvirt/images/fedora-cloud.qcow2`
- Cloud-init seed: `/var/lib/libvirt/images/seed.iso`

### For k3s Scripts
- curl
- SSH access to VMs

### For Driver Scripts
- kernel-devel, gcc, make (installed automatically on VMs)

---

## Troubleshooting

### VMs won't start
```bash
# Check libvirt network
virsh net-start default

# Check socket files
ls -la /tmp/numa-cluster-*.sock

# Check mock-accel servers
ps aux | grep mock-accel-server
```

### k3s fails to install
```bash
# Check SSH connectivity
ssh -p 2240 fedora@localhost

# Check VM networking
virsh -c qemu:///system console mock-cluster-node1
# Inside VM: ip addr show eth0
```

### Driver build fails
```bash
# SSH to node and check manually
ssh -p 2240 fedora@localhost
sudo dnf install -y kernel-devel-$(uname -r) gcc make
cd ~/mock-device/kernel-driver
make
```

---

## Architecture

```
scripts/
├── setup-complete-cluster.sh     # All-in-one: VMs + k3s + driver
├── start-numa-cluster.sh         # Start VMs only
├── stop-numa-cluster.sh          # Stop and cleanup
├── setup-k3s-cluster.sh          # Install k3s on running VMs
├── install-driver-cluster.sh     # Install driver on running VMs
├── test-numa-cluster.sh          # Full integration test
├── test-vm.sh                    # Legacy: single device
├── test-numa.sh                  # Legacy: NUMA test
├── test-static-vfs.sh            # Legacy: VF test
└── README.md                     # This file
```
