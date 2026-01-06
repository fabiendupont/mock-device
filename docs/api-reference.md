# Mock Device API Reference

## Overview

This document provides comprehensive API documentation for all mock-device interfaces: Go packages, sysfs attributes, ResourceSlice schema, and CDI specifications.

---

## Go Package API

### package `discovery`

#### `DiscoveredDevice`

Represents a mock-accel device discovered from sysfs.

```go
type DiscoveredDevice struct {
    Name         string  // Device name (e.g., "mock0", "mock0_vf0")
    UUID         string  // Unique identifier from device register
    MemorySize   int64   // Device memory in bytes
    NumaNode     int     // NUMA node (0-based)
    DeviceType   string  // "pf" (Physical Function) or "vf" (Virtual Function)
    PCIAddress   string  // PCI BDF address (e.g., "0000:11:00.0")
    Capabilities uint32  // Device capability flags (bitmask)
    PhysFn       string  // Parent PF name (VFs only, e.g., "mock0")
}
```

**Field Details:**

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `Name` | string | Device name from sysfs | `"mock0"`, `"mock0_vf1"` |
| `UUID` | string | Device unique ID | `"NODE1-NUMA0-PF"` |
| `MemorySize` | int64 | Memory in bytes | `17179869184` (16 GiB) |
| `NumaNode` | int | NUMA node | `0`, `1` |
| `DeviceType` | string | Function type | `"pf"`, `"vf"` |
| `PCIAddress` | string | Full PCI address | `"0000:11:00.0"` |
| `Capabilities` | uint32 | Capability bitmask | `0x00000001` |
| `PhysFn` | string | Parent PF (VFs only) | `"mock0"` |

---

#### `DeviceScanner`

Scans sysfs for mock-accel devices.

```go
type DeviceScanner struct {
    // Private fields
}
```

**Methods:**

##### `NewDeviceScanner(nodeName string) *DeviceScanner`

Creates a new device scanner for the specified node.

**Parameters:**
- `nodeName` - Kubernetes node name (used for labeling ResourceSlices)

**Returns:** DeviceScanner instance

**Example:**
```go
scanner := discovery.NewDeviceScanner("node1")
```

---

##### `SetSysfsPath(path string)`

Overrides the default sysfs path (primarily for testing).

**Parameters:**
- `path` - Custom sysfs path

**Default:** `/sys/class/mock-accel`

**Example:**
```go
scanner.SetSysfsPath("/tmp/test-sysfs")
```

---

##### `Scan() (map[string]*DiscoveredDevice, error)`

Scans sysfs and discovers all mock-accel devices.

**Returns:**
- `map[string]*DiscoveredDevice` - Map of device name → discovered device
- `error` - Error if scan fails

