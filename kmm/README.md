# Kernel Module Management (KMM) Deployment

This directory contains configuration for deploying the mock-accel kernel module using the Kernel Module Management (KMM) operator.

## Overview

KMM automates kernel module deployment across Kubernetes clusters:
- Builds module containers per kernel version
- Deploys via DaemonSets
- Handles module loading/unloading
- Manages dependencies and firmware

## Files

- `module.yaml` - KMM Module CR defining the mock-accel module
- `../Containerfile` - Multi-stage build for the kernel module
- `../scripts/install-kmm.sh` - Install KMM operator
- `../scripts/deploy-kmm-module.sh` - Build and deploy module

## Prerequisites

- k3s cluster running (use `../scripts/setup-k3s-cluster.sh`)
- cert-manager (required by KMM for webhook certificates)
- KMM operator installed
- podman installed on host
- 12 mock-accel-server processes running

**Note**: The `deploy-kmm-module.sh` script automatically installs cert-manager and KMM if not present.

## Quick Start

```bash
# 1. Build and deploy module (auto-installs cert-manager and KMM)
./scripts/deploy-kmm-module.sh

# 2. Verify deployment
ssh fedora@192.168.122.211 'sudo k3s kubectl get module mock-accel'
ssh fedora@192.168.122.211 'sudo k3s kubectl get pods -l kmm.node.kubernetes.io/module.name=mock-accel'

# 3. Check devices on nodes
ssh fedora@192.168.122.211 'ls /sys/class/mock-accel/'
ssh fedora@192.168.122.143 'ls /sys/class/mock-accel/'
```

## How It Works

### 1. Image Build

The `Containerfile` uses a multi-stage build:

**Builder stage** (fedora:43):
- Installs kernel-devel, gcc, make
- Compiles mock-accel.ko for specific kernel version

**Runtime stage** (fedora-minimal:43):
- Only includes kmod (for modprobe)
- Copies compiled .ko file
- Copies firmware file
- Runs `modprobe mock-accel && sleep infinity`

### 2. Module Deployment

The `Module` CR tells KMM:
- Match nodes with Fedora 43 kernels (`^.*\.fc43\.x86_64$`)
- Use pre-built image `mock-accel-module:latest`
- Load module via `modprobe mock-accel`
- Deploy on all Linux nodes

**Dependencies**:
- cert-manager: Provides webhook certificates for KMM validation
- KMM controller: Manages Module CRs and creates DaemonSets
- KMM webhook: Validates Module CR changes

### 3. DaemonSet Creation

KMM automatically creates a DaemonSet that:
- Runs privileged pods on each node
- Mounts `/lib/modules` and `/lib/firmware`
- Loads the kernel module
- Keeps pod running (module stays loaded)

## Verification

### Check Module Status

```bash
# On host
ssh fedora@192.168.122.211 'sudo k3s kubectl get module mock-accel -o yaml'

# Expected status
# status:
#   nodes:
#   - mock-cluster-node1: Ready
#   - mock-cluster-node2: Ready
```

### Check Module Pods

```bash
ssh fedora@192.168.122.211 'sudo k3s kubectl get pods -l kmm.node.kubernetes.io/module.name=mock-accel -o wide'

# Expected: 2 pods (one per node), Running
```

### Check Loaded Module

```bash
# Node 1
ssh fedora@192.168.122.211 'lsmod | grep mock_accel'

# Node 2
ssh fedora@192.168.122.143 'lsmod | grep mock_accel'
```

### Check Devices

```bash
# Node 1 - should show mock0-mock5
ssh fedora@192.168.122.211 'ls -la /sys/class/mock-accel/'

# Node 2 - should show mock0-mock5
ssh fedora@192.168.122.143 'ls -la /sys/class/mock-accel/'
```

## Troubleshooting

### Module pods not starting

```bash
# Check pod logs
ssh fedora@192.168.122.211 'sudo k3s kubectl logs -l kmm.node.kubernetes.io/module.name=mock-accel'

# Common issues:
# - Image not present: Ensure deploy script imported to both nodes
# - Kernel mismatch: Rebuild for correct kernel version
# - Missing firmware: Check /lib/firmware/mock-accel-wordlist.fw in container
```

### Module not loading

```bash
# Check dmesg on node
ssh fedora@192.168.122.211 'sudo dmesg | tail -50'

# Check if mock-accel servers are running
ps aux | grep mock-accel-server | wc -l  # Should be 12
```

### Rebuild for different kernel

```bash
# Get current kernel version
KERNEL_VER=$(ssh fedora@192.168.122.211 'uname -r')

# Rebuild
podman build --build-arg KERNEL_VERSION=$KERNEL_VER -t mock-accel-module:latest -f Containerfile .

# Re-import and restart pods
./scripts/deploy-kmm-module.sh
```

## Cleanup

```bash
# Remove Module (unloads kernel module and removes DaemonSet)
ssh fedora@192.168.122.211 'sudo k3s kubectl delete module mock-accel'

# Uninstall KMM operator
ssh fedora@192.168.122.211 'sudo k3s kubectl delete -k "https://github.com/kubernetes-sigs/kernel-module-management/config/default?ref=v2.4.1"'
```

## Next Steps

After the kernel module is loaded via KMM:
1. Deploy the mock-device-dra-driver DaemonSet
2. Deploy k8s-dra-driver-nodepartition
3. Create ResourceClass and test pod allocation

## References

- [KMM Documentation](https://github.com/kubernetes-sigs/kernel-module-management)
- [Fedora 43 Release](https://fedoramagazine.org/announcing-fedora-linux-43/)
