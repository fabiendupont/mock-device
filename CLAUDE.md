# Mock Device Project - Claude Code Context

## Project Purpose

This project creates a **mock PCIe accelerator device** for testing Kubernetes Dynamic Resource Allocation (DRA) drivers. It enables end-to-end testing of the [k8s-dra-driver-nodepartition](../k8s-dra-driver-nodepartition) meta-DRA driver without requiring real hardware.

The full testing stack consists of:
1. **This project (mock-device)**:
   - vfio-user server that emulates PCIe accelerator devices in userspace
   - Kernel module (`mock-accel.ko`) that exposes devices via sysfs
   - **DRA driver (`dra-driver/`)**: Kubernetes DRA driver for device allocation
2. **k8s-dra-driver-nodepartition**: Meta-DRA driver that orchestrates resource allocation with topology awareness

## Architecture Overview

```
Host                                    QEMU Guest (q35 Machine)
┌─────────────────────────┐            ┌──────────────────────────────────┐
│ mock-accel-server       │            │ NUMA Node 0 (1 CPU, 1GB)         │
│  - PCI config space     │◄──socket──►│  └── pxb-pcie (numa_node=0)      │
│  - BAR0 (registers)     │            │       └── pcie-root-port         │
│  - UUID, memory_size    │            │            └── vfio-user-pci 0   │
└─────────────────────────┘            │                  (0000:11:00.0)  │
                                       │                  ↓               │
┌─────────────────────────┐            │            mock-accel.ko         │
│ mock-accel-server       │            │            (kernel driver)       │
│  - PCI config space     │◄──socket──►│                  ↓               │
│  - BAR0 (registers)     │            │ NUMA Node 1 (1 CPU, 1GB)         │
│  - UUID, memory_size    │            │  └── pxb-pcie (numa_node=1)      │
└─────────────────────────┘            │       └── pcie-root-port         │
                                       │            └── vfio-user-pci 1   │
                                       │                  (0000:21:00.0)  │
                                       │                  ↓               │
                                       │            mock-accel.ko         │
                                       └──────────────────────────────────┘
                                       │                                  │
                                       │ /sys/class/mock-accel/           │
                                       │  ├── mock0/                      │
                                       │  │   ├── uuid                    │
                                       │  │   ├── memory_size             │
                                       │  │   ├── numa_node (0)           │
                                       │  │   ├── capabilities            │
                                       │  │   └── status (RW)             │
                                       │  └── mock1/                      │
                                       │      ├── uuid                    │
                                       │      ├── memory_size             │
                                       │      ├── numa_node (1)           │
                                       │      ├── capabilities            │
                                       │      └── status (RW)             │
                                       └──────────────────────────────────┘
                                       │                                  │
                                       │ Kubernetes DRA Stack             │
                                       │ ┌──────────────────────────────┐ │
                                       │ │ mock-device-dra-driver       │ │
                                       │ │  - Scans /sys/class/mock-*   │ │
                                       │ │  - Reads device properties   │ │
                                       │ │  - Writes status for alloc   │ │
                                       │ │  - Reports ResourceSlices    │ │
                                       │ └──────────────────────────────┘ │
                                       └──────────────────────────────────┘
```

## Directory Structure

```
mock-device/
├── CLAUDE.md              # This file - Claude Code context
├── README.md              # Project documentation
├── vfio-user/             # vfio-user server implementation (C)
│   ├── mock-accel-server.c  # Main server implementation
│   └── Makefile           # Build configuration
├── kernel-driver/         # Linux kernel module (C)
│   ├── mock-accel.c       # PCI driver implementation
│   └── Makefile           # Kernel module build
├── dra-driver/            # Kubernetes DRA driver (Go)
│   ├── cmd/dra-driver/    # Main entry point
│   ├── pkg/               # Go packages
│   │   ├── discovery/     # Device scanner and sysfs helpers
│   │   ├── controller/    # ResourceSlice publisher
│   │   ├── nodeagent/     # Kubelet plugin (gRPC, CDI, allocation)
│   │   └── version/       # Version information
│   ├── deployments/       # Kubernetes manifests
│   ├── Dockerfile         # Container image build
│   ├── Makefile           # Build automation
│   └── README.md          # DRA driver documentation
├── libvfio-user/          # libvfio-user library (git clone)
│   └── build/lib/         # Built library
├── scripts/               # Helper scripts
│   ├── start-numa-cluster.sh    # Start NUMA VMs
│   ├── stop-numa-cluster.sh     # Stop cluster
│   ├── setup-k3s-cluster.sh     # Install k3s with crun
│   ├── deploy-kmm-module.sh     # Deploy kernel module via KMM
│   └── status-cluster.sh        # Check cluster status
├── test/                  # Test resources
│   └── images/            # VM images (Fedora Cloud)
├── docs/                  # Documentation
│   └── PLAN.md            # Implementation plan
└── .claude/
    └── commands/          # Custom slash commands
```

