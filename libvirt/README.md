# Libvirt Configuration for NUMA-Aware Mock Device Testing

This directory contains libvirt domain XML definitions for testing the mock-device project with NUMA-aware topology, suitable for testing the k8s-dra-driver-nodepartition.

## Topology

Each VM node has:
- **2 NUMA nodes** (2 cores, 4GB RAM each)
- **6 mock devices total** (3 per NUMA node)
  - NUMA 0: 1 PF + 2 VFs (PCI addresses: 11:00.0, 11:00.1, 11:00.2)
  - NUMA 1: 1 PF + 2 VFs (PCI addresses: 21:00.0, 21:00.1, 21:00.2)

```
┌─────────────────────────────────────────────┐
│ VM: mock-cluster-node1 (8GB, 4 cores)       │
├─────────────────────────────────────────────┤
│ NUMA Node 0 (4GB, CPUs 0-1)                 │
│  ├── PCIe Expander Bus 16                   │
│  │   └── Root Port → PCI 11:00.x            │
│  │       ├── 11:00.0 - PF  (function 0)     │
│  │       ├── 11:00.1 - VF0 (function 1)     │
│  │       └── 11:00.2 - VF1 (function 2)     │
├─────────────────────────────────────────────┤
│ NUMA Node 1 (4GB, CPUs 2-3)                 │
│  ├── PCIe Expander Bus 32                   │
│  │   └── Root Port → PCI 21:00.x            │
│  │       ├── 21:00.0 - PF  (function 0)     │
│  │       ├── 21:00.1 - VF0 (function 1)     │
│  │       └── 21:00.2 - VF1 (function 2)     │
└─────────────────────────────────────────────┘
```

## Files

- **node1.xml** - Libvirt domain definition for K8s worker node 1
- **node2.xml** - Libvirt domain definition for K8s worker node 2

## Prerequisites

- **Libvirt** with qemu:///system access
- **Base VM image** in `/var/lib/libvirt/images/fedora-cloud.qcow2`
- **Cloud-init seed** in `/var/lib/libvirt/images/seed.iso`
- **libvirt 'default' network** active (`virsh net-start default`)

## Usage

### Starting the Cluster

Use the start script to launch a persistent cluster:

```bash
cd /home/fdupont/Code/github.com/fabiendupont/mock-device
./scripts/start-numa-cluster.sh
```

This script will:
1. Start 12 mock-accel-server processes (6 per node)
2. Set socket permissions for QEMU access (chmod 666)
3. Create QCOW2 overlay images (node1.qcow2, node2.qcow2)
4. Define and start both VMs
5. Print console access instructions

### Accessing VMs

Once started, access via serial console:

```bash
# Node 1
virsh -c qemu:///system console mock-cluster-node1

# Node 2
virsh -c qemu:///system console mock-cluster-node2

# (Press Ctrl+] to exit console)
```

### Stopping the Cluster

```bash
./scripts/stop-numa-cluster.sh
```

This cleans up:
- Destroys and undefines VMs
- Kills all mock-accel-server processes
- Removes Unix sockets
- Deletes overlay disk images

### Full Test with Verification

For automated testing with SSH access and driver installation:

```bash
./scripts/test-numa-cluster.sh
```

This script will:
1. Start the cluster (as above)
2. Define and start both VMs with libvirt
3. Wait for SSH connectivity
4. Install and load the kernel driver on both nodes
5. Verify NUMA topology
6. Display device details

### Manual Management

Start mock-accel-server processes first (see test script for details), then:

```bash
# Define VMs
virsh define libvirt/node1.xml
virsh define libvirt/node2.xml

# Start VMs
virsh start mock-cluster-node1
virsh start mock-cluster-node2

# Check status
virsh list

# Access console
virsh console mock-cluster-node1

# SSH access
ssh -p 2240 fedora@localhost  # node1
ssh -p 2241 fedora@localhost  # node2

# Stop VMs
virsh destroy mock-cluster-node1
virsh destroy mock-cluster-node2

# Undefine VMs
virsh undefine mock-cluster-node1
virsh undefine mock-cluster-node2
```

## Requirements

- Libvirt 8.0.0+ (for vfio-user support)
- QEMU 6.0+ with vfio-user support
- KVM enabled
- 20GB RAM minimum (16GB for VMs, 4GB for host/services)
- 8+ CPU cores recommended

## PCIe Topology Details

### PCIe Expander Buses (pxb-pcie)

Each NUMA node has a dedicated PCIe expander bus:
- NUMA 0: Bus 16 (0x10)
- NUMA 1: Bus 32 (0x20)

This ensures devices are correctly associated with their NUMA node in the guest OS.

### Root Ports

Each expander bus has one PCIe root port:
- Chassis 100 on NUMA 0 expander (high number avoids conflicts)
- Chassis 101 on NUMA 1 expander

Devices connect to these root ports.

### Multifunction Devices

The PF on each NUMA node uses `multifunction='on'` and sits at function 0.
VFs occupy functions 1 and 2 on the same slot.

