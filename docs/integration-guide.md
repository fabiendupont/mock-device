# Mock Device Integration Guide

## Overview

This guide shows how to integrate and test your DRA driver using mock-device for comprehensive end-to-end testing without physical hardware. This is particularly valuable for meta-DRA drivers like k8s-dra-driver-nodepartition that need to test topology-aware allocation strategies.

## Architecture for Meta-DRA Drivers

### Data Flow

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. Device Discovery & ResourceSlice Publication                   │
│                                                                    │
│   mock-accel-dra-driver (Per Node)                               │
│   ├── Scans /sys/class/mock-accel/                               │
│   ├── Reads device properties (UUID, NUMA, PCI, memory, caps)    │
│   └── Publishes ResourceSlices to Kubernetes API                 │
│                                                                    │
│   Result: One ResourceSlice per device with full topology info   │
└────────────────────────────────────────────────────────────────────┘
                                ↓
┌────────────────────────────────────────────────────────────────────┐
│ 2. Topology Discovery by Meta-Driver                              │
│                                                                    │
│   Your Meta-DRA Driver (e.g., Node Partition)                    │
│   ├── Lists ResourceSlices from Kubernetes API                   │
│   ├── Filters by driver label (mock-accel.example.com)           │
│   ├── Parses topology attributes (NUMA node, PCI address)        │
│   └── Builds topology map (NUMA → devices, PCIe bus → devices)   │
└────────────────────────────────────────────────────────────────────┘
                                ↓
┌────────────────────────────────────────────────────────────────────┐
│ 3. Allocation Decision & ResourceClaim Creation                   │
│                                                                    │
│   Your Meta-DRA Driver                                            │
│   ├── Selects devices based on topology constraints              │
│   ├── Creates ResourceClaim with CEL selectors                   │
│   │   • Specific device selection (PCI address match)            │
│   │   • NUMA locality constraints (same NUMA node)               │
│   │   • Device type constraints (PF vs VF)                       │
│   └── Submits ResourceClaim to Kubernetes API                    │
└────────────────────────────────────────────────────────────────────┘
                                ↓
┌────────────────────────────────────────────────────────────────────┐
│ 4. Device Allocation & CDI Injection                              │
│                                                                    │
│   mock-accel-dra-driver Node Agent                                │
│   ├── Receives PrepareResources call from kubelet                │
│   ├── Writes "1" to /sys/class/mock-accel/<device>/status        │
│   ├── Generates CDI spec at /var/run/cdi/                        │
│   └── Returns CDI device reference to kubelet                    │
│                                                                    │
│   Container Runtime (containerd + crun)                           │
│   ├── Reads CDI spec file                                         │
│   ├── Injects environment variables into container               │
│   └── Mounts sysfs device path (read-only)                       │
└────────────────────────────────────────────────────────────────────┘
```

### ResourceSlice Schema

Each mock-accel device publishes a complete ResourceSlice with topology information:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: mock-accel.example.com-mock-cluster-node1-mock0
  labels:
    driver: mock-accel.example.com
    node: mock-cluster-node1
    device: mock0
spec:
  nodeName: mock-cluster-node1
  pool:
    name: mock0              # Each device is its own pool
    generation: 1
    resourceSliceCount: 1
  driver: mock-accel.example.com
  devices:
  - name: mock0
    basic:
      attributes:
        # All attributes are prefixed with driver domain
        mock-accel.example.com/uuid: {stringValue: "NODE1-NUMA0-PF"}
        mock-accel.example.com/memory: {intValue: 17179869184}
        mock-accel.example.com/deviceType: {stringValue: "pf"}
        mock-accel.example.com/pciAddress: {stringValue: "0000:11:00.0"}
        mock-accel.example.com/numaNode: {intValue: 0}        # KEY for topology
        mock-accel.example.com/capabilities: {intValue: 1}
        # VFs only:
        mock-accel.example.com/physfn: {stringValue: "mock0"}  # Parent PF
      capacity:
        mock-accel.example.com/memory: 16Gi
```

