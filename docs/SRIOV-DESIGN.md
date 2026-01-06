# SR-IOV Implementation Design

## Overview

Add Single Root I/O Virtualization (SR-IOV) support to the mock-device project to enable realistic testing of DRA drivers with device partitioning.

**Implementation approach:** Static VFs - all VFs are pre-configured in QEMU, kernel driver enables/disables them via `sriov_numvfs`.

## Architecture

### Physical Function (PF)
- Main device at function 0 (e.g., 0000:11:00.0)
- Manages SR-IOV capability
- Has full resources (16GB memory, all capabilities)

### Virtual Functions (VFs)
- Functions 1-N on same device (e.g., 0000:11:00.1, 0000:11:00.2, ...)
- Smaller resource allocation (2GB memory each)
- Initially disabled, enabled when sriov_numvfs is written
- Inherit NUMA node from PF

## Implementation Details

### 1. vfio-user Server

#### PF Server (`mock-accel-server`)

**New command-line options:**
```bash
./mock-accel-server -u UUID -m MEMORY_SIZE -t TOTAL_VFS <socket-path>
  -t, --total-vfs NUM    Number of VFs this PF supports (default: 0, max: 7)
```

**SR-IOV Capability in PCI Config Space:**
- Extended capability at offset 0x100 (first extended cap)
- Capability ID: 0x10 (SR-IOV)
- Total VFs: Configurable (default: 4)
- Initial VFs: 0 (VFs disabled at boot)
- VF Device ID: 0x0002 (different from PF)

**PF-specific registers (BAR0):**
- Same as current implementation
- 0x00: DEVICE_ID = 0x4D4F434B
- 0x04: REVISION = 0x00010000
- 0x08-0x17: UUID (128-bit)
- 0x20: MEMORY_SIZE = 16GB
- 0x28: CAPABILITIES = 0x0001
- 0x2C: STATUS

#### VF Server (`mock-accel-server` with VF flag)

**New command-line option:**
```bash
./mock-accel-server -u UUID -m MEMORY_SIZE --vf <socket-path>
  --vf                   Run as Virtual Function (different Device ID)
```