## Key Technical Details

### vfio-user Server (vfio-user/)

The vfio-user server (`mock-accel-server`) emulates a PCIe accelerator using libvfio-user:

- **PCI IDs**: Vendor `0x1de5` (Eideticom, Inc), Device `0x0001`
- **BARs**:
  - BAR0: 4KB MMIO for device registers
- **Registers** (BAR0 offsets):
  - `0x00`: Device ID (32-bit, read-only) - `0x4D4F434B` ("MOCK")
  - `0x04`: Revision (32-bit, read-only) - `0x00010000` (v1.0)
  - `0x08-0x17`: UUID (128-bit, read-only) - Set via `-u` flag
  - `0x20`: Memory size (64-bit, read-only) - Fixed at 16GB
  - `0x28`: Capabilities (32-bit, read-only) - `0x0001`
  - `0x2C`: Status (32-bit, read/write) - Runtime status

**Communication:**
- Uses Unix domain sockets (e.g., `/tmp/mock-accel-0.sock`)
- Implements vfio-user protocol for PCI config space, BAR access, and DMA
- QEMU's `vfio-user-pci` device connects to the server

### QEMU Integration

Devices are attached to NUMA nodes using **pxb-pcie** (PCIe Expander Bridge):

```bash
# Create expander bridges on NUMA nodes
-device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0
-device pxb-pcie,bus_nr=32,id=pci.20,numa_node=1,bus=pcie.0

# Create root ports on the expander bridges
-device pcie-root-port,id=rp0,bus=pci.10,chassis=1
-device pcie-root-port,id=rp1,bus=pci.20,chassis=2

# Attach vfio-user devices to root ports
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-accel-0.sock", "type": "unix"}, "bus": "rp0"}'
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-accel-1.sock", "type": "unix"}, "bus": "rp1"}'
```

**Critical**: Device ordering matters! Define all `pxb-pcie` before `pcie-root-port` before `vfio-user-pci`.

### Kernel Driver (kernel-driver/)

The Linux kernel module (`mock-accel.ko`) provides the interface for DRA drivers:

**Key Functions:**
- Probes PCI devices with vendor `0x1de5`, device `0x0001`
- Maps BAR0 and reads device registers from vfio-user server
- Creates `/sys/class/mock-accel/mockN/` for each device
- Exposes sysfs attributes for device properties and state

**sysfs Attributes:**
- `uuid` - Device UUID (read from BAR0 offset 0x08)
- `memory_size` - Device memory in bytes (read from BAR0 offset 0x20)
- `capabilities` - Feature flags (read from BAR0 offset 0x28)
- `status` - Allocation state (read/write BAR0 offset 0x2C) - **DRA driver writes here**
- `numa_node` - NUMA node (inherited from PCI device)

**Building and Loading:**
```bash
# Inside QEMU guest
cd /path/to/kernel-driver
make
sudo insmod mock-accel.ko

# Verify
ls /sys/class/mock-accel/
# mock0  mock1
```

### sysfs Layout (what DRA driver reads)

```
/sys/class/mock-accel/
├── mock0 -> ../../devices/pci0000:10/0000:10:00.0/0000:11:00.0/mock-accel/mock0
│   ├── uuid              # UUID from device register
│   ├── memory_size       # "17179869184" (16GB)
│   ├── numa_node         # "0" (from PCI device)
│   ├── capabilities      # "0x00000001"
│   ├── status            # "0x00000000" (read/write for allocation)
│   └── device -> ../../../0000:11:00.0
└── mock1 -> ../../devices/pci0000:20/0000:20:00.0/0000:21:00.0/mock-accel/mock1
    ├── uuid              # UUID from device register
    ├── memory_size       # "17179869184"
    ├── numa_node         # "1" (from PCI device)
    ├── capabilities      # "0x00000001"
    ├── status            # "0x00000000"
    └── device -> ../../../0000:21:00.0
```