**Behavior:**
- Returns empty map (not error) if sysfs path doesn't exist
- Logs warnings for individual device scan failures but continues
- Reuses internal map for memory efficiency (don't modify returned map)

**Thread Safety:** Not thread-safe. Use separate scanner per goroutine or external synchronization.

**Example:**
```go
devices, err := scanner.Scan()
if err != nil {
    return fmt.Errorf("scan failed: %w", err)
}

for name, dev := range devices {
    fmt.Printf("Device %s: NUMA=%d, Type=%s\n", name, dev.NumaNode, dev.DeviceType)
}
```

---

### package `controller`

#### `ResourceSliceBuilder`

Builds Kubernetes ResourceSlices from discovered devices.

```go
type ResourceSliceBuilder struct {
    // Private fields
}
```

**Methods:**

##### `NewResourceSliceBuilder(nodeName string) *ResourceSliceBuilder`

Creates a new ResourceSlice builder.

**Parameters:**
- `nodeName` - Kubernetes node name

**Returns:** ResourceSliceBuilder instance

---

##### `Build(devices map[string]*DiscoveredDevice) ([]*resourcev1.ResourceSlice, error)`

Builds ResourceSlices from discovered devices.

**Parameters:**
- `devices` - Map of devices from `DeviceScanner.Scan()`

**Returns:**
- `[]*resourcev1.ResourceSlice` - Array of ResourceSlices (one per device)
- `error` - Error if build fails

**Behavior:**
- Creates one ResourceSlice per device (not grouped by pool)
- Each device becomes its own pool
- All attributes prefixed with `mock-accel.example.com/`

**Example:**
```go
scanner := discovery.NewDeviceScanner("node1")
builder := controller.NewResourceSliceBuilder("node1")

devices, err := scanner.Scan()
if err != nil {
    return err
}

slices, err := builder.Build(devices)
if err != nil {
    return err
}

fmt.Printf("Built %d ResourceSlices\n", len(slices))
```

---

## sysfs Interface

### Device Discovery Path

**Base Path:** `/sys/class/mock-accel/`

**Device Entries:** Symlinks to PCI device directories

**Example:**
```bash
$ ls -la /sys/class/mock-accel/
lrwxrwxrwx mock0 -> ../../devices/pci0000:10/0000:10:00.0/0000:11:00.0/mock-accel/mock0
lrwxrwxrwx mock1 -> ../../devices/pci0000:10/0000:10:00.0/0000:11:00.1/mock-accel/mock1
lrwxrwxrwx mock0_vf0 -> ../../devices/pci0000:10/0000:10:00.0/0000:11:00.0/virtfn0/mock-accel/mock0_vf0
```

---

### Device Attributes

All attributes are located at `/sys/class/mock-accel/<device-name>/`

#### `uuid` (read-only)

**Type:** string
**Source:** Device register BAR0 offset 0x08 (16 bytes)
**Format:** Free-form string (typically uppercase hex or descriptive)

**Examples:**
```bash
$ cat /sys/class/mock-accel/mock0/uuid
NODE1-NUMA0-PF

$ cat /sys/class/mock-accel/mock0_vf0/uuid
NODE1-NUMA0-VF0
```

**Usage:** Unique device identifier for tracking and debugging.

---

#### `memory_size` (read-only)

**Type:** int64
**Source:** Device register BAR0 offset 0x20 (8 bytes)
**Format:** Decimal bytes

**Example:**
```bash
$ cat /sys/class/mock-accel/mock0/memory_size
17179869184
```

**Conversion:** `17179869184 bytes = 16 GiB`

---

#### `capabilities` (read-only)

**Type:** uint32
**Source:** Device register BAR0 offset 0x28 (4 bytes)
**Format:** Hexadecimal with `0x` prefix

**Bit Definitions:**
| Bit | Name | Description |
|-----|------|-------------|
| 0 | Basic | Basic capability (always set) |
| 1 | Encryption | Hardware encryption support |
| 2-31 | Reserved | Future capabilities |

**Example:**
```bash
$ cat /sys/class/mock-accel/mock0/capabilities
0x00000001

$ cat /sys/class/mock-accel/mock1/capabilities
0x00000003  # Basic + Encryption
```

**Usage in CEL:**
```yaml
# Check if bit 1 (encryption) is set
expression: |(device.attributes["mock-accel.example.com/capabilities"].intValue & 2) != 0
```

---

#### `status` (read/write)

**Type:** uint32
**Source:** Device register BAR0 offset 0x2C (4 bytes)
**Format:** Decimal

**Values:**
| Value | State | Description |
|-------|-------|-------------|
| `0` | Free | Device is available for allocation |
| `1` | Allocated | Device is allocated to a pod |

**Example:**
```bash
# Read status
$ cat /sys/class/mock-accel/mock0/status
0

# Allocate device (DRA driver writes)
$ echo 1 | sudo tee /sys/class/mock-accel/mock0/status
1

# Deallocate device
$ echo 0 | sudo tee /sys/class/mock-accel/mock0/status
0
```

**Permissions:** Read for all users, write requires root or `CAP_DAC_OVERRIDE`.

**Usage:** DRA node agent writes `1` on allocation, `0` on deallocation.

---

#### `numa_node` (read-only, inherited)

**Type:** int
**Source:** PCI device sysfs (`/sys/class/mock-accel/<device>/device/numa_node`)
**Format:** Decimal

**Example:**
```bash
$ cat /sys/class/mock-accel/mock0/numa_node
0

$ cat /sys/class/mock-accel/mock3/numa_node
1
```

**Note:** Inherited from PCIe topology (pxb-pcie numa_node parameter in QEMU).

---

#### `device` (symlink)

**Type:** symlink
**Target:** `../../../<pci-address>` (e.g., `../../../0000:11:00.0`)

**Example:**
```bash
$ readlink /sys/class/mock-accel/mock0/device
../../../0000:11:00.0

$ ls -l /sys/class/mock-accel/mock0/device/
# PCI device directory with vendor, device, class, etc.
```

**Usage:** Navigate to PCI device directory for additional attributes (vendor ID, device ID, etc.).

---

### SR-IOV Attributes (PF only)

#### `sriov_totalvfs` (read-only)

**Type:** int
**Format:** Decimal
**Range:** 0-7

**Example:**
```bash
$ cat /sys/class/mock-accel/mock0/sriov_totalvfs
4
```

**Meaning:** Maximum VFs supported by this PF.

---

#### `sriov_numvfs` (read/write)

**Type:** int
**Format:** Decimal
**Range:** 0 to `sriov_totalvfs`

**Example:**
```bash
# Check current VFs
$ cat /sys/class/mock-accel/mock0/sriov_numvfs
0

# Enable 2 VFs
$ echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs
2

# Verify VF devices appeared
$ ls /sys/class/mock-accel/ | grep mock0
mock0
mock0_vf0
mock0_vf1

# Disable VFs
$ echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs
0
```

**Effect:** Creates/destroys VF devices named `<pf>_vf<N>` (e.g., `mock0_vf0`, `mock0_vf1`).

**Permissions:** Write requires root.

---

## ResourceSlice Schema

### Metadata

```yaml
metadata:
  name: mock-accel.example.com-<node-name>-<device-name>
  labels:
    driver: mock-accel.example.com
    node: <node-name>
    device: <device-name>
```

**Naming Convention:**
`mock-accel.example.com-mock-cluster-node1-mock0`

**Labels:**
- `driver` - DRA driver name (for filtering)
- `node` - Kubernetes node name
- `device` - Device name

---

### Spec

#### `nodeName`

**Type:** string
**Value:** Kubernetes node name
**Example:** `"mock-cluster-node1"`

---

#### `pool`

**Type:** object

| Field | Type | Value | Description |
|-------|------|-------|-------------|
| `name` | string | Device name | Each device is its own pool |
| `generation` | int64 | `1` | Static value |
| `resourceSliceCount` | int64 | `1` | One slice per device |

**Example:**
```yaml
pool:
  name: mock0
  generation: 1
  resourceSliceCount: 1
```

---

#### `driver`

**Type:** string
**Value:** `"mock-accel.example.com"`

---

#### `devices`

**Type:** array of Device objects

##### Device Object

```yaml
- name: mock0
  basic:
    attributes: { ... }
    capacity: { ... }
```

---

### Attributes

All attribute keys are prefixed with `mock-accel.example.com/`.

| Attribute Key | Type | DRA Type | Description | Example | VF Only |
|---------------|------|----------|-------------|---------|---------|
| `uuid` | string | stringValue | Device UUID | `"NODE1-NUMA0-PF"` | No |
| `memory` | int64 | intValue | Memory (bytes) | `17179869184` | No |
| `deviceType` | string | stringValue | PF or VF | `"pf"` or `"vf"` | No |
| `pciAddress` | string | stringValue | PCI BDF | `"0000:11:00.0"` | No |
| `numaNode` | int64 | intValue | NUMA node | `0` or `1` | No |
| `capabilities` | int64 | intValue | Capability flags | `1` | No |
| `physfn` | string | stringValue | Parent PF | `"mock0"` | Yes |

**Full Example:**
```yaml
attributes:
  mock-accel.example.com/uuid: {stringValue: "NODE1-NUMA0-PF"}
  mock-accel.example.com/memory: {intValue: 17179869184}
  mock-accel.example.com/deviceType: {stringValue: "pf"}
  mock-accel.example.com/pciAddress: {stringValue: "0000:11:00.0"}
  mock-accel.example.com/numaNode: {intValue: 0}
  mock-accel.example.com/capabilities: {intValue: 1}
```

**VF Example:**
```yaml
attributes:
  mock-accel.example.com/uuid: {stringValue: "NODE1-NUMA0-VF0"}
  mock-accel.example.com/memory: {intValue: 17179869184}
  mock-accel.example.com/deviceType: {stringValue: "vf"}
  mock-accel.example.com/pciAddress: {stringValue: "0000:11:00.3"}
  mock-accel.example.com/numaNode: {intValue: 0}
  mock-accel.example.com/capabilities: {intValue: 1}
  mock-accel.example.com/physfn: {stringValue: "mock0"}  # VF-specific
```

---

### Capacity

| Capacity Key | Type | Description | Example |
|--------------|------|-------------|---------|
| `mock-accel.example.com/memory` | Quantity | Allocatable memory | `16Gi` |

**Example:**
```yaml
capacity:
  mock-accel.example.com/memory: 16Gi
```

---

### CEL Selector Examples

#### Select PF devices only
```yaml
selectors:
- cel:
    expression: device.attributes["mock-accel.example.com/deviceType"].stringValue == "pf"
```

#### Select devices on NUMA node 0
```yaml
selectors:
- cel:
    expression: device.attributes["mock-accel.example.com/numaNode"].intValue == 0
```

#### Select devices with minimum memory
```yaml
selectors:
- cel:
    expression: device.capacity["mock-accel.example.com/memory"].isGreaterThan(quantity("8Gi"))
```

#### Select VFs from specific PF
```yaml
selectors:
- cel:
    expression: |
      device.attributes["mock-accel.example.com/deviceType"].stringValue == "vf" &&
      device.attributes["mock-accel.example.com/physfn"].stringValue == "mock0"
```

#### Complex: PF on NUMA 0 with specific PCI bus
```yaml
selectors:
- cel:
    expression: |
      device.attributes["mock-accel.example.com/deviceType"].stringValue == "pf" &&
      device.attributes["mock-accel.example.com/numaNode"].intValue == 0 &&
      device.attributes["mock-accel.example.com/pciAddress"].stringValue.startsWith("0000:11:")
```

#### Select by capability (encryption support)
```yaml
selectors:
- cel:
    expression: |(device.attributes["mock-accel.example.com/capabilities"].intValue & 2) != 0
```

---

## CDI Spec Schema

### File Location

**Directory:** `/var/run/cdi/`
**Filename Pattern:** `<vendor>-<device>.json`
**Vendor Format:** Replace `/` with `_` in CDI kind

**Examples:**
- CDI kind: `example.com/mock-accel`
- Filename: `example.com_mock-accel-mock0.json`
- Full path: `/var/run/cdi/example.com_mock-accel-mock0.json`

---

### CDI Spec v0.8.0

```json
{
  "cdiVersion": "0.8.0",
  "kind": "example.com/mock-accel",
  "devices": [
    {
      "name": "mock0",
      "containerEdits": {
        "env": [
          "MOCK_ACCEL_UUID=NODE1-NUMA0-PF",
          "MOCK_ACCEL_PCI=0000:11:00.0",
          "MOCK_ACCEL_DEVICE=mock0"
        ],
        "mounts": [
          {
            "hostPath": "/sys/class/mock-accel/mock0",
            "containerPath": "/sys/class/mock-accel/mock0",
            "options": ["ro", "bind"]
          }
        ]
      }
    }
  ],
  "containerEdits": {}
}
```

---

### Schema Fields

#### `cdiVersion`

**Type:** string
**Value:** `"0.8.0"`
**Required:** Yes

---

#### `kind`

**Type:** string
**Format:** `<vendor>/<class>`
**Value:** `"example.com/mock-accel"`
**Required:** Yes

**Note:** Must match CDI device reference format.

---

#### `devices`

**Type:** array
**Required:** Yes

##### Device Entry

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Device name (e.g., `"mock0"`) |
| `containerEdits` | object | Container modifications |

##### `containerEdits`

| Field | Type | Description |
|-------|------|-------------|
| `env` | array of strings | Environment variables |
| `mounts` | array of Mount objects | Filesystem mounts |

---

### Environment Variables in Container

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `MOCK_ACCEL_UUID` | Device UUID | `"NODE1-NUMA0-PF"` |
| `MOCK_ACCEL_PCI` | PCI address | `"0000:11:00.0"` |
| `MOCK_ACCEL_DEVICE` | Device name | `"mock0"` |

**Usage in Container:**
```bash
$ env | grep MOCK_ACCEL
MOCK_ACCEL_DEVICE=mock0
MOCK_ACCEL_PCI=0000:11:00.0
MOCK_ACCEL_UUID=NODE1-NUMA0-PF
```

---

### Container Mounts

**Mount Entry:**
```json
{
  "hostPath": "/sys/class/mock-accel/mock0",
  "containerPath": "/sys/class/mock-accel/mock0",
  "options": ["ro", "bind"]
}
```

| Field | Value | Description |
|-------|-------|-------------|
| `hostPath` | `/sys/class/mock-accel/<device>` | sysfs device directory on host |
| `containerPath` | `/sys/class/mock-accel/<device>` | Mount point in container |
| `options` | `["ro", "bind"]` | Read-only bind mount |

**Accessible Attributes in Container:**
```bash
$ ls /sys/class/mock-accel/mock0/
capabilities  device  memory_size  numa_node  status  uuid
```

---

### CDI Device Reference

**Format:** `<vendor>/<class>=<device>`

**Example:**
- Kind: `example.com/mock-accel`
- Device: `mock0`
- **Reference:** `example.com/mock-accel=mock0`

**Usage:** Returned by DRA node agent to kubelet, passed to container runtime.

---

## Error Codes

### Scanner Errors

| Error Message | Cause | Resolution |
|---------------|-------|------------|
| `failed to read sysfs directory` | `/sys/class/mock-accel` missing or inaccessible | Load kernel module: `sudo modprobe mock-accel` |
| `failed to read uuid` | Device attribute file missing | Check kernel driver version compatibility |
| `failed to read numa_node` | PCI device symlink broken | Verify sysfs structure: `ls -la /sys/class/mock-accel/<device>/device` |
| `failed to parse numa_node` | Invalid NUMA node value | Check `dmesg` for kernel driver errors |

---

### Allocator Errors

| Error Message | Cause | Resolution |
|---------------|-------|------------|
| `failed to write status` (permission denied) | Insufficient permissions | Run DRA node agent as root or with `CAP_DAC_OVERRIDE` |
| `failed to write status` (no such file) | Device doesn't exist | Verify device in sysfs: `ls /sys/class/mock-accel/` |
| `failed to write status` (invalid argument) | Invalid status value | Use `0` (free) or `1` (allocated) only |

---

### CDI Generation Errors

| Error Message | Cause | Resolution |
|---------------|-------|------------|
| `failed to create CDI directory` | Permission denied on `/var/run/cdi/` | Ensure directory exists and is writable: `sudo mkdir -p /var/run/cdi && sudo chmod 755 /var/run/cdi` |
| `failed to read PCI address` | Device symlink broken | Verify sysfs structure |
| `failed to marshal CDI spec` | Invalid CDI data | Check logs for data issues |
| `failed to write CDI spec file` | Disk full or permissions | Check disk space and `/var/run/cdi/` permissions |

---

## Version Compatibility

### Kubernetes

| Kubernetes Version | DRA Version | Support Status |
|--------------------|-------------|----------------|
| 1.26 | alpha | Minimum (alpha API) |
| 1.27-1.30 | alpha | Supported (v1alpha2, v1alpha3) |
| 1.31+ | v1 | **Recommended** (v1 GA) |
| 1.34+ | v1 | **Tested** |

**Recommendation:** Use Kubernetes 1.31+ for DRA v1 GA API.

---

### Container Runtime

| Runtime | Minimum Version | CDI Support | Notes |
|---------|-----------------|-------------|-------|
| containerd | 1.7.0 | Built-in (0.5.0+) | **Recommended** |
| containerd | 2.0.0+ | Built-in (0.8.0+) | Latest CDI spec |
| crun | 1.8.0+ | Yes | Required for KMM (finit_module syscall) |
| runc | 1.1.0+ | Yes | Not recommended (blocks finit_module) |

**Note:** k3s uses containerd by default. Ensure `--default-runtime crun` for KMM support.

---

### CDI Version

| CDI Spec Version | Support Status | Notes |
|------------------|----------------|-------|
| 0.5.0 | Legacy | Older containerd versions |
| 0.6.0 | Supported | Common baseline |
| 0.7.0 | Supported | Improved device injection |
| **0.8.0** | **Current** | Used by mock-accel |

**Specification:** [CDI Specification v0.8.0](https://github.com/cncf-tags/container-device-interface/blob/main/SPEC.md)

---

### Kernel Module

| Kernel Version | Support Status | Notes |
|----------------|----------------|-------|
| 5.10+ | Minimum | Basic PCI driver support |
| 6.0+ | **Recommended** | Full SR-IOV support |
| 6.17+ | **Tested** | Fedora 43 (test environment) |

---

## Deprecation Policy

### Stable APIs

The following APIs are considered stable and will not change in minor versions:

**ResourceSlice Attributes:**
- `mock-accel.example.com/uuid`
- `mock-accel.example.com/memory`
- `mock-accel.example.com/deviceType`
- `mock-accel.example.com/pciAddress`
- `mock-accel.example.com/numaNode`
- `mock-accel.example.com/capabilities`
- `mock-accel.example.com/physfn`

**sysfs Attributes:**
- `uuid`
- `memory_size`
- `capabilities`
- `status`
- `numa_node`

**CDI Spec:**
- CDI device reference format: `example.com/mock-accel=<device>`
- Environment variables: `MOCK_ACCEL_UUID`, `MOCK_ACCEL_PCI`, `MOCK_ACCEL_DEVICE`
- sysfs mount path: `/sys/class/mock-accel/<device>`

---

### Experimental Features

The following features may change in minor versions:

**SR-IOV Interface:**
- `sriov_numvfs` attribute
- `sriov_totalvfs` attribute
- VF naming convention (`<pf>_vf<N>`)

**Capability Bits:**
- Bit definitions beyond bit 0 (basic)
- Future capability extensions

**Note:** Experimental features are clearly marked in documentation.

---

## References

- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [CDI Specification](https://github.com/cncf-tags/container-device-interface/blob/main/SPEC.md)
- [CEL Language Specification](https://github.com/google/cel-spec)
- [PCI Express Base Specification](https://pcisig.com/specifications)
- [mock-device Integration Guide](integration-guide.md)
- [mock-device Testing Guide](testing-guide.md)
