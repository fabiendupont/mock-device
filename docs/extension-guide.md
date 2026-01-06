# Mock Device Extension Guide

## Overview

This guide shows how to extend mock-device with new capabilities for testing advanced DRA scenarios. Extensions enable testing of features like multi-instance GPUs (MIG), device partitioning, advanced telemetry, or specialized hardware capabilities.

**Target Audience**: Developers who need to test DRA drivers with custom device attributes or behaviors not provided by the base mock-device implementation.

---

## Adding New Device Attributes

### Example: Temperature Sensor

Let's add a `temperature` attribute that DRA drivers can read from sysfs and include in ResourceSlices.

#### 1. Update vfio-user Server

**File**: `vfio-user/mock-accel-server.c`

Define register offset and implement read handler:

```c
// Add to register definitions
#define DEVICE_ID_REG         0x00  // Existing
#define REVISION_REG          0x04  // Existing
#define UUID_REG              0x08  // Existing
#define MEMORY_SIZE_REG       0x20  // Existing
#define CAPABILITIES_REG      0x28  // Existing
#define STATUS_REG            0x2C  // Existing
#define TEMPERATURE_REG       0x30  // NEW - 4 bytes (uint32)

// Add to bar0_access callback
static ssize_t bar0_access(vfu_ctx_t *vfu_ctx, char *buf, size_t count,
                           loff_t offset, bool is_write)
{
    struct mock_accel_dev *dev = vfu_get_private(vfu_ctx);

    // ... existing code for other registers ...

    case TEMPERATURE_REG:
        if (is_write) {
            // Temperature is read-only
            return -EPERM;
        } else {
            // Simulate temperature reading (e.g., 45°C = 45000 millidegrees)
            uint32_t temp = 45000;
            memcpy(buf, &temp, sizeof(temp));
            return sizeof(temp);
        }
        break;

    // ... rest of switch statement ...
}
```

**Rebuild**:
```bash
cd vfio-user
make clean && make
```

---

#### 2. Update Kernel Driver

**File**: `kernel-driver/mock-accel.c`

Add sysfs attribute to expose temperature:

```c
// Add to device structure
struct mock_accel_device {
    struct device dev;
    void __iomem *bar0;
    u8 uuid[16];
    u64 memory_size;
    u32 capabilities;
    u32 numa_node;
    u32 temperature;  // NEW - in millidegrees Celsius
};

// Add sysfs attribute show function
static ssize_t temperature_show(struct device *dev,
                                struct device_attribute *attr,
                                char *buf)
{
    struct mock_accel_device *mdev = dev_get_drvdata(dev);
    return sprintf(buf, "%u\n", mdev->temperature);
}
static DEVICE_ATTR_RO(temperature);

// Add to attribute group
static struct attribute *mock_accel_attrs[] = {
    &dev_attr_uuid.attr,
    &dev_attr_memory_size.attr,
    &dev_attr_capabilities.attr,
    &dev_attr_status.attr,
    &dev_attr_temperature.attr,  // NEW
    NULL,
};

// Read temperature during probe
static int mock_accel_probe(struct pci_dev *pdev,
                            const struct pci_device_id *id)
{
    // ... existing code ...

    // Read temperature register (BAR0 offset 0x30)
    mdev->temperature = ioread32(mdev->bar0 + 0x30);
    dev_info(&pdev->dev, "Temperature: %u millidegrees C\n", mdev->temperature);

    // ... rest of probe ...
}
```

**Rebuild and Reload**:
```bash
cd kernel-driver
make clean && make

# On test node (SSH)
sudo rmmod mock_accel
sudo insmod mock-accel.ko

# Verify new attribute
cat /sys/class/mock-accel/mock0/temperature
# Expected: 45000
```

---

#### 3. Update DRA Driver Discovery

**File**: `dra-driver/pkg/discovery/scanner.go`

Add temperature to `DiscoveredDevice` struct:

```go
type DiscoveredDevice struct {
    Name         string
    UUID         string
    MemorySize   int64
    NumaNode     int
    DeviceType   string
    PCIAddress   string
    Capabilities uint32
    PhysFn       string
    Temperature  uint32  // NEW - millidegrees Celsius
}
```

