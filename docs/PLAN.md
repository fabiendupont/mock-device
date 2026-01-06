# Implementation Plan

## Overview

This document outlines the implementation plan for the mock-device project, which creates a simulated PCIe accelerator for testing Kubernetes DRA drivers with realistic topology.

## Phase 1: QEMU PCIe Device

### 1.1 Study Reference Implementation

- [ ] Clone and study [pciemu](https://github.com/luizinhosuraty/pciemu) for QEMU device structure
- [ ] Review QEMU's `hw/misc/edu.c` as a simple PCI device example
- [ ] Understand QEMU's object model (QOM) and device properties

### 1.2 Implement mock-accel Device

**File: `qemu-device/mock-accel.c`**

```c
// Key structures needed:
typedef struct MockAccelState {
    PCIDevice parent_obj;

    // Device properties (set via QEMU command line)
    char *uuid;
    uint64_t memory_size;
    uint32_t capabilities;

    // MMIO region
    MemoryRegion mmio;

    // Register state
    uint32_t status;
} MockAccelState;
```

**Registers to implement:**

| Offset | Name | Size | Access | Description |
|--------|------|------|--------|-------------|
| 0x00 | DEVICE_ID | 4B | RO | Fixed: 0x4D4F434B ("MOCK") |
| 0x04 | REVISION | 4B | RO | Fixed: 0x00010000 (v1.0) |
| 0x08 | UUID | 16B | RO | From property |
| 0x20 | MEMORY_SIZE | 8B | RO | From property |
| 0x28 | CAPABILITIES | 4B | RO | From property |
| 0x2C | STATUS | 4B | RW | Runtime status |

**Implementation tasks:**

- [ ] Create `MockAccelState` structure
- [ ] Implement `mock_accel_class_init()` with PCI IDs (vendor=0x1de5, device=0x0001)
- [ ] Implement `mock_accel_realize()` to set up MMIO BAR
- [ ] Implement `mock_accel_mmio_read()` for register reads
- [ ] Implement `mock_accel_mmio_write()` for register writes
- [ ] Add device properties: `uuid`, `memory_size`, `capabilities`
- [ ] Register device type with QEMU

### 1.3 Build Integration

**Options:**

**Option A: Out-of-tree build (faster iteration)**
- Create standalone Makefile that compiles against QEMU headers
- Produces `mock-accel.so` that can be loaded with `-device mock-accel`

**Option B: In-tree patch (cleaner integration)**
- Create patch for QEMU source tree
- Add to `hw/misc/Kconfig` and `hw/misc/meson.build`

**Recommendation:** Start with Option B for simplicity

- [ ] Create `scripts/build-qemu.sh` to clone, patch, and build QEMU
- [ ] Test device appears in `qemu-system-x86_64 -device help`

### 1.4 Testing

- [ ] Verify device appears in guest `lspci`
- [ ] Verify PCI config space (vendor/device IDs)
- [ ] Verify BAR0 is mapped and registers readable
- [ ] Test with multiple devices on different PCIe buses

---

## Phase 2: Linux Kernel Driver

### 2.1 PCI Driver Structure

**File: `kernel-driver/mock-accel-drv.c`**

```c
// Key structures:
struct mock_accel_device {
    struct pci_dev *pdev;
    void __iomem *bar0;
    struct device *dev;      // sysfs device
    int index;               // Device index (mock0, mock1, ...)

    // Cached register values
    char uuid[37];           // UUID string
    u64 memory_size;
    u32 capabilities;
};

static struct class *mock_accel_class;
```

**Implementation tasks:**

- [ ] Implement `mock_accel_probe()`:
  - Enable PCI device
  - Map BAR0
  - Read UUID, memory_size, capabilities from registers
  - Create sysfs class device

- [ ] Implement `mock_accel_remove()`:
  - Remove sysfs device
  - Unmap BAR0
  - Disable PCI device

- [ ] Create sysfs attributes:
  - `uuid` (read-only)
  - `memory_size` (read-only)
  - `numa_node` (read-only, from PCI device)
  - `capabilities` (read-only)
  - `status` (read-write)

- [ ] Implement module init/exit:
  - Create `mock-accel` device class
  - Register PCI driver

### 2.2 sysfs Layout

```
/sys/class/mock-accel/
├── mock0/
│   ├── uuid           # "MOCK-0000-0001-0000-000000000001"
│   ├── memory_size    # "17179869184"
│   ├── numa_node      # "0"
│   ├── capabilities   # "0x00000001"
│   ├── status         # "0x00000000"
│   ├── device -> ../../../0000:b4:00.0
│   └── subsystem -> ../../../../../../class/mock-accel
```

### 2.3 Build System

**File: `kernel-driver/Makefile`**

```makefile
obj-m := mock_accel.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
```

**File: `kernel-driver/dkms.conf`** (for easy installation)

```
PACKAGE_NAME="mock-accel"
PACKAGE_VERSION="1.0.0"
BUILT_MODULE_NAME[0]="mock_accel"
DEST_MODULE_LOCATION[0]="/kernel/drivers/misc"
AUTOINSTALL="yes"
```

- [ ] Create Makefile
- [ ] Create dkms.conf
- [ ] Test module build
- [ ] Test module load/unload

### 2.4 Testing

- [ ] Verify module loads without errors
- [ ] Verify `/sys/class/mock-accel/` is created
- [ ] Verify device attributes are readable
- [ ] Verify numa_node matches QEMU configuration
- [ ] Test with multiple devices

---

## Phase 3: Scripts and Testing Infrastructure

### 3.1 QEMU Launch Script

**File: `scripts/run-qemu.sh`**

Features:
- [ ] Parse command-line arguments (numa-nodes, devices-per-node, memory, cpus)
- [ ] Generate QEMU command with:
  - q35 machine type
  - NUMA topology
  - PCIe expander buses per NUMA node
  - Root ports and mock-accel devices
- [ ] Support both KVM and TCG (for CI without KVM)
- [ ] Include common options (serial console, SSH port forward)

### 3.2 Topology Verification Script

**File: `scripts/test-topology.sh`**

- [ ] Enumerate all mock-accel devices
- [ ] Verify NUMA node assignments
- [ ] Compare against expected topology
- [ ] Output machine-readable results (JSON)

### 3.3 CI/CD Setup

- [ ] Create GitHub Actions workflow for:
  - Building QEMU
  - Building kernel module
  - Running topology tests (using QEMU TCG mode)
- [ ] Create Makefile targets for common operations

---

## Phase 4: Integration Testing

### 4.1 With mock-device-dra-driver

- [ ] Create test that:
  1. Launches QEMU with mock devices
  2. Loads kernel module
  3. Runs mock-device-dra-driver
  4. Verifies ResourceSlices are published
  5. Verifies topology info in ResourceSlices

### 4.2 With k8s-dra-driver-nodepartition

- [ ] Create end-to-end test with full stack:
  1. Kind cluster inside QEMU guest
  2. All DRA drivers deployed
  3. Test ResourceClaim allocation
  4. Verify topology-aware placement

---

## Implementation Order

1. **Week 1: QEMU Device**
   - Study pciemu and QEMU device model
   - Implement basic mock-accel device
   - Test in QEMU

2. **Week 2: Kernel Driver**
   - Implement PCI driver
   - Create sysfs interface
   - Test driver load/unload

3. **Week 3: Scripts and Testing**
   - Create run-qemu.sh with topology support
   - Create test-topology.sh
   - Set up CI

4. **Week 4: Integration**
   - Test with DRA drivers
   - Fix any issues
   - Documentation

---

## Open Questions

1. **QEMU distribution**: Should we provide pre-built QEMU binaries or require users to build?
   - Recommendation: Provide build script, consider container image

2. **Kernel module distribution**: Should we use DKMS or provide pre-built modules?
   - Recommendation: DKMS for flexibility, container with pre-built for testing

3. **Device capabilities**: What capability flags should we support?
   - Start simple: just a "compute" capability flag
   - Expand as needed for testing scenarios

4. **Interrupt support**: Do we need MSI/MSI-X interrupts?
   - Not required for initial DRA testing
   - Can add later if needed for more realistic simulation

---

## References

- [QEMU Developer Documentation](https://www.qemu.org/docs/master/devel/)
- [Linux Device Drivers, 3rd Edition](https://lwn.net/Kernel/LDD3/)
- [pciemu project](https://github.com/luizinhosuraty/pciemu)
- [QEMU edu device](https://github.com/qemu/qemu/blob/master/hw/misc/edu.c)