DRA drivers scan `/sys/class/mock-accel/` to discover devices, read properties, and **write to `status`** for allocation/deallocation.

### DRA Driver (dra-driver/)

The Kubernetes DRA (Dynamic Resource Allocation) driver manages device allocation and exposes devices to pods:

**Architecture**: Two-component design
- **Controller** (Deployment): Discovers devices and publishes ResourceSlices
- **Node Agent** (DaemonSet): Kubelet gRPC plugin for allocation and CDI generation

**Key Responsibilities:**
1. **Device Discovery**: Scans `/sys/class/mock-accel/` and reads device properties
2. **ResourceSlice Publishing**: Creates ResourceSlices with topology information (NUMA node, PCI address, device type)
3. **Allocation**: Writes to sysfs `status` register when device is allocated to a pod
4. **CDI Generation**: Creates Container Device Interface specs for runtime integration

**ResourceSlice Structure:**
```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: ResourceSlice
metadata:
  name: mock-accel-node1-numa0
spec:
  nodeName: mock-cluster-node1
  pool:
    name: numa0              # NUMA node grouping
    generation: 1
  driver: mock-accel.example.com
  devices:
  - name: mock0
    basic:
      attributes:
        uuid: {stringValue: "NODE1-NUMA0-PF"}
        memory: {intValue: 17179869184}
        deviceType: {stringValue: "pf"}      # "pf" or "vf"
        pciAddress: {stringValue: "0000:11:00.0"}
        physfn: {stringValue: "mock0"}       # VFs only
      capacity:
        memory: 16Gi
```

**Device Allocation Flow:**
1. User creates ResourceClaim requesting a device
2. Scheduler selects device based on DeviceClass selectors (CEL expressions)
3. Kubelet calls Node Agent's `NodePrepareResources` gRPC method
4. Node Agent:
   - Writes `1` to `/sys/class/mock-accel/<device>/status`
   - Generates CDI spec at `/var/run/cdi/mock-accel_example_com-<device>.json`
   - Returns CDI device reference to kubelet
5. Container runtime reads CDI spec and configures container with:
   - Environment variables (MOCK_ACCEL_UUID, MOCK_ACCEL_PCI, MOCK_ACCEL_DEVICE)
   - Sysfs mount at `/sys/class/mock-accel/<device>` (read-only)

**Building and Deploying:**
```bash
# Build DRA driver
cd dra-driver
make build-image
make load-image           # Load to k3s on test nodes

# Deploy
make deploy               # Deploys RBAC, controller, node agent, DeviceClasses

# Verify
kubectl get resourceslices
kubectl get pods -n mock-device
```

**Example Usage:**
```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: ResourceClaim
metadata:
  name: my-accel
spec:
  devices:
    requests:
    - name: accel
      deviceClassName: mock-accel-pf
      count: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  resourceClaims:
  - name: accel
    resourceClaimName: my-accel
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "env | grep MOCK_ACCEL && sleep 3600"]
    resources:
      claims:
      - name: accel
```

**Integration with k8s-dra-driver-nodepartition:**
- DRA driver publishes ResourceSlices with topology attributes
- Meta-driver reads ResourceSlices and parses topology
- Coordinates multi-device, NUMA-aware allocation

## E2E Test Workflow with Kubernetes

### Prerequisites

**CRITICAL Requirements:**

1. **crun container runtime**: k3s must use **crun** as the default container runtime (not runc)
   - KMM worker pods need the `finit_module` syscall to load kernel modules
   - runc blocks `finit_module` via seccomp even with SYS_MODULE capability
   - crun allows `finit_module` with just SYS_MODULE capability (no privileged mode needed)
   - The setup scripts automatically configure crun via k3s installation flags

2. **SELinux permissive mode**: SELinux must be set to permissive mode (not enforcing)
   - Even with `seLinuxOptions: type: spc_t` in the pod security context, SELinux blocks module insertion in enforcing mode
   - The setup scripts automatically configure SELinux to permissive mode on both nodes
   - This is required for KMM worker pods to successfully load kernel modules

### Complete E2E Test Steps

**1. Start NUMA Cluster**
```bash
./scripts/start-numa-cluster.sh
```