**Key Topology Attributes:**
- `numaNode` - NUMA node (0-based integer)
- `pciAddress` - Full PCI BDF address (e.g., `0000:11:00.0`)
- `deviceType` - `"pf"` (Physical Function) or `"vf"` (Virtual Function)
- `physfn` - Parent PF name for VFs (enables VF grouping)

---

## Reading Topology in Your Driver

### Discovering Devices from ResourceSlices

```go
package metadriver

import (
    "context"
    "fmt"

    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    resourcev1 "k8s.io/api/resource/v1"
    "k8s.io/client-go/kubernetes"
)

// TopologyDevice represents a device with parsed topology
type TopologyDevice struct {
    Name       string
    NumaNode   int
    PCIAddress string
    DeviceType string  // "pf" or "vf"
    ParentPF   string  // For VFs only
    UUID       string
    Memory     int64
    Pool       string
}

// DiscoverMockDevices discovers all mock-accel devices on a specific node
func (d *MetaDriver) DiscoverMockDevices(ctx context.Context, nodeName string) ([]TopologyDevice, error) {
    // List ResourceSlices for mock-accel driver on this node
    selector := fmt.Sprintf("driver=mock-accel.example.com,node=%s", nodeName)
    sliceList, err := d.k8sClient.ResourceV1().ResourceSlices().List(ctx, metav1.ListOptions{
        LabelSelector: selector,
    })
    if err != nil {
        return nil, fmt.Errorf("failed to list ResourceSlices: %w", err)
    }

    devices := []TopologyDevice{}
    for _, slice := range sliceList.Items {
        for _, dev := range slice.Spec.Devices {
            // Parse topology attributes (all prefixed with driver domain)
            attrs := dev.Attributes
            device := TopologyDevice{
                Name:       dev.Name,
                Pool:       slice.Spec.Pool.Name,
                NumaNode:   int(*attrs["mock-accel.example.com/numaNode"].IntValue),
                PCIAddress: *attrs["mock-accel.example.com/pciAddress"].StringValue,
                DeviceType: *attrs["mock-accel.example.com/deviceType"].StringValue,
                UUID:       *attrs["mock-accel.example.com/uuid"].StringValue,
                Memory:     *attrs["mock-accel.example.com/memory"].IntValue,
            }

            // For VFs, parse parent PF
            if device.DeviceType == "vf" {
                if physfn, ok := attrs["mock-accel.example.com/physfn"]; ok {
                    device.ParentPF = *physfn.StringValue
                }
            }

            devices = append(devices, device)
        }
    }

    return devices, nil
}
```

### Building Topology Maps

```go
// TopologyMap organizes devices by topology dimensions
type TopologyMap struct {
    ByNUMA   map[int][]TopologyDevice          // NUMA node → devices
    ByPCIBus map[string][]TopologyDevice       // PCIe bus → devices
    ByPF     map[string][]TopologyDevice       // PF name → VFs
    AllPFs   []TopologyDevice                   // All PF devices
    AllVFs   []TopologyDevice                   // All VF devices
}

// BuildTopologyMap creates a topology map from discovered devices
func BuildTopologyMap(devices []TopologyDevice) *TopologyMap {
    topo := &TopologyMap{
        ByNUMA:   make(map[int][]TopologyDevice),
        ByPCIBus: make(map[string][]TopologyDevice),
        ByPF:     make(map[string][]TopologyDevice),
    }

    for _, dev := range devices {
        // Group by NUMA node
        topo.ByNUMA[dev.NumaNode] = append(topo.ByNUMA[dev.NumaNode], dev)

        // Group by PCIe bus (extract from PCI address)
        // Example: "0000:11:00.0" → bus "0x11"
        bus := extractPCIBus(dev.PCIAddress)
        topo.ByPCIBus[bus] = append(topo.ByPCIBus[bus], dev)

        // Separate PFs and VFs
        if dev.DeviceType == "pf" {
            topo.AllPFs = append(topo.AllPFs, dev)
        } else if dev.DeviceType == "vf" {
            topo.AllVFs = append(topo.AllVFs, dev)
            // Group VFs by parent PF
            topo.ByPF[dev.ParentPF] = append(topo.ByPF[dev.ParentPF], dev)
        }
    }

    return topo
}

// extractPCIBus extracts bus number from PCI address
// Example: "0000:11:00.0" returns "0x11"
func extractPCIBus(pciAddr string) string {
    parts := strings.Split(pciAddr, ":")
    if len(parts) >= 2 {
        return "0x" + parts[1]
    }
    return ""
}
```