This mimics real SR-IOV behavior where VFs are additional functions on the PF's device.

## Verifying NUMA Affinity

Inside the VM:

```bash
# Check NUMA topology
numactl --hardware

# Check device NUMA nodes
for dev in /sys/class/mock-accel/mock*; do
    echo "$(basename $dev): NUMA $(cat $dev/device/numa_node)"
done

# Expected output:
# mock0: NUMA 0  (PF on NUMA 0)
# mock1: NUMA 0  (VF on NUMA 0)
# mock2: NUMA 0  (VF on NUMA 0)
# mock3: NUMA 1  (PF on NUMA 1)
# mock4: NUMA 1  (VF on NUMA 1)
# mock5: NUMA 1  (VF on NUMA 1)
```

## Integration with k8s-dra-driver-nodepartition

The DRA driver should see:
- 2 nodes with devices
- Each node has 2 NUMA domains
- Each NUMA domain has 3 devices (1 PF + 2 VFs)
- Devices are properly associated with their NUMA nodes

This allows testing topology-aware resource allocation where:
- Pods can request devices from specific NUMA nodes
- Cross-NUMA allocation can be tested
- Performance characteristics of local vs remote NUMA access can be evaluated

## Networking

Both VMs use the libvirt 'default' network (NAT bridge):
- Automatic DHCP IP assignment
- VMs can communicate with each other
- VMs can access the internet

The 'default' network must be active:
```bash
virsh net-start default
virsh net-autostart default
```

## Technical Notes

### Libvirt vfio-user Support

As of libvirt 11.6.0, there is **no native `<hostdev type='vfio-user'>`** support. The XML files use `<qemu:commandline>` to pass vfio-user device arguments directly to QEMU:

```xml
<qemu:commandline xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <qemu:arg value='-device'/>
  <qemu:arg value='{"driver": "vfio-user-pci", "socket": {...}, ...}'/>
</qemu:commandline>
```

### Disk Image Isolation

Multiple VMs **cannot share the same qcow2 image** due to SELinux labeling. The test scripts automatically create overlay images:

```bash
qemu-img create -f qcow2 -F qcow2 -b fedora-cloud.qcow2 node1.qcow2
qemu-img create -f qcow2 -F qcow2 -b fedora-cloud.qcow2 node2.qcow2
```

This allows both VMs to share the base image while maintaining separate writable overlays.

### Socket Permissions

QEMU runs as user `qemu:qemu` (uid 107) when using `qemu:///system`. Unix sockets created by your user need world-readable/writable permissions:

```bash
chmod 666 /tmp/numa-cluster-*.sock
```

The test scripts handle this automatically.

### PCI Bus Conflicts

Libvirt automatically creates PCIe root ports that can conflict with manually specified devices. Key solutions:

1. **Explicit PCI addresses** for expander bridges (`addr=0x10`, `addr=0x11`) to avoid slot 1
2. **High chassis numbers** (100, 101) to avoid conflicts with auto-generated root ports
3. **Remove duplicate network devices** - don't mix `<interface>` XML with `-netdev` qemu:commandline

### NUMA Topology with pxb-pcie

PCIe Expander Bridges (`pxb-pcie`) must specify `numa_node` to associate devices with NUMA nodes:

```xml
<qemu:arg value='pxb-pcie,bus_nr=16,id=pci.numa0,numa_node=0,bus=pcie.0,addr=0x10'/>
```

Device ordering matters: Define all `pxb-pcie` → then `pcie-root-port` → then `vfio-user-pci`.

## Troubleshooting

### VMs won't start

Check that all vfio-user socket files exist:
```bash
ls -la /tmp/numa-cluster-node*.sock
```

Should show 12 socket files (6 per node).

### Devices not appearing in guest

Check QEMU logs:
```bash
virsh qemu-monitor-command mock-cluster-node1 --hmp 'info pci'
```

Check that mock-accel-server processes are running:
```bash
ps aux | grep mock-accel-server
```

### NUMA topology incorrect

Inside the VM, check:
```bash
numactl --hardware
lscpu | grep NUMA
```

Check PCIe topology:
```bash
lspci -tv
```

Devices should appear under the correct expander buses.

## Cost Estimates for AWS Bare Metal

For GitHub Actions self-hosted runners:

| Instance | vCPUs | RAM | Price/hour | Monthly (24/7) |
|----------|-------|-----|------------|----------------|
| m5zn.metal | 48 | 192GB | $3.96 | ~$2,851 |
| m6i.metal | 128 | 512GB | $6.14 | ~$4,421 |

**Recommendation:** Use spot instances + auto-start/stop to reduce costs by 70-90%.

## References

- [Libvirt vfio-user support](https://libvirt.org/formatdomain.html#vfio-user-device)
- [QEMU PCIe documentation](https://github.com/qemu/qemu/blob/master/docs/pcie.txt)
- [NUMA in QEMU/libvirt](https://libvirt.org/formatdomain.html#numa-node-tuning)
