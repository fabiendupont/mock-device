# Mock-Accel DRA Driver

A Kubernetes Dynamic Resource Allocation (DRA) driver for mock-accel devices. This driver enables Kubernetes to discover, allocate, and manage mock PCIe accelerator devices with NUMA topology awareness.

## Overview

This DRA driver implements the Kubernetes DRA v1alpha3 API to:
- Discover mock-accel devices from `/sys/class/mock-accel/`
- Publish ResourceSlices with device properties and NUMA topology
- Handle device allocation/deallocation via sysfs status registers
- Generate CDI (Container Device Interface) specs for container runtime integration
- Support Physical Functions (PF) and Virtual Functions (VF)

## Architecture

```
┌──────────────┐         ┌──────────────────┐
│  Controller  │◄────────┤  Kubernetes API  │
│  Deployment  │         │  ResourceSlices  │
└──────────────┘         └──────────────────┘
                                  ▲
                                  │
┌──────────────┐                 │
│ Node Agent   │─────────────────┘
│  DaemonSet   │
└──────────────┘
       │
       ▼
┌──────────────┐         ┌──────────────────┐
│   Sysfs      │         │   CDI Specs      │
│   /sys/...   │         │   /var/run/cdi/  │
└──────────────┘         └──────────────────┘
```

**Controller**: Scans devices and publishes ResourceSlices
**Node Agent**: Kubelet gRPC plugin for allocation and CDI generation

## Prerequisites

- Kubernetes cluster with DRA support (v1.26+)
- mock-accel kernel module loaded on nodes
- Container runtime with CDI support (containerd, crun)

## Building

```bash
# Build Go binary
make build

# Build container image
make build-image

# Load image into k3s (for testing)
make load-image
```

## Deployment

```bash
# Deploy RBAC, controller, node agent, and DeviceClasses
make deploy

# Or manually:
kubectl apply -f deployments/rbac.yaml
kubectl apply -f deployments/controller.yaml
kubectl apply -f deployments/node-agent.yaml
kubectl apply -f deployments/deviceclass.yaml
```

## Device Classes

The driver includes several pre-defined DeviceClasses:

### mock-accel-pf
Physical Functions only:
```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: DeviceClass
metadata:
  name: mock-accel-pf
spec:
  selectors:
  - cel:
      expression: device.attributes["deviceType"].string == "pf"
```

### mock-accel-vf
Virtual Functions only:
```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: DeviceClass
metadata:
  name: mock-accel-vf
spec:
  selectors:
  - cel:
      expression: device.attributes["deviceType"].string == "vf"
```

### mock-accel-vf-2gb
VFs with at least 2GB memory:
```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: DeviceClass
metadata:
  name: mock-accel-vf-2gb
spec:
  selectors:
  - cel:
      expression: |
        device.attributes["deviceType"].string == "vf" &&
        device.capacity["memory"].isGreaterThan(quantity("2Gi"))
```

## Usage Example

### Create a ResourceClaim

```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: ResourceClaim
metadata:
  name: my-accel-claim
  namespace: default
spec:
  devices:
    requests:
    - name: accel
      deviceClassName: mock-accel-pf
      count: 1
```

### Use in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: accel-test
spec:
  resourceClaims:
  - name: accel
    resourceClaimName: my-accel-claim
  containers:
  - name: app
    image: busybox
    command:
    - sh
    - -c
    - |
      echo "Device UUID: $MOCK_ACCEL_UUID"
      echo "PCI Address: $MOCK_ACCEL_PCI"
      ls -la /sys/class/mock-accel/$MOCK_ACCEL_DEVICE
      sleep 3600
    resources:
      claims:
      - name: accel
```

### Verify Allocation

```bash
# Check ResourceSlices
kubectl get resourceslices

# Check device status in sysfs (on node)
cat /sys/class/mock-accel/mock0/status
# Should show "1" (allocated)

# Check CDI spec (on node)
cat /var/run/cdi/mock-accel_example_com-mock0.json

# Check pod environment
kubectl exec accel-test -- env | grep MOCK_ACCEL
```

## Device Attributes

ResourceSlices include the following device attributes:

| Attribute | Type | Description | Example |
|-----------|------|-------------|---------|
| `uuid` | string | Device unique identifier | `NODE1-NUMA0-PF` |
| `memory` | int64 | Device memory in bytes | `17179869184` (16GB) |
| `deviceType` | string | PF or VF | `"pf"` or `"vf"` |
| `pciAddress` | string | PCI BDF address | `"0000:11:00.0"` |
| `physfn` | string | Parent PF (VFs only) | `"mock0"` |
| `capabilities` | int64 | Device capability flags | `1` |

## NUMA Topology

Devices are grouped into pools by NUMA node:
- Pool `numa0`: Devices on NUMA node 0
- Pool `numa1`: Devices on NUMA node 1

The Kubernetes scheduler can use pool information for topology-aware allocation.

## Documentation

For comprehensive guides and references:

- **[Integration Guide](../docs/integration-guide.md)** - How to integrate mock-device with meta-DRA drivers (especially Node Partition DRA driver). Includes topology discovery patterns, CEL selectors, and test scenarios.

- **[API Reference](../docs/api-reference.md)** - Complete API documentation for Go packages, sysfs interface, ResourceSlice schema, and CDI specifications.

- **[Testing Guide](../docs/testing-guide.md)** - End-to-end testing strategies, test scenarios (discovery, allocation, NUMA, SR-IOV), performance testing, and CI/CD integration.

- **[Extension Guide](../docs/extension-guide.md)** - How to extend mock-device with new device attributes and capabilities for testing advanced DRA scenarios.

- **[Usage Examples](../docs/examples/)** - Complete YAML examples for common allocation patterns:
  - `basic-allocation.yaml` - Simple single device allocation
  - `numa-locality.yaml` - NUMA-aware multi-device allocation
  - `pcie-locality.yaml` - PCIe bus locality constraints
  - `sriov-vf-allocation.yaml` - SR-IOV VF allocation from same PF
  - `mixed-pf-vf.yaml` - Mixed PF and VF allocation

## Integration with k8s-dra-driver-nodepartition

This driver is designed to work with the k8s-dra-driver-nodepartition meta-driver:

1. mock-accel-dra-driver publishes ResourceSlices with topology attributes
2. k8s-dra-driver-nodepartition reads and aggregates topology
3. Meta-driver coordinates multi-device, NUMA-aware allocation

## Troubleshooting

### Controller not creating ResourceSlices

```bash
# Check controller logs
kubectl logs -n mock-device deployment/mock-accel-controller

# Verify devices exist on nodes
ssh node1 ls /sys/class/mock-accel/
```

### Node agent not allocating devices

```bash
# Check node agent logs
kubectl logs -n mock-device daemonset/mock-accel-node-agent

# Verify gRPC socket exists
ssh node1 ls -la /var/lib/kubelet/plugins/mock-accel.example.com/

# Check CDI directory
ssh node1 ls -la /var/run/cdi/
```

### Devices not appearing in pods

```bash
# Verify CDI spec was generated
ssh node1 cat /var/run/cdi/mock-accel_example_com-mock0.json

# Check container runtime supports CDI
ssh node1 crun --version
# Should show CDI support

# Check status register
ssh node1 cat /sys/class/mock-accel/mock0/status
# Should show "1" when allocated
```

## Development

### Running Tests

```bash
make test
```

### Code Formatting

```bash
make fmt
```

### Linting

```bash
make lint
```

## License

Apache License 2.0

## References

- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [Container Device Interface Specification](https://github.com/cncf-tags/container-device-interface)
- [mock-device Project](../README.md)