---

## Creating Topology-Aware Claims

### CEL Expression Helpers

```go
package metadriver

import (
    "fmt"
    "strings"
)

// CELSelector builds CEL expressions for device selection
type CELSelector struct {
    expressions []string
}

// NewCELSelector creates a new CEL selector builder
func NewCELSelector() *CELSelector {
    return &CELSelector{}
}

// WithNUMANode adds NUMA node constraint
func (c *CELSelector) WithNUMANode(numaNode int) *CELSelector {
    expr := fmt.Sprintf(`device.attributes["mock-accel.example.com/numaNode"].intValue == %d`, numaNode)
    c.expressions = append(c.expressions, expr)
    return c
}

// WithPCIAddress adds exact PCI address match
func (c *CELSelector) WithPCIAddress(pciAddr string) *CELSelector {
    expr := fmt.Sprintf(`device.attributes["mock-accel.example.com/pciAddress"].stringValue == "%s"`, pciAddr)
    c.expressions = append(c.expressions, expr)
    return c
}

// WithDeviceType adds device type constraint (pf or vf)
func (c *CELSelector) WithDeviceType(devType string) *CELSelector {
    expr := fmt.Sprintf(`device.attributes["mock-accel.example.com/deviceType"].stringValue == "%s"`, devType)
    c.expressions = append(c.expressions, expr)
    return c
}

// WithParentPF adds parent PF constraint (VFs only)
func (c *CELSelector) WithParentPF(pfName string) *CELSelector {
    expr := fmt.Sprintf(`device.attributes["mock-accel.example.com/physfn"].stringValue == "%s"`, pfName)
    c.expressions = append(c.expressions, expr)
    return c
}

// WithMinMemory adds minimum memory constraint
func (c *CELSelector) WithMinMemory(minBytes int64) *CELSelector {
    expr := fmt.Sprintf(`device.capacity["mock-accel.example.com/memory"].isGreaterThan(quantity("%d"))`, minBytes)
    c.expressions = append(c.expressions, expr)
    return c
}

// Build returns the combined CEL expression
func (c *CELSelector) Build() string {
    return strings.Join(c.expressions, " && ")
}
```

### Example: NUMA Locality Claim

```go
import (
    resourcev1 "k8s.io/api/resource/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// CreateNUMALocalityClaim creates a claim for devices on same NUMA node
func (d *MetaDriver) CreateNUMALocalityClaim(numaNode int, devices []TopologyDevice) *resourcev1.ResourceClaim {
    claim := &resourcev1.ResourceClaim{
        ObjectMeta: metav1.ObjectMeta{
            Name: "numa-locality-claim",
            Labels: map[string]string{
                "meta-dra.k8s.io/coordinated": "true",
                "meta-dra.k8s.io/strategy":    "numa-local",
            },
        },
        Spec: resourcev1.ResourceClaimSpec{
            Devices: resourcev1.DeviceClaim{
                Requests: []resourcev1.DeviceRequest{},
                Constraints: []resourcev1.DeviceConstraint{
                    {
                        // All devices must be on same NUMA node
                        Requests:       []string{},  // Will be populated below
                        MatchAttribute: stringPtr("mock-accel.example.com/numaNode"),
                    },
                },
            },
        },
    }

    // Add request for each device with specific PCI address selector
    for i, dev := range devices {
        requestName := fmt.Sprintf("device-%d", i)

        selector := NewCELSelector().
            WithNUMANode(numaNode).
            WithPCIAddress(dev.PCIAddress).
            WithDeviceType("pf").
            Build()

        request := resourcev1.DeviceRequest{
            Name:            requestName,
            DeviceClassName: "mock-accel-pf",
            Count:           1,
            Selectors: []resourcev1.DeviceSelector{
                {
                    CEL: &resourcev1.CELDeviceSelector{
                        Expression: selector,
                    },
                },
            },
        }

        claim.Spec.Devices.Requests = append(claim.Spec.Devices.Requests, request)
        claim.Spec.Devices.Constraints[0].Requests = append(
            claim.Spec.Devices.Constraints[0].Requests,
            requestName,
        )
    }

    return claim
}

func stringPtr(s string) *string {
    return &s
}
```