This script:
- Starts 12 mock-accel-server processes (2 nodes × 2 NUMA × 3 devices)
- Creates VM overlay disk images from base image
- Boots 2 QEMU VMs with NUMA topology
- Each VM has 2 NUMA nodes with devices attached via pxb-pcie

**Expected Output:**
```
=== NUMA-Aware Cluster Test (Libvirt) ===
Topology: 2 K8s nodes × 2 NUMA nodes × (1 PF + 2 VFs)

Starting mock-accel-server processes (12 total)...
Node 1 - NUMA 0:
  PF:  PID 3364874
  VF0: PID 3364875
  VF1: PID 3364876
...
✓ VMs started successfully
```

**2. Setup k3s Cluster with crun**
```bash
./scripts/setup-k3s-cluster.sh
```

This script:
- Sets SELinux to permissive mode on both nodes (required for KMM)
- Installs k3s server on Node 1 with `--default-runtime crun` flag
- Installs k3s agent on Node 2 with `--default-runtime crun` flag
- Configures flannel networking on enp1s0
- Retrieves and distributes k3s token for agent join

**Verification:**
```bash
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s crictl info 2>/dev/null | grep -A2 defaultRuntimeName"
# Expected: "defaultRuntimeName": "crun"
```

**3. Deploy KMM Operator and Module**
```bash
./scripts/deploy-kmm-module.sh
```

This script:
- Installs cert-manager v1.16.2 (required by KMM)
- Waits for cert-manager pods to be Running
- **Waits for cert-manager webhook to be ready** (critical for KMM)
- Installs KMM operator v2.4.1 via kustomize
- Creates `mock-device` namespace with privileged labels:
  - `pod-security.kubernetes.io/enforce=privileged`
  - `pod-security.kubernetes.io/audit=privileged`
  - `pod-security.kubernetes.io/warn=privileged`
  - `kmm.node.k8s.io/contains-modules=''`
- Builds mock-accel kernel module container image
- Loads image into k3s containerd
- Deploys Module CR to trigger DaemonSet creation

**Expected Module CR:**
```yaml
apiVersion: kmm.sigs.x-k8s.io/v1beta1
kind: Module
metadata:
  name: mock-accel
  namespace: mock-device
spec:
  moduleLoader:
    container:
      modprobe:
        moduleName: mock-accel
      imagePullPolicy: IfNotPresent
      kernelMappings:
        - regexp: '^.*\.fc43\.x86_64$'
          containerImage: "mock-accel-module:latest"
  selector:
    kubernetes.io/os: linux
```

**Verification:**
```bash
# Check Module status
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl get module -n mock-device"

# Check worker DaemonSet pods
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl get pods -n mock-device"

# Verify kernel module loaded on nodes
sshpass -p "test123" ssh fedora@192.168.122.211 "lsmod | grep mock_accel"
sshpass -p "test123" ssh fedora@192.168.122.212 "lsmod | grep mock_accel"

# Check sysfs devices created
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "ls -la /sys/class/mock-accel/"
```

**4. Check Cluster Status**
```bash
./scripts/status-cluster.sh
```

Shows:
- VM status and IP addresses
- k3s cluster status
- Node information
- Running pods across all namespaces

**5. Stop Cluster**
```bash
./scripts/stop-numa-cluster.sh
```

This script:
- Destroys and undefines VMs
- Kills all mock-accel-server processes
- Removes socket files
- Removes overlay disk images

**Clean shutdown - preserves base image for future tests.**

### Container Runtime Details

**Why crun is Required:**

| Runtime | SYS_MODULE Capability | finit_module Syscall | Result |
|---------|----------------------|---------------------|---------|
| runc (default) | ✅ Granted | ❌ Blocked by seccomp | Module loading fails |
| crun | ✅ Granted | ✅ Allowed | Module loading succeeds |

**How It's Configured:**

k3s installation automatically configures crun via CLI flags:

```bash
# Server node
curl -sfL https://get.k3s.io | sh -s - server \
    --disable=traefik \
    --node-name=mock-cluster-node1 \
    --advertise-address=$NODE1_IP \
    --flannel-iface=enp1s0 \
    --default-runtime crun

# Agent node
curl -sfL https://get.k3s.io | K3S_URL=https://$NODE1_IP:6443 K3S_TOKEN='$TOKEN' sh -s - agent \
    --node-name=mock-cluster-node2 \
    --default-runtime crun
```