Update `scanDevice` to read temperature:

```go
func (s *DeviceScanner) scanDevice(devName, devPath string) (*DiscoveredDevice, error) {
    dev := &DiscoveredDevice{Name: devName}

    // ... existing attribute reads ...

    // Read temperature (optional attribute for backward compatibility)
    temp, err := readSysfsUint32(devPath, "temperature")
    if err != nil {
        klog.V(6).Infof("Device %s has no temperature attribute, defaulting to 0", devName)
        temp = 0
    }
    dev.Temperature = temp

    return dev, nil
}
```

---

#### 4. Update ResourceSlice Builder

**File**: `dra-driver/pkg/controller/resourceslice.go`

Add temperature attribute to ResourceSlice:

```go
func (b *ResourceSliceBuilder) Build(devices map[string]*DiscoveredDevice) ([]*resourcev1.ResourceSlice, error) {
    // ... existing code ...

    for _, dev := range devices {
        // ... existing attributes ...

        attributes := map[string]resourcev1.DeviceAttribute{
            attrPrefix + "uuid":         {StringValue: &dev.UUID},
            attrPrefix + "memory":       {IntValue: &dev.MemorySize},
            attrPrefix + "deviceType":   {StringValue: &dev.DeviceType},
            attrPrefix + "pciAddress":   {StringValue: &dev.PCIAddress},
            attrPrefix + "numaNode":     {IntValue: &numaNodeInt},
            attrPrefix + "capabilities": {IntValue: &capsInt},
            attrPrefix + "temperature":  {IntValue: &tempInt},  // NEW
        }

        tempInt := int64(dev.Temperature)

        // ... rest of build logic ...
    }
}
```

---

#### 5. Using in DeviceClass Selectors

**Example ResourceClaim** - Select cool devices (< 50°C):

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: cool-device-claim
spec:
  devices:
    requests:
    - name: cool-device
      deviceClassName: mock-accel-pf
      count: 1
      selectors:
      - cel:
          # Temperature in millidegrees: 50000 = 50°C
          expression: device.attributes["mock-accel.example.com/temperature"].intValue < 50000
```

---

### Verification

```bash
# 1. Rebuild all components
cd vfio-user && make
cd ../kernel-driver && make
cd ../dra-driver && make build

# 2. Deploy updated components
./scripts/start-numa-cluster.sh
./scripts/setup-k3s-cluster.sh
./scripts/deploy-kmm-module.sh

# 3. Verify sysfs attribute
sshpass -p "test123" ssh fedora@192.168.122.211 "cat /sys/class/mock-accel/mock0/temperature"
# Expected: 45000

# 4. Verify ResourceSlice attribute
kubectl get resourceslice mock-accel.example.com-mock-cluster-node1-mock0 -o jsonpath='{.spec.devices[0].basic.attributes}' | jq '.["mock-accel.example.com/temperature"]'
# Expected: {"intValue": 45000}

# 5. Test CEL selector
kubectl apply -f <cool-device-claim.yaml>
kubectl get resourceclaim cool-device-claim -o yaml
# Check .status.allocation to verify device was selected
```

---

## Adding New Capabilities

### Example: Encryption Capability Bit

Let's add hardware encryption support as capability bit 1.

#### Capability Bit Definitions

**Standard Bits** (already defined):
- Bit 0: Basic capability (always set)

**New Bits**:
- Bit 1: Hardware encryption support
- Bit 2: Hardware compression support
- Bit 3: PCIe peer-to-peer DMA support

---

#### 1. Update vfio-user Server

**File**: `vfio-user/mock-accel-server.c`

Add capability flags and command-line option:

```c
// Capability bit definitions
#define CAP_BASIC       (1 << 0)  // Always set
#define CAP_ENCRYPTION  (1 << 1)  // Encryption support
#define CAP_COMPRESSION (1 << 2)  // Compression support
#define CAP_P2P_DMA     (1 << 3)  // PCIe P2P DMA

// Add to device structure
struct mock_accel_dev {
    uint8_t uuid[16];
    uint32_t capabilities;  // Capability bitmask
    uint32_t status;
};