### Example: PCIe Bus Locality Claim

```go
// CreatePCIeLocalityClaim creates a claim for devices on same PCIe bus
func (d *MetaDriver) CreatePCIeLocalityClaim(bus string, devices []TopologyDevice) *resourcev1.ResourceClaim {
    claim := &resourcev1.ResourceClaim{
        ObjectMeta: metav1.ObjectMeta{
            Name: "pcie-locality-claim",
            Labels: map[string]string{
                "meta-dra.k8s.io/coordinated": "true",
                "meta-dra.k8s.io/strategy":    "pcie-local",
            },
        },
        Spec: resourcev1.ResourceClaimSpec{
            Devices: resourcev1.DeviceClaim{
                Requests: []resourcev1.DeviceRequest{},
            },
        },
    }

    // Add request for each device on the specified bus
    for i, dev := range devices {
        requestName := fmt.Sprintf("device-%d", i)

        // CEL: PCI address starts with bus prefix (e.g., "0000:11:")
        selector := fmt.Sprintf(
            `device.attributes["mock-accel.example.com/pciAddress"].stringValue.startsWith("%s:")`,
            strings.TrimPrefix(bus, "0x"),
        )

        request := resourcev1.DeviceRequest{
            Name:            requestName,
            DeviceClassName: "mock-accel-pf",
            Count:           1,
            Selectors: []resourcev1.DeviceSelector{
                {
                    CEL: &resourcev1.CELDeviceSelector{
                        Expression: selector,
                    },
                },
            },
        }

        claim.Spec.Devices.Requests = append(claim.Spec.Devices.Requests, request)
    }

    return claim
}
```

---

## Test Scenarios

### Scenario 1: NUMA Locality Testing

**Goal**: Verify meta-driver selects devices on same NUMA node

**Test Cluster Topology**:
```
Node 1:
  NUMA 0: mock0 (PCI 0000:11:00.0), mock1 (PCI 0000:11:00.1), mock2 (PCI 0000:11:00.2)
  NUMA 1: mock3 (PCI 0000:21:00.0), mock4 (PCI 0000:21:00.1), mock5 (PCI 0000:21:00.2)
Node 2:
  NUMA 0: mock0 (PCI 0000:11:00.0), mock1 (PCI 0000:11:00.1), mock2 (PCI 0000:11:00.2)
  NUMA 1: mock3 (PCI 0000:21:00.0), mock4 (PCI 0000:21:00.1), mock5 (PCI 0000:21:00.2)
```

**Setup**:
```bash
# Start NUMA cluster
cd mock-device
./scripts/start-numa-cluster.sh

# Deploy mock-accel-dra-driver
kubectl apply -f dra-driver/deployments/

# Verify ResourceSlices published with NUMA info
kubectl get resourceslices -o custom-columns=\
NAME:.metadata.name,\
DEVICE:.spec.devices[0].name,\
NUMA:.spec.devices[0].basic.attributes.mock-accel\.example\.com/numaNode.intValue
```

