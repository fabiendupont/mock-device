# Mock PCIe Accelerator Device

[![Release](https://img.shields.io/github/v/release/fabiendupont/mock-device)](https://github.com/fabiendupont/mock-device/releases)
[![Container](https://img.shields.io/badge/container-ghcr.io-blue)](https://github.com/fabiendupont/mock-device/pkgs/container/mock-accel-dra-driver)
[![Helm](https://img.shields.io/badge/helm-oci%3A%2F%2Fghcr.io-blue)](https://github.com/fabiendupont/mock-device/pkgs/container/charts%2Fmock-device)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A simulated PCIe accelerator device for testing Kubernetes Dynamic Resource Allocation (DRA) drivers with realistic PCIe topology and NUMA node associations.

## Overview

This project provides mock PCIe accelerator devices using **vfio-user** for userspace device emulation:

1. **vfio-user Server** (`vfio-user/`): Userspace server implementing PCI device emulation using libvfio-user
2. **QEMU vfio-user-pci**: QEMU device driver that connects to the server via Unix sockets
3. **Kernel Driver** (`kernel-driver/`): Linux PCI driver that exposes device attributes via sysfs

The mock devices appear as real PCIe devices in the guest VM, complete with:
- Proper PCI configuration space (vendor 0x1de5, device 0x0001)
- NUMA node association (via PCIe Expander Bridges - pxb-pcie)
- Device-specific registers (UUID, memory size, capabilities, status)
- sysfs class interface (`/sys/class/mock-accel/`) for DRA driver discovery and manipulation

## Use Case

This project enables end-to-end testing of the [k8s-dra-driver-nodepartition](https://github.com/fabiendupont/k8s-dra-driver-nodepartition) meta-DRA driver, which orchestrates topology-aware resource allocation across multiple DRA drivers.

```
┌─────────────────────────────────────────────────────────────┐
│                    Testing Stack                            │
├─────────────────────────────────────────────────────────────┤
│  k8s-dra-driver-nodepartition (meta-driver)                 │
│       ↓ orchestrates                                        │
│  mock-device-dra-driver (reports ResourceSlices)            │
│       ↓ reads/writes /sys/class/mock-accel/                 │
│  QEMU Guest: mock-accel kernel driver                       │
│       ↓ maps BAR0, creates sysfs attrs                      │
│  QEMU Guest: PCI device (vendor 0x1de5, device 0x0001)      │
│       ↓ vfio-user-pci via Unix socket                       │
│  Host: vfio-user server (mock-accel-server)                 │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **vfio-user based**: Userspace device emulation using libvfio-user
- **Kernel driver**: Exposes device attributes via `/sys/class/mock-accel/` for manipulation
- **SR-IOV support**: Physical Functions (PF) with Virtual Functions (VF) for realistic device partitioning
- **Configurable topology**: Multiple NUMA nodes with devices assigned via pxb-pcie
- **Realistic PCIe**: Devices appear in `/sys/bus/pci/devices/` with proper `numa_node`
- **Stateful devices**: Read/write device status register for allocation tracking
- **No real hardware required**: Runs entirely in QEMU with userspace servers

## Quick Start

### Kubernetes Installation (Helm)

Install mock-device on an existing Kubernetes cluster using Helm:

```bash
# Install DRA driver only (assumes kernel module already loaded)
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.1.0 \
  --namespace mock-device --create-namespace

# Install DRA driver + kernel module (via KMM)
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.1.0 \
  --namespace mock-device --create-namespace \
  --set kernelModule.enabled=true \
  --set kernelModule.image.tag=v0.1.0-fc43
```

**Verify installation:**
```bash
# Check pods are running
kubectl get pods -n mock-device

# Check ResourceSlices are published
kubectl get resourceslices -l driver=mock-accel.example.com

# Check DeviceClasses
kubectl get deviceclass | grep mock-accel
```

**Test device allocation:**
```bash
kubectl apply -f https://raw.githubusercontent.com/fabiendupont/mock-device/main/docs/examples/basic-allocation.yaml
kubectl wait --for=condition=Ready pod/basic-allocation-test --timeout=60s
kubectl logs basic-allocation-test
```

See [Installation Guide](docs/installation-guide.md) for complete prerequisites and configuration options.

### Development Testing

#### Option 1: Complete k3s Cluster Setup (Recommended for Development)

Set up a complete 2-node Kubernetes cluster with mock devices in one command:

```bash
./scripts/setup-complete-cluster.sh
```

This will:
1. Start 2 NUMA-aware VMs (12 mock-accel-server processes)
2. Install k3s cluster (1 server + 1 agent)
3. Install mock-accel kernel driver on both nodes
4. Configure kubectl access from host

Access the cluster:
```bash
export KUBECONFIG=~/.kube/config-mock-cluster
kubectl get nodes -o wide
```

Stop the cluster:
```bash
./scripts/stop-numa-cluster.sh
```

**Next:** Deploy [mock-device-dra-driver](https://github.com/fabiendupont/mock-device-dra-driver) and [k8s-dra-driver-nodepartition](https://github.com/fabiendupont/k8s-dra-driver-nodepartition).

#### Option 2: Manual Testing

### Prerequisites

- QEMU 7.0+ (with vfio-user-pci support)
- libvfio-user library
- CMake, GCC, make
- Linux kernel headers (for building kernel module)
- Fedora Cloud image (for testing in VM)

### Build

```bash
# Clone and build libvfio-user (one-time setup)
cd mock-device
git clone https://github.com/nutanix/libvfio-user.git
cd libvfio-user
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Debug ..
make

# Build mock-accel-server
cd ../../vfio-user
make
```

### Run

```bash
# Test with single device
./scripts/test-vm.sh

# Test with NUMA topology (2 nodes, 2 devices)
./scripts/test-numa.sh

# Inside the guest:
# Install kernel headers
sudo dnf install -y kernel-devel-$(uname -r) gcc make

# Build and load kernel module
cd /path/to/mock-device/kernel-driver
make
sudo insmod mock-accel.ko

# Check PCI devices
lspci -nn | grep 1de5
# 11:00.0 Non-VGA unclassified device [0000]: Eideticom, Inc Device [1de5:0001]
# 21:00.0 Non-VGA unclassified device [0000]: Eideticom, Inc Device [1de5:0001]

# Verify kernel driver created sysfs entries
ls /sys/class/mock-accel/
# mock0  mock1

# Check device attributes
cat /sys/class/mock-accel/mock0/uuid
cat /sys/class/mock-accel/mock0/memory_size
cat /sys/class/mock-accel/mock0/numa_node
cat /sys/class/mock-accel/mock0/status

# Verify NUMA topology
for d in /sys/class/mock-accel/mock*; do
  echo "$(basename $d): NUMA $(cat $d/numa_node), UUID $(cat $d/uuid)"
done
# mock0: NUMA 0, UUID ...
# mock1: NUMA 1, UUID ...
```

## Architecture

### vfio-user Architecture

```
Host                                    QEMU Guest (q35 Machine)
┌─────────────────────────┐            ┌──────────────────────────────────┐
│ mock-accel-server       │            │ NUMA Node 0 (1 CPU, 1GB)         │
│  - PCI config space     │◄──socket──►│  └── pxb-pcie (numa_node=0)      │
│  - BAR0 (registers)     │            │       └── pcie-root-port         │
│  - UUID, memory_size    │            │            └── vfio-user-pci 0   │
└─────────────────────────┘            │                  (0000:11:00.0)  │
                                       │                                  │
┌─────────────────────────┐            │ NUMA Node 1 (1 CPU, 1GB)         │
│ mock-accel-server       │            │  └── pxb-pcie (numa_node=1)      │
│  - PCI config space     │◄──socket──►│       └── pcie-root-port         │
│  - BAR0 (registers)     │            │            └── vfio-user-pci 1   │
│  - UUID, memory_size    │            │                  (0000:21:00.0)  │
└─────────────────────────┘            └──────────────────────────────────┘
```

**Key Components:**
- **pxb-pcie**: PCIe Expander Bridge that creates a separate PCIe hierarchy on a specific NUMA node
- **pcie-root-port**: Downstream port of the expander bridge
- **vfio-user-pci**: QEMU device that connects to userspace server via Unix socket
- **mock-accel-server**: Userspace process implementing PCI device using libvfio-user

### Device Registers (BAR0)

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0x00 | 4B | DEVICE_ID | Device identifier (read-only) |
| 0x04 | 4B | REVISION | Hardware revision (read-only) |
| 0x08 | 16B | UUID | Unique device ID (read-only) |
| 0x20 | 8B | MEMORY_SIZE | Device memory in bytes (read-only) |
| 0x28 | 4B | CAPABILITIES | Feature flags (read-only) |
| 0x2C | 4B | STATUS | Device status (read/write) |

### PCI sysfs Interface

The devices appear as standard PCI devices and can be discovered via `/sys/bus/pci/devices/`:

```
/sys/bus/pci/devices/0000:11:00.0/
├── vendor         # "0x1de5" (Eideticom, Inc)
├── device         # "0x0001"
├── class          # "0x000000" (Non-VGA unclassified device)
├── numa_node      # "0" (inherited from pxb-pcie)
├── resource       # BAR mappings
├── config         # PCI configuration space
└── ...

/sys/bus/pci/devices/0000:21:00.0/
├── vendor         # "0x1de5"
├── device         # "0x0001"
├── numa_node      # "1" (inherited from pxb-pcie)
└── ...
```

DRA drivers can scan for devices by vendor/device ID and read topology from `numa_node`.

## Configuration

### mock-accel-server Parameters

```bash
mock-accel-server [OPTIONS] <socket-path>

Options:
  -v              Enable verbose logging
  -u UUID         Device UUID (default: MOCK-0000-0001)
  -m SIZE         Memory size, e.g., 16G (default: 16G for PF, 2G for VF)
  --vf            Run as Virtual Function (Device ID 0x0002)
  --total-vfs N   Total VFs supported by PF (default: 4, max: 7)

Examples:
  # Physical Function with 4 VFs
  ./vfio-user/mock-accel-server -u MOCK-PF-0 -m 16G --total-vfs 4 /tmp/mock-pf-0.sock

  # Virtual Function
  ./vfio-user/mock-accel-server -u MOCK-VF-0 -m 2G --vf /tmp/mock-vf-0-0.sock
```

### QEMU Configuration Example

```bash
# Start servers first
./vfio-user/mock-accel-server -v -u "MOCK-NUMA0-0001" /tmp/mock-accel-0.sock &
./vfio-user/mock-accel-server -v -u "MOCK-NUMA1-0001" /tmp/mock-accel-1.sock &

# Launch QEMU with vfio-user-pci devices
qemu-system-x86_64 \
    -machine q35 \
    -m 2G \
    -smp 2,sockets=2,cores=1,threads=1 \
    -numa node,nodeid=0,cpus=0,memdev=mem0 \
    -numa node,nodeid=1,cpus=1,memdev=mem1 \
    -object memory-backend-ram,id=mem0,size=1G \
    -object memory-backend-ram,id=mem1,size=1G \
    -device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0 \
    -device pxb-pcie,bus_nr=32,id=pci.20,numa_node=1,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pci.10,chassis=1 \
    -device pcie-root-port,id=rp1,bus=pci.20,chassis=2 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-accel-0.sock", "type": "unix"}, "bus": "rp0"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-accel-1.sock", "type": "unix"}, "bus": "rp1"}'
```

**Important**: Device ordering matters! Define all `pxb-pcie` devices before `pcie-root-port` devices, which must come before `vfio-user-pci` devices.

## SR-IOV Support

The mock devices support SR-IOV (Single Root I/O Virtualization) for realistic device partitioning scenarios. This enables testing DRA drivers that allocate VFs instead of whole devices.

### Architecture

- **Physical Function (PF)**: Device ID 0x0001, supports up to 7 VFs, 16GB memory default
- **Virtual Functions (VF)**: Device ID 0x0002, 2GB memory default each
- **Implementation**: Static SR-IOV - all VFs pre-configured in QEMU, enabled/disabled via sysfs

### sysfs Interface

For Physical Functions:
```bash
/sys/class/mock-accel/mock0/
├── sriov_totalvfs    # Read-only: total VFs supported (e.g., "4")
├── sriov_numvfs      # Read/write: enable/disable VFs (write "2" to enable 2 VFs)
├── uuid              # PF UUID
├── memory_size       # PF memory (16GB)
└── ...
```

When VFs are enabled, they appear as:
```bash
/sys/class/mock-accel/
├── mock0             # PF
├── mock0_vf0         # VF 0
├── mock0_vf1         # VF 1
└── ...
```

### QEMU Configuration for SR-IOV

All functions must be on the same PCI slot using multifunction:

```bash
# Start PF server
./vfio-user/mock-accel-server -u MOCK-PF-0 -m 16G --total-vfs 4 /tmp/mock-pf-0.sock &

# Start VF servers
./vfio-user/mock-accel-server -u MOCK-VF-0 -m 2G --vf /tmp/mock-vf-0-0.sock &
./vfio-user/mock-accel-server -u MOCK-VF-1 -m 2G --vf /tmp/mock-vf-0-1.sock &
./vfio-user/mock-accel-server -u MOCK-VF-2 -m 2G --vf /tmp/mock-vf-0-2.sock &
./vfio-user/mock-accel-server -u MOCK-VF-3 -m 2G --vf /tmp/mock-vf-0-3.sock &

# Launch QEMU with multifunction device
qemu-system-x86_64 \
    ... \
    -device pxb-pcie,bus_nr=16,id=pci.10,numa_node=0,bus=pcie.0 \
    -device pcie-root-port,id=rp0,bus=pci.10,chassis=1 \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-pf-0.sock", "type": "unix"}, "bus": "rp0", "addr": "0.0", "multifunction": "on"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-0.sock", "type": "unix"}, "bus": "rp0", "addr": "0.1"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-1.sock", "type": "unix"}, "bus": "rp0", "addr": "0.2"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-2.sock", "type": "unix"}, "bus": "rp0", "addr": "0.3"}' \
    -device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-3.sock", "type": "unix"}, "bus": "rp0", "addr": "0.4"}'
```

Result: All functions on same device (e.g., 0000:11:00.0-0000:11:00.4)

### Enabling VFs

Inside the guest VM:

```bash
# Load kernel module
sudo insmod mock-accel.ko

# Initially only PF is visible
$ ls /sys/class/mock-accel/
mock0

# Check SR-IOV capability
$ cat /sys/class/mock-accel/mock0/sriov_totalvfs
4

# Enable 2 VFs
$ echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs

# VFs now appear
$ ls /sys/class/mock-accel/
mock0  mock0_vf0  mock0_vf1

# Disable VFs
$ echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs
```

### Testing SR-IOV

```bash
# Simple SR-IOV test (manual - starts servers, provides QEMU command)
./scripts/test-sriov-simple.sh

# Automated end-to-end SR-IOV test (experimental)
./scripts/test-sriov.sh
```

The simple test starts the PF and VF servers, then provides the QEMU command and instructions for manual testing inside the VM.

For more details, see [SR-IOV Design Document](docs/SRIOV-DESIGN.md).

## Documentation

### Guides

- [Installation Guide](docs/installation-guide.md) - Complete installation instructions (Helm, manual YAML, binary methods)
- [Upgrade Guide](docs/upgrade-guide.md) - Version upgrade procedures and rollback
- [Compatibility Guide](docs/compatibility.md) - Version compatibility matrices and requirements
- [Integration Guide](docs/integration-guide.md) - Meta-DRA driver integration
- [Testing Guide](docs/testing-guide.md) - E2E testing scenarios
- [API Reference](docs/api-reference.md) - ResourceSlice schema and sysfs interface
- [Extension Guide](docs/extension-guide.md) - Adding custom device attributes

### Release Information

- [Releases](https://github.com/fabiendupont/mock-device/releases) - Download binaries, images, and source tarballs
- [Changelog](CHANGELOG.md) - Version history and release notes
- [Release Notes](docs/release-notes/) - Detailed release notes per version
- [Contributing](CONTRIBUTING.md) - Development and release process

## Development

See [CLAUDE.md](CLAUDE.md) for development context, conventions, and Claude Code integration.

### Project Structure

```
mock-device/
├── vfio-user/           # vfio-user server implementation (C)
│   ├── mock-accel-server.c
│   └── Makefile
├── kernel-driver/       # Linux kernel module (C)
│   ├── mock-accel.c    # PCI driver
│   └── Makefile        # Kernel module build
├── libvfio-user/        # libvfio-user library (git submodule)
│   └── build/lib/      # Built library
├── scripts/             # Test and helper scripts
│   ├── test-vm.sh      # Single device test
│   ├── test-numa.sh    # NUMA topology test
│   └── setup-vm.sh     # VM image setup
├── test/                # Test resources
│   └── images/         # VM images (Fedora Cloud)
├── CLAUDE.md            # Development context
└── README.md            # This file
```

## Related Projects

- [k8s-dra-driver-nodepartition](https://github.com/fabiendupont/k8s-dra-driver-nodepartition) - Meta-DRA driver for topology-aware allocation
- [libvfio-user](https://github.com/nutanix/libvfio-user) - Library for implementing vfio-user servers
- [QEMU vfio-user](https://www.qemu.org/docs/master/devel/vfio-user.html) - QEMU vfio-user protocol documentation

## License

Apache License 2.0