// Add command-line parsing
int main(int argc, char *argv[]) {
    const char *uuid_str = NULL;
    const char *socket_path = NULL;
    uint32_t capabilities = CAP_BASIC;  // Default: basic only
    int opt;

    while ((opt = getopt(argc, argv, "u:c:v")) != -1) {
        switch (opt) {
        case 'u':
            uuid_str = optarg;
            break;
        case 'c':
            // Parse capability flags (e.g., "3" for BASIC|ENCRYPTION)
            capabilities = strtoul(optarg, NULL, 0);
            break;
        case 'v':
            verbose = true;
            break;
        default:
            fprintf(stderr, "Usage: %s [-v] [-u UUID] [-c CAPABILITIES] <socket-path>\n", argv[0]);
            exit(EXIT_FAILURE);
        }
    }

    dev.capabilities = capabilities;
    // ... rest of main ...
}

// Update BAR0 capabilities register read
case CAPABILITIES_REG:
    if (is_write) {
        return -EPERM;  // Read-only
    } else {
        memcpy(buf, &dev->capabilities, sizeof(dev->capabilities));
        return sizeof(dev->capabilities);
    }
    break;
```

**Start Server with Encryption**:
```bash
# Device with encryption (capability = 0x03 = BASIC | ENCRYPTION)
./vfio-user/mock-accel-server -u "NODE1-NUMA0-ENC" -c 3 /tmp/mock-accel-enc.sock
```

---

#### 2. Using Capability Selectors

**Example 1** - Select devices with encryption:

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: mock-accel-encrypted
spec:
  selectors:
  - cel:
      # Check if bit 1 (encryption) is set using bitwise AND
      expression: |(device.attributes["mock-accel.example.com/capabilities"].intValue & 2) != 0
```

**Example 2** - Select devices with both encryption AND compression:

```yaml
selectors:
- cel:
    # Check bits 1 and 2 are both set (0x06 = 0b0110)
    expression: |(device.attributes["mock-accel.example.com/capabilities"].intValue & 6) == 6
```

**Example 3** - Select devices with ANY advanced capability:

```yaml
selectors:
- cel:
    # Check any bit beyond basic (> 1)
    expression: |device.attributes["mock-accel.example.com/capabilities"].intValue > 1
```

---

#### 3. Documentation Updates

Update API reference with capability bit definitions:

**File**: `docs/api-reference.md`

```markdown
### Capability Bits

| Bit | Name | Description |
|-----|------|-------------|
| 0 | Basic | Basic capability (always set) |
| 1 | Encryption | Hardware encryption support |
| 2 | Compression | Hardware compression support |
| 3 | P2P DMA | PCIe peer-to-peer DMA |
| 4-31 | Reserved | Future capabilities |

**Examples**:
- `0x01` (binary `0001`) - Basic only
- `0x03` (binary `0011`) - Basic + Encryption
- `0x07` (binary `0111`) - Basic + Encryption + Compression
- `0x0F` (binary `1111`) - All features
```

---

### Verification

```bash
# 1. Start server with different capabilities
./vfio-user/mock-accel-server -u "DEV-BASIC" -c 1 /tmp/mock-basic.sock &
./vfio-user/mock-accel-server -u "DEV-ENCRYPTED" -c 3 /tmp/mock-encrypted.sock &

# 2. Boot VM and check sysfs
cat /sys/class/mock-accel/mock0/capabilities
# Expected: 0x00000001 (basic)

cat /sys/class/mock-accel/mock1/capabilities
# Expected: 0x00000003 (basic + encryption)

# 3. Verify ResourceSlice attributes
kubectl get resourceslices -o custom-columns=\
NAME:.metadata.name,\
CAPS:.spec.devices[0].basic.attributes.mock-accel\.example\.com/capabilities.intValue

# 4. Test capability selector
kubectl apply -f <encrypted-device-class.yaml>
kubectl get deviceclass mock-accel-encrypted -o yaml
```

---

## Adding SR-IOV-like Features

### Example: Device Partitioning (MIG-style)