No manual containerd configuration needed. No config.toml.tmpl files. Just the installation flag.

### Troubleshooting

**cert-manager webhook not ready:**
```bash
# Check cert-manager pods
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl get pods -n cert-manager"

# Check webhook endpoint
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl get endpoints -n cert-manager cert-manager-webhook"
```

**KMM webhook pod stuck in ContainerCreating:**
```bash
# Check for missing certificate secret
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl get secret -n kmm-operator-system | grep cert"

# Check Certificate resources
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl get certificate,issuer -A"
```

**Module deployment fails:**
```bash
# Check Module status
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl describe module mock-accel -n mock-device"

# Check worker pod logs
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl logs -n mock-device -l kmm.node.kubernetes.io/module.name=mock-accel"
```

**Kernel module fails to load:**
```bash
# SSH into node and check dmesg
sshpass -p "test123" ssh fedora@192.168.122.211 "sudo dmesg | tail -50"

# Verify PCI devices are present
sshpass -p "test123" ssh fedora@192.168.122.211 "lspci -nn | grep 1de5"

# Check if devices attached to correct NUMA nodes
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "for d in /sys/bus/pci/devices/*/device; do \
     grep -q 0x0001 \"\$d\" 2>/dev/null && \
     echo \"\$(dirname \$d): NUMA \$(cat \$(dirname \$d)/numa_node)\"; \
   done"
```

## Build Commands

```bash
# Build libvfio-user (one-time setup)
cd libvfio-user
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Debug ..
make

# Build mock-accel-server
cd ../../vfio-user
make

# Test with single device
./scripts/test-vm.sh

# Test with NUMA topology (2 nodes, 2 devices)
./scripts/test-numa.sh
```

Inside the QEMU guest, verify devices:

```bash
# Check PCI devices
lspci -nn | grep 1de5
# Expected: 11:00.0 and 21:00.0 devices

# Verify NUMA topology
for d in /sys/bus/pci/devices/*/device; do
  grep -q 0x0001 "$d" 2>/dev/null && echo "$(dirname $d): NUMA $(cat $(dirname $d)/numa_node)"
done
# Expected:
# /sys/bus/pci/devices/0000:11:00.0: NUMA 0
# /sys/bus/pci/devices/0000:21:00.0: NUMA 1
```

## Conventions

### Code Style
- **C (vfio-user)**: Follow standard C style, similar to libvfio-user examples
- **Shell**: Use bash, shellcheck-clean

### Naming
- Server binary: `mock-accel-server`
- PCI vendor: `0x1de5` (Eideticom, Inc)
- PCI device: `0x0001`
- Socket paths: `/tmp/mock-accel-N.sock`

### Testing
- Always verify NUMA topology after QEMU boot
- Test with multiple NUMA configurations (1, 2, 4 nodes)
- Test with varying device counts per node

## Related Projects

- **k8s-dra-driver-nodepartition**: `../k8s-dra-driver-nodepartition/`
  - Read `internal/topology/discoverer.go` for sysfs paths it expects
  - Read `internal/topology/types.go` for data structures

## Common Tasks

### Adding a new device register
1. Define offset and access handlers in `vfio-user/mock-accel-server.c`
2. Implement in the `bar0_access` callback function
3. Rebuild with `make -C vfio-user/`
4. Update documentation

### Changing NUMA topology for testing
Edit `scripts/test-numa.sh` to modify QEMU parameters:
- Change number of NUMA nodes (sockets)
- Adjust memory per node
- Add more `pxb-pcie` devices for additional NUMA nodes
- Add more `mock-accel-server` processes and `vfio-user-pci` devices

### Debugging vfio-user server
```bash
# Run server with verbose logging
./vfio-user/mock-accel-server -v -u "TEST-UUID" /tmp/test.sock

# In QEMU, check dmesg for PCI enumeration
dmesg | grep -i pci

# Check QEMU monitor for device info
info pci
```

## References

- [libvfio-user](https://github.com/nutanix/libvfio-user) - Library for implementing vfio-user servers
- [QEMU vfio-user](https://www.qemu.org/docs/master/devel/vfio-user.html) - QEMU vfio-user protocol documentation
- [QEMU PCIe Documentation](https://github.com/qemu/qemu/blob/master/docs/pcie.txt) - PCIe topology with pxb-pcie
- [Kubernetes DRA](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