**Test Code**:
```go
func TestNUMALocality(t *testing.T) {
    ctx := context.Background()
    k8sClient := getK8sClient(t)

    // Discover devices
    devices, err := metaDriver.DiscoverMockDevices(ctx, "mock-cluster-node1")
    require.NoError(t, err)

    // Build topology map
    topo := BuildTopologyMap(devices)

    // Select 2 devices from NUMA 0
    numa0Devices := topo.ByNUMA[0]
    require.GreaterOrEqual(t, len(numa0Devices), 2, "Need at least 2 devices on NUMA 0")

    // Create claim for NUMA locality
    claim := metaDriver.CreateNUMALocalityClaim(0, numa0Devices[:2])

    // Create claim
    _, err = k8sClient.ResourceV1().ResourceClaims("default").Create(ctx, claim, metav1.CreateOptions{})
    require.NoError(t, err)

    // Wait for allocation
    waitForClaimAllocated(t, k8sClient, "numa-locality-claim", 60*time.Second)

    // Verify both devices allocated from NUMA 0
    claim, err = k8sClient.ResourceV1().ResourceClaims("default").Get(ctx, "numa-locality-claim", metav1.GetOptions{})
    require.NoError(t, err)

    for _, result := range claim.Status.Allocation.Devices.Results {
        // Verify device is from NUMA 0
        deviceName := result.Device
        // SSH to node and check NUMA node
        numaNode := getDeviceNUMA(t, "mock-cluster-node1", deviceName)
        assert.Equal(t, 0, numaNode, "Device %s should be on NUMA 0", deviceName)
    }
}
```

### Scenario 2: PCIe Bus Locality

**Goal**: Verify meta-driver selects devices on same PCIe bus

**Test**:
```go
func TestPCIeBusLocality(t *testing.T) {
    ctx := context.Background()

    // Discover devices
    devices, err := metaDriver.DiscoverMockDevices(ctx, "mock-cluster-node1")
    require.NoError(t, err)

    // Build topology map
    topo := BuildTopologyMap(devices)

    // Select devices from bus 0x11
    bus11Devices := topo.ByPCIBus["0x11"]
    require.GreaterOrEqual(t, len(bus11Devices), 2)

    // Create claim for PCIe bus locality
    claim := metaDriver.CreatePCIeLocalityClaim("0x11", bus11Devices[:2])

    // Test allocation...
    // Verify all devices have PCI addresses starting with "0000:11:"
}
```

### Scenario 3: SR-IOV VF Allocation

**Goal**: Allocate VFs from same PF

**Setup**:
```bash
# SSH into node
sshpass -p "test123" ssh fedora@192.168.122.211

# Enable 2 VFs on mock0
echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs

# Verify VFs appeared
ls /sys/class/mock-accel/
# mock0  mock0_vf0  mock0_vf1  mock1  ...

# Exit and wait for ResourceSlices to update
kubectl get resourceslices | grep _vf
```

**Test Code**:
```go
func TestSRIOVAllocation(t *testing.T) {
    // Discover devices including VFs
    devices, err := metaDriver.DiscoverMockDevices(ctx, "mock-cluster-node1")
    require.NoError(t, err)

    // Build topology map
    topo := BuildTopologyMap(devices)

    // Select VFs from mock0
    vfs := topo.ByPF["mock0"]
    require.GreaterOrEqual(t, len(vfs), 2, "Need at least 2 VFs from mock0")

    // Create claim for VFs from same PF
    claim := &resourcev1.ResourceClaim{
        ObjectMeta: metav1.ObjectMeta{Name: "sriov-vf-claim"},
        Spec: resourcev1.ResourceClaimSpec{
            Devices: resourcev1.DeviceClaim{
                Requests: []resourcev1.DeviceRequest{
                    {
                        Name:            "vf-0",
                        DeviceClassName: "mock-accel-vf",
                        Count:           1,
                        Selectors: []resourcev1.DeviceSelector{{
                            CEL: &resourcev1.CELDeviceSelector{
                                Expression: NewCELSelector().
                                    WithDeviceType("vf").
                                    WithParentPF("mock0").
                                    WithPCIAddress(vfs[0].PCIAddress).
                                    Build(),
                            },
                        }},
                    },
                    {
                        Name:            "vf-1",
                        DeviceClassName: "mock-accel-vf",
                        Count:           1,
                        Selectors: []resourcev1.DeviceSelector{{
                            CEL: &resourcev1.CELDeviceSelector{
                                Expression: NewCELSelector().
                                    WithDeviceType("vf").
                                    WithParentPF("mock0").
                                    WithPCIAddress(vfs[1].PCIAddress).
                                    Build(),
                            },
                        }},
                    },
                },
                Constraints: []resourcev1.DeviceConstraint{
                    {
                        Requests:       []string{"vf-0", "vf-1"},
                        MatchAttribute: stringPtr("mock-accel.example.com/physfn"),
                    },
                },
            },
        },
    }

    // Test allocation...
}
```