Implement GPU Multi-Instance GPU (MIG)-style partitioning where a PF can be divided into multiple logical partitions with different memory sizes.

#### Partitioning Model

- **PF** (Physical Function): Full device with 16GB memory
- **Partition 0**: 8GB (50% of device)
- **Partition 1**: 4GB (25% of device)
- **Partition 2**: 4GB (25% of device)

---

#### 1. Define Partition Registers

**File**: `vfio-user/mock-accel-server.c`

```c
// Partition configuration registers
#define PARTITION_COUNT_REG   0x40  // Number of active partitions (uint32)
#define PARTITION_CONFIG_REG  0x44  // Partition configuration base (8 bytes per partition)

// Partition config structure (8 bytes)
struct partition_config {
    uint32_t size_mb;       // Partition size in MB
    uint32_t state;         // 0 = inactive, 1 = active
};

// Device structure with partitions
struct mock_accel_dev {
    uint8_t uuid[16];
    uint64_t total_memory;
    uint32_t capabilities;
    uint32_t status;
    uint32_t partition_count;                    // NEW
    struct partition_config partitions[4];       // NEW - max 4 partitions
};

// Initialize partitions in main()
dev.total_memory = 16ULL * 1024 * 1024 * 1024;  // 16GB
dev.partition_count = 0;  // No partitions initially

// BAR0 access for partition registers
case PARTITION_COUNT_REG:
    if (is_write) {
        uint32_t new_count;
        memcpy(&new_count, buf, sizeof(new_count));
        if (new_count > 4) {
            return -EINVAL;
        }
        dev.partition_count = new_count;
        // Initialize default partition sizes
        if (new_count == 3) {
            dev.partitions[0].size_mb = 8192;  // 8GB
            dev.partitions[1].size_mb = 4096;  // 4GB
            dev.partitions[2].size_mb = 4096;  // 4GB
            dev.partitions[0].state = 1;
            dev.partitions[1].state = 1;
            dev.partitions[2].state = 1;
        }
        return sizeof(new_count);
    } else {
        memcpy(buf, &dev.partition_count, sizeof(dev.partition_count));
        return sizeof(dev.partition_count);
    }
    break;

case PARTITION_CONFIG_REG ... (PARTITION_CONFIG_REG + 32):
    // Read/write partition configurations
    offset_in_config = offset - PARTITION_CONFIG_REG;
    partition_idx = offset_in_config / sizeof(struct partition_config);

    if (partition_idx >= 4) {
        return -EINVAL;
    }

    if (is_write) {
        memcpy(&dev.partitions[partition_idx], buf, sizeof(struct partition_config));
        return sizeof(struct partition_config);
    } else {
        memcpy(buf, &dev.partitions[partition_idx], sizeof(struct partition_config));
        return sizeof(struct partition_config);
    }
    break;
```

---

#### 2. Kernel Driver Sysfs Support

**File**: `kernel-driver/mock-accel.c`

Add sysfs attributes for partitioning:

```c
// Add to device structure
struct mock_accel_device {
    // ... existing fields ...
    u32 partition_count;
    struct partition_info {
        u32 size_mb;
        u32 state;
    } partitions[4];
};

// Sysfs attribute: partition_count (read/write)
static ssize_t partition_count_show(struct device *dev,
                                     struct device_attribute *attr,
                                     char *buf)
{
    struct mock_accel_device *mdev = dev_get_drvdata(dev);
    return sprintf(buf, "%u\n", mdev->partition_count);
}

static ssize_t partition_count_store(struct device *dev,
                                      struct device_attribute *attr,
                                      const char *buf, size_t count)
{
    struct mock_accel_device *mdev = dev_get_drvdata(dev);
    unsigned int val;
    int ret;

    ret = kstrtouint(buf, 10, &val);
    if (ret)
        return ret;

    if (val > 4)
        return -EINVAL;

    // Write to device register
    iowrite32(val, mdev->bar0 + 0x40);
    mdev->partition_count = val;

    // Re-read partition configurations
    for (int i = 0; i < val; i++) {
        u32 *part_config = (u32 *)(mdev->bar0 + 0x44 + (i * 8));
        mdev->partitions[i].size_mb = ioread32(part_config);
        mdev->partitions[i].state = ioread32(part_config + 1);
    }

    dev_info(dev, "Partitioning configured: %u partitions\n", val);
    return count;
}
static DEVICE_ATTR_RW(partition_count);

// Sysfs attribute: partition_info (read-only)
static ssize_t partition_info_show(struct device *dev,
                                    struct device_attribute *attr,
                                    char *buf)
{
    struct mock_accel_device *mdev = dev_get_drvdata(dev);
    ssize_t len = 0;

    for (int i = 0; i < mdev->partition_count; i++) {
        len += sprintf(buf + len, "partition%d: %u MB (%s)\n",
                       i,
                       mdev->partitions[i].size_mb,
                       mdev->partitions[i].state ? "active" : "inactive");
    }

    return len;
}
static DEVICE_ATTR_RO(partition_info);

// Add to attribute group
static struct attribute *mock_accel_attrs[] = {
    // ... existing attributes ...
    &dev_attr_partition_count.attr,
    &dev_attr_partition_info.attr,
    NULL,
};
```