**VF-specific config:**
- Device ID: 0x0002 (to distinguish from PF)
- Class code: 0x000000 (same as PF)
- No SR-IOV capability (VFs don't have SR-IOV)
- Smaller BAR0 memory allocation (2GB default)

### 2. Kernel Driver

#### SR-IOV Detection

In `mock_accel_probe()`:
1. Check for SR-IOV extended capability
2. Read Total VFs from capability structure
3. Store in device structure

#### New sysfs Attributes

**For PF only:**
```c
/sys/bus/pci/devices/0000:11:00.0/sriov_totalvfs    # read-only, e.g., "4"
/sys/bus/pci/devices/0000:11:00.0/sriov_numvfs      # read/write
```

**For both PF and VF:**
```c
/sys/class/mock-accel/mock0/physfn           # symlink to PF (VF only)
/sys/class/mock-accel/mock0/virtfn0          # symlink to VF (PF only)
/sys/class/mock-accel/mock0/virtfn1          # symlink to VF (PF only)
```

#### VF Enable/Disable Logic

When `sriov_numvfs` is written:
1. Validate: 0 <= num_vfs <= total_vfs
2. If increasing VFs: Enable VF devices (write to SR-IOV control register)
3. If decreasing VFs: Disable VF devices
4. VF devices appear/disappear on PCI bus
5. Kernel driver re-probes and creates /sys/class/mock-accel/mockN_vf* entries

**Note:** With static VFs, the VF PCI devices are always present in QEMU. The SR-IOV control register just enables/disables them (makes them visible to the OS).

### 3. QEMU Configuration

#### Multifunction Device

All VFs share the same slot (device number) but different functions:

```bash
# PF on function 0
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-pf-0.sock", "type": "unix"}, "bus": "rp0", "addr": "0.0", "multifunction": "on"}'

# VF 0 on function 1
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-0.sock", "type": "unix"}, "bus": "rp0", "addr": "0.1"}'

# VF 1 on function 2
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-1.sock", "type": "unix"}, "bus": "rp0", "addr": "0.2"}'

# VF 2 on function 3
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-2.sock", "type": "unix"}, "bus": "rp0", "addr": "0.3"}'

# VF 3 on function 4
-device '{"driver": "vfio-user-pci", "socket": {"path": "/tmp/mock-vf-0-3.sock", "type": "unix"}, "bus": "rp0", "addr": "0.4"}'
```

**Result:** All functions appear under same device:
```
0000:11:00.0  PF
0000:11:00.1  VF 0
0000:11:00.2  VF 1
0000:11:00.3  VF 2
0000:11:00.4  VF 3
```

### 4. Testing

#### Server Startup

```bash
# Start PF server
./vfio-user/mock-accel-server -v -u "MOCK-PF-NUMA0" -m 16G -t 4 /tmp/mock-pf-0.sock &

# Start VF servers
./vfio-user/mock-accel-server -v -u "MOCK-VF0-NUMA0" -m 2G --vf /tmp/mock-vf-0-0.sock &
./vfio-user/mock-accel-server -v -u "MOCK-VF1-NUMA0" -m 2G --vf /tmp/mock-vf-0-1.sock &
./vfio-user/mock-accel-server -v -u "MOCK-VF2-NUMA0" -m 2G --vf /tmp/mock-vf-0-2.sock &
./vfio-user/mock-accel-server -v -u "MOCK-VF3-NUMA0" -m 2G --vf /tmp/mock-vf-0-3.sock &
```

#### Expected Behavior

**Initial state:**
```bash
$ cat /sys/bus/pci/devices/0000:11:00.0/sriov_totalvfs
4

$ cat /sys/bus/pci/devices/0000:11:00.0/sriov_numvfs
0

$ ls /sys/class/mock-accel/
mock0  # Only PF
```

**Enable 2 VFs:**
```bash
$ echo 2 | sudo tee /sys/bus/pci/devices/0000:11:00.0/sriov_numvfs

$ cat /sys/bus/pci/devices/0000:11:00.0/sriov_numvfs
2

$ ls /sys/class/mock-accel/
mock0  mock0_vf0  mock0_vf1

$ cat /sys/class/mock-accel/mock0_vf0/uuid
MOCK-VF0-NUMA0

$ cat /sys/class/mock-accel/mock0_vf0/memory_size
2147483648  # 2GB
```

## Implementation Phases

### Phase 1: Basic SR-IOV Infrastructure
1. Add SR-IOV extended capability to vfio-user server
2. Add `--vf` flag to distinguish VF servers
3. Update kernel driver to detect SR-IOV capability
4. Add `sriov_totalvfs` sysfs attribute (read-only)

### Phase 2: VF Enable/Disable
1. Add `sriov_numvfs` sysfs attribute (read/write)
2. Implement VF enable logic in kernel driver
3. Handle VF probe/remove events
4. Test with QEMU multifunction configuration

### Phase 3: VF Device Management
1. Add physfn/virtfn symlinks
2. Different naming for VFs in /sys/class/mock-accel/
3. Update test scripts

### Phase 4: NUMA Topology with SR-IOV
1. Test dual-NUMA with SR-IOV
2. Verify VFs inherit NUMA node
3. Update documentation

## Benefits for DRA Testing

1. **Realistic partitioning**: Test allocation of VFs instead of whole devices
2. **Resource granularity**: Multiple pods sharing same PF
3. **Isolation**: Each VF is independent device to guest OS
4. **Topology inheritance**: All VFs on same NUMA node as PF
5. **Dynamic allocation**: Enable/disable VFs as needed

## Limitations (Static SR-IOV)

1. **Fixed max VFs**: Must be configured at QEMU start
2. **All or nothing**: All VF servers must be running before QEMU starts
3. **No true hotplug**: VFs are always present, just enabled/disabled
4. **Memory overhead**: All VF servers consume memory even when VFs disabled

## Future Enhancements (Dynamic SR-IOV)

1. PF server spawns VF servers on demand
2. VF hotplug into running QEMU
3. Configurable VF resources per instance
4. VF migration support

## Files to Modify

### vfio-user/
- `mock-accel-server.c` - Add SR-IOV capability, --vf flag, --total-vfs
- `Makefile` - No changes needed

### kernel-driver/
- `mock-accel.c` - Add SR-IOV detection, sriov_* attributes, VF handling

### scripts/
- `test-sriov.sh` - New script for SR-IOV testing
- `test-numa-sriov.sh` - NUMA + SR-IOV testing

### docs/
- Update README.md with SR-IOV examples
- Update CLAUDE.md with SR-IOV architecture