---

## Common Patterns

### Pattern 1: Filtering by Device Capability

```go
// Select devices with encryption capability (bit 1 set)
selector := `(device.attributes["mock-accel.example.com/capabilities"].intValue & 2) != 0`
```

### Pattern 2: Cross-NUMA Spread

```go
// Allocate devices spread across NUMA nodes
claim := &resourcev1.ResourceClaim{
    Spec: resourcev1.ResourceClaimSpec{
        Devices: resourcev1.DeviceClaim{
            Requests: []resourcev1.DeviceRequest{
                {
                    Name:            "numa0-device",
                    DeviceClassName: "mock-accel-pf",
                    Count:           1,
                    Selectors: []resourcev1.DeviceSelector{{
                        CEL: &resourcev1.CELDeviceSelector{
                            Expression: `device.attributes["mock-accel.example.com/numaNode"].intValue == 0`,
                        },
                    }},
                },
                {
                    Name:            "numa1-device",
                    DeviceClassName: "mock-accel-pf",
                    Count:           1,
                    Selectors: []resourcev1.DeviceSelector{{
                        CEL: &resourcev1.CELDeviceSelector{
                            Expression: `device.attributes["mock-accel.example.com/numaNode"].intValue == 1`,
                        },
                    }},
                },
            },
        },
    },
}
```

### Pattern 3: Memory-based Selection

```go
// Select devices with at least 8GB memory
selector := NewCELSelector().
    WithMinMemory(8 * 1024 * 1024 * 1024).
    WithDeviceType("pf").
    Build()
```

---

## Troubleshooting

### Issue: ResourceSlices not appearing

**Symptoms**: `kubectl get resourceslices` shows no mock-accel slices

**Debug**:
```bash
# Check controller pods running
kubectl get pods -n mock-device -l app=mock-accel-controller

# Check controller logs
kubectl logs -n mock-device deployment/mock-accel-controller

# Verify devices exist in sysfs on node
sshpass -p "test123" ssh fedora@192.168.122.211 "ls /sys/class/mock-accel/"

# Check if kernel module loaded
sshpass -p "test123" ssh fedora@192.168.122.211 "lsmod | grep mock_accel"
```

**Resolution**: Ensure kernel module loaded and sysfs devices present.

---

### Issue: Topology attributes missing

**Symptoms**: ResourceSlice exists but numaNode or pciAddress attributes are zero/empty

**Debug**:
```bash
# Inspect ResourceSlice YAML
kubectl get resourceslice <name> -o yaml

# Check sysfs attributes on node
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "cat /sys/class/mock-accel/mock0/numa_node"
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "cat /sys/class/mock-accel/mock0/device/numa_node"
```

**Resolution**: Verify kernel driver correctly exposes NUMA topology.

---

### Issue: CEL expression fails

**Symptoms**: Pod stuck in Pending, events show CEL evaluation error

**Debug**:
```bash
# Check pod events
kubectl describe pod <pod-name>

# Verify attribute names match exactly (case-sensitive, with domain prefix)
kubectl get resourceslice <name> -o jsonpath='{.spec.devices[0].basic.attributes}'
```

**Common Mistakes**:
- Missing driver domain prefix: ❌ `device.attributes["numaNode"]` ✅ `device.attributes["mock-accel.example.com/numaNode"]`
- Wrong attribute type: ❌ `.intValue == "0"` ✅ `.intValue == 0`
- Typo in attribute name: ❌ `numa_node` ✅ `numaNode`

---

## References

- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [CEL Expression Language](https://github.com/google/cel-spec)
- [mock-device API Reference](api-reference.md)
- [mock-device Testing Guide](testing-guide.md)
- [mock-device Project README](../README.md)