**Usage**:
```bash
# Enable 3-way partitioning
echo 3 | sudo tee /sys/class/mock-accel/mock0/partition_count

# View partition configuration
cat /sys/class/mock-accel/mock0/partition_info
# Expected:
# partition0: 8192 MB (active)
# partition1: 4096 MB (active)
# partition2: 4096 MB (active)
```

---

#### 3. DRA Driver Discovery

Partition discovery can be implemented two ways:

**Option A**: Report partitions as separate devices in ResourceSlices
**Option B**: Report partitioning as device attributes

**Implementation (Option B - Attributes)**:

```go
// Add to DiscoveredDevice
type DiscoveredDevice struct {
    // ... existing fields ...
    PartitionCount int
    Partitions     []PartitionInfo
}

type PartitionInfo struct {
    Index  int
    SizeMB uint32
    State  uint32
}

// Read partition info in scanner
func (s *DeviceScanner) scanDevice(devName, devPath string) (*DiscoveredDevice, error) {
    // ... existing code ...

    // Read partition count
    partCount, err := readSysfsInt(devPath, "partition_count")
    if err == nil && partCount > 0 {
        dev.PartitionCount = partCount

        // Parse partition info
        partInfo, err := readSysfsString(devPath, "partition_info")
        if err == nil {
            dev.Partitions = parsePartitionInfo(partInfo)
        }
    }

    return dev, nil
}
```

**ResourceSlice Attributes**:
```go
attributes := map[string]resourcev1.DeviceAttribute{
    // ... existing attributes ...
    attrPrefix + "partitionCount": {IntValue: &partCountInt},
    attrPrefix + "partition0Size": {IntValue: &part0SizeInt},
    attrPrefix + "partition1Size": {IntValue: &part1SizeInt},
    attrPrefix + "partition2Size": {IntValue: &part2SizeInt},
}
```

---

#### 4. CEL Selectors for Partitions

**Select devices with partitioning enabled**:
```yaml
selectors:
- cel:
    expression: device.attributes["mock-accel.example.com/partitionCount"].intValue > 0
```

**Select devices with large primary partition (> 8GB)**:
```yaml
selectors:
- cel:
    expression: device.attributes["mock-accel.example.com/partition0Size"].intValue >= 8192
```

---

### Verification

```bash
# 1. Enable partitioning on device
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "echo 3 | sudo tee /sys/class/mock-accel/mock0/partition_count"

# 2. Verify partition configuration
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "cat /sys/class/mock-accel/mock0/partition_info"

# 3. Wait for ResourceSlice update
sleep 30  # Wait for rescan interval

# 4. Verify ResourceSlice attributes
kubectl get resourceslice mock-accel.example.com-mock-cluster-node1-mock0 -o yaml | grep partition

# 5. Test CEL selector
kubectl apply -f <partitioned-device-claim.yaml>
```

---

## Testing Extended Features

### Test Plan Template

For each new feature, follow this test plan:

1. **Unit Tests** (if applicable)
2. **sysfs Verification**
3. **ResourceSlice Verification**
4. **CEL Selector Testing**
5. **Pod Allocation Testing**

---

### Example Test Script

**File**: `scripts/test-temperature-feature.sh`

```bash
#!/bin/bash
set -e

echo "=== Temperature Feature Test ==="

NODE_IP=192.168.122.211
DEVICE=mock0

# 1. Verify sysfs attribute
echo "1. Checking sysfs attribute..."
TEMP=$(sshpass -p "test123" ssh fedora@$NODE_IP "cat /sys/class/mock-accel/$DEVICE/temperature")
if [ -z "$TEMP" ]; then
  echo "✗ FAIL: Temperature attribute not found in sysfs"
  exit 1
fi
echo "✓ PASS: Temperature attribute exists ($TEMP millidegrees)"

# 2. Verify ResourceSlice attribute
echo "2. Checking ResourceSlice attribute..."
SLICE_NAME="mock-accel.example.com-mock-cluster-node1-$DEVICE"
TEMP_ATTR=$(kubectl get resourceslice $SLICE_NAME -o jsonpath='{.spec.devices[0].basic.attributes.mock-accel\.example\.com/temperature.intValue}')
if [ -z "$TEMP_ATTR" ]; then
  echo "✗ FAIL: Temperature not in ResourceSlice"
  exit 1
fi
echo "✓ PASS: Temperature in ResourceSlice ($TEMP_ATTR)"

# 3. Test CEL selector
echo "3. Testing CEL selector..."
cat <<EOF | kubectl apply -f -
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: temp-test-claim
spec:
  devices:
    requests:
    - name: cool-device
      deviceClassName: mock-accel-pf
      count: 1
      selectors:
      - cel:
          expression: device.attributes["mock-accel.example.com/temperature"].intValue < 100000
EOF

kubectl wait --for=jsonpath='{.status.allocation}' resourceclaim/temp-test-claim --timeout=60s
if [ $? -ne 0 ]; then
  echo "✗ FAIL: ResourceClaim allocation failed"
  kubectl delete resourceclaim temp-test-claim
  exit 1
fi
echo "✓ PASS: CEL selector matched device"

# 4. Cleanup
kubectl delete resourceclaim temp-test-claim

echo ""
echo "✓ All temperature feature tests passed!"
```

---

## Compatibility Considerations

### Backward Compatibility Guidelines

When adding new features, follow these principles:

1. **Optional Attributes**: New attributes should be optional
2. **Graceful Degradation**: Old drivers should work with new devices
3. **Feature Detection**: Enable runtime feature detection
4. **Version Markers**: Use capability bits for feature flags

---

### Pattern: Optional Attribute with Graceful Fallback

```go
// Read optional attribute with default fallback
temperature, err := readSysfsUint32(devPath, "temperature")
if err != nil {
    klog.V(5).Infof("Device %s has no temperature attribute, defaulting to 0", devName)
    temperature = 0  // Default for devices without temperature support
}
dev.Temperature = temperature
```

**Why**: Ensures DRA driver works with both old and new kernel drivers.

---

### Pattern: Feature Detection via Capabilities

```go
// Check if device supports a feature before using it
func (d *DiscoveredDevice) SupportsEncryption() bool {
    return (d.Capabilities & CAP_ENCRYPTION) != 0
}

// Use feature conditionally
if dev.SupportsEncryption() {
    // Use encryption-specific attributes
} else {
    // Fallback to non-encrypted mode
}
```

---

### API Versioning Strategy

**Stable Attributes** (never change):
- `uuid`
- `memory`
- `deviceType`
- `pciAddress`
- `numaNode`

**Experimental Attributes** (may change):
- Prefix with `experimental/` in attribute name
- Example: `mock-accel.example.com/experimental/temperature`
- Remove prefix when stable

**Deprecated Attributes**:
- Mark as deprecated in API reference
- Continue supporting for 2 minor versions
- Remove after deprecation period

**Example**:
```markdown
### Deprecated Attributes

| Attribute | Deprecated In | Remove In | Replacement |
|-----------|---------------|-----------|-------------|
| `old-memory-attr` | v1.2.0 | v1.4.0 | `memory` |
```

---

### Testing Backward Compatibility

**Test Matrix**:

| DRA Driver Version | Kernel Driver Version | Expected Result |
|--------------------|----------------------|-----------------|
| v1.2 (with temp) | v1.1 (no temp) | Works (temp defaults to 0) |
| v1.1 (no temp) | v1.2 (with temp) | Works (temp ignored) |
| v1.2 (with temp) | v1.2 (with temp) | Works (temp reported) |

**Test Script**:
```bash
#!/bin/bash

echo "=== Backward Compatibility Test ==="

# Test old DRA driver with new kernel driver
echo "1. Testing old DRA driver (no temp) with new kernel driver (temp)"
# Deploy old DRA driver image
# Verify ResourceSlices created (without temp attribute)

# Test new DRA driver with old kernel driver
echo "2. Testing new DRA driver (temp) with old kernel driver (no temp)"
# Deploy new DRA driver image
# Verify ResourceSlices created (temp defaults to 0)

# Test new DRA driver with new kernel driver
echo "3. Testing new DRA driver (temp) with new kernel driver (temp)"
# Deploy new DRA driver and kernel driver
# Verify ResourceSlices created (temp has actual value)
```

---

## Example: Complete Feature Addition Workflow

Let's walk through adding a complete feature: **Power Consumption Monitoring**.

### 1. Design

**Attribute**: `power_watts` (current power consumption in watts)
**Register**: BAR0 offset `0x34` (uint32, read-only)
**sysfs**: `/sys/class/mock-accel/<device>/power_watts`
**ResourceSlice**: `mock-accel.example.com/powerWatts` (intValue)

### 2. Implementation Checklist

- [ ] Update vfio-user server register definitions
- [ ] Implement BAR0 read handler (simulate value)
- [ ] Add sysfs attribute to kernel driver
- [ ] Read attribute during driver probe
- [ ] Add field to `DiscoveredDevice` struct
- [ ] Read attribute in DRA driver scanner
- [ ] Add attribute to ResourceSlice builder
- [ ] Update API reference documentation
- [ ] Create test script
- [ ] Add example CEL selector
- [ ] Test backward compatibility

### 3. Implementation Steps

```bash
# 1. vfio-user server
vim vfio-user/mock-accel-server.c
# Add POWER_WATTS_REG = 0x34
# Add case in bar0_access: return simulated power (e.g., 150W)

# 2. Kernel driver
vim kernel-driver/mock-accel.c
# Add dev_attr_power_watts
# Read from BAR0 offset 0x34 in probe

# 3. DRA driver discovery
vim dra-driver/pkg/discovery/scanner.go
# Add PowerWatts uint32 field
# Read from sysfs in scanDevice

# 4. DRA driver ResourceSlice
vim dra-driver/pkg/controller/resourceslice.go
# Add "powerWatts" attribute to map

# 5. Documentation
vim docs/api-reference.md
# Add power_watts to sysfs section
# Add powerWatts to ResourceSlice attributes

# 6. Test
vim scripts/test-power-feature.sh
# Create test script following template

# 7. Rebuild and test
make clean && make
./scripts/test-power-feature.sh
```

### 4. Verification Commands

```bash
# sysfs
cat /sys/class/mock-accel/mock0/power_watts
# Expected: 150

# ResourceSlice
kubectl get resourceslice <name> -o jsonpath='{.spec.devices[0].basic.attributes.mock-accel\.example\.com/powerWatts.intValue}'
# Expected: 150

# CEL selector (low-power devices < 200W)
kubectl apply -f low-power-claim.yaml
```

---

## References

- [mock-device API Reference](api-reference.md) - Complete attribute documentation
- [mock-device Integration Guide](integration-guide.md) - CEL expression patterns
- [mock-device Testing Guide](testing-guide.md) - Verification strategies
- [Kubernetes DRA CEL](https://kubernetes.io/docs/reference/using-api/cel/) - CEL language reference
- [CDI Specification](https://github.com/cncf-tags/container-device-interface/blob/main/SPEC.md) - Container device interface
