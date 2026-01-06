# Mock Device Testing Guide

## Overview

This guide provides comprehensive end-to-end testing strategies for DRA (Dynamic Resource Allocation) driver developers using the mock-device project. It covers test environment setup, validation scenarios, performance testing, debugging techniques, and CI/CD integration.

---

## Test Environment Setup

### Quick Start (Complete Cluster)

The fastest way to get a fully functional test environment:

```bash
# Clone the repository
git clone https://github.com/fabiendupont/mock-device.git
cd mock-device

# Start NUMA-aware cluster (2 nodes × 2 NUMA × 3 devices)
./scripts/start-numa-cluster.sh

# Setup k3s cluster with crun runtime
./scripts/setup-k3s-cluster.sh

# Deploy kernel module via KMM
./scripts/deploy-kmm-module.sh

# Verify cluster status
./scripts/status-cluster.sh
```

**Expected Result:**
- 2 QEMU VMs running (mock-cluster-node1, mock-cluster-node2)
- k3s cluster operational with crun as default runtime
- mock-accel kernel module loaded on both nodes
- 12 devices available (2 nodes × 2 NUMA × 3 devices)

---

### Manual Setup Steps

For custom configurations or troubleshooting:

#### 1. Start vfio-user Servers

```bash
# Start 12 mock-accel-server processes (example for node 1, NUMA 0)
./vfio-user/mock-accel-server -u "NODE1-NUMA0-PF" /tmp/mock-accel-node1-numa0-pf.sock &
./vfio-user/mock-accel-server -u "NODE1-NUMA0-VF0" /tmp/mock-accel-node1-numa0-vf0.sock &
./vfio-user/mock-accel-server -u "NODE1-NUMA0-VF1" /tmp/mock-accel-node1-numa0-vf1.sock &
# ... repeat for NUMA 1, node 2
```

#### 2. Boot QEMU VMs with NUMA Topology

```bash
# See scripts/start-numa-cluster.sh for complete QEMU command line
# Key parameters:
# - pxb-pcie devices with numa_node parameter
# - pcie-root-port attached to pxb-pcie
# - vfio-user-pci devices attached to root ports
```

#### 3. Install k3s with crun

**CRITICAL**: k3s must use crun (not runc) for KMM to work:

```bash
# Server node
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "curl -sfL https://get.k3s.io | sh -s - server \
    --disable=traefik \
    --node-name=mock-cluster-node1 \
    --default-runtime crun"

# Agent node
sshpass -p "test123" ssh fedora@192.168.122.212 \
  "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.122.211:6443 K3S_TOKEN='...' sh -s - agent \
    --node-name=mock-cluster-node2 \
    --default-runtime crun"
```

#### 4. Deploy KMM and Module

```bash
# Install cert-manager (required by KMM)
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml"

# Wait for cert-manager webhook
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl wait --for=condition=Available --timeout=180s deployment -n cert-manager cert-manager-webhook"

# Install KMM operator
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default?ref=v2.4.1"

# Build and load module image
cd kernel-driver
make build-image
make load-image

# Deploy Module CR
kubectl apply -f kernel-driver/deployments/module.yaml
```

#### 5. Verification Commands

```bash
# Check nodes are Ready
kubectl get nodes

# Verify crun is default runtime
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "sudo k3s crictl info 2>/dev/null | grep -A2 defaultRuntimeName"
# Expected: "defaultRuntimeName": "crun"

# Check kernel module loaded
sshpass -p "test123" ssh fedora@192.168.122.211 "lsmod | grep mock_accel"
sshpass -p "test123" ssh fedora@192.168.122.212 "lsmod | grep mock_accel"

# Verify sysfs devices
sshpass -p "test123" ssh fedora@192.168.122.211 "ls -la /sys/class/mock-accel/"
# Expected: mock0, mock1, mock2, mock3, mock4, mock5

# Check NUMA topology
sshpass -p "test123" ssh fedora@192.168.122.211 \
  "for d in /sys/class/mock-accel/mock*; do echo \"\$(basename \$d): NUMA \$(cat \$d/numa_node)\"; done"
# Expected:
# mock0: NUMA 0
# mock1: NUMA 0
# mock2: NUMA 0
# mock3: NUMA 1
# mock4: NUMA 1
# mock5: NUMA 1
```

---

## Test Scenarios

### Scenario 1: Basic Device Discovery

**Goal**: Verify DRA driver discovers devices and publishes ResourceSlices.

**Setup**:
```bash
# Deploy DRA driver
cd dra-driver
make deploy

# Wait for controller to be Running
kubectl wait --for=condition=Ready pod -n mock-device -l app=mock-accel-controller --timeout=60s
```

**Validation**:
```bash
# Check ResourceSlices published
kubectl get resourceslices

# Expected output: One ResourceSlice per device
# NAME                                                      NODE                  DRIVER
# mock-accel.example.com-mock-cluster-node1-mock0          mock-cluster-node1    mock-accel.example.com
# mock-accel.example.com-mock-cluster-node1-mock1          mock-cluster-node1    mock-accel.example.com
# ...

# Verify device attributes
kubectl get resourceslice mock-accel.example.com-mock-cluster-node1-mock0 -o yaml

# Check for required attributes
kubectl get resourceslice mock-accel.example.com-mock-cluster-node1-mock0 -o jsonpath='{.spec.devices[0].basic.attributes}' | jq .

# Expected attributes:
# - mock-accel.example.com/uuid
# - mock-accel.example.com/memory
# - mock-accel.example.com/deviceType (pf or vf)
# - mock-accel.example.com/pciAddress
# - mock-accel.example.com/numaNode
# - mock-accel.example.com/capabilities

# Verify capacity
kubectl get resourceslice mock-accel.example.com-mock-cluster-node1-mock0 -o jsonpath='{.spec.devices[0].basic.capacity}' | jq .
# Expected: {"mock-accel.example.com/memory": "16Gi"}
```

**Test Script**:
```bash
#!/bin/bash
set -e

echo "=== Device Discovery Test ==="

# Count ResourceSlices
EXPECTED_COUNT=12  # 2 nodes × 6 devices
ACTUAL_COUNT=$(kubectl get resourceslices -l driver=mock-accel.example.com --no-headers | wc -l)

if [ "$ACTUAL_COUNT" -eq "$EXPECTED_COUNT" ]; then
  echo "✓ PASS: Found $ACTUAL_COUNT ResourceSlices (expected $EXPECTED_COUNT)"
else
  echo "✗ FAIL: Found $ACTUAL_COUNT ResourceSlices (expected $EXPECTED_COUNT)"
  exit 1
fi

# Verify each slice has required attributes
for slice in $(kubectl get resourceslices -l driver=mock-accel.example.com -o name); do
  uuid=$(kubectl get $slice -o jsonpath='{.spec.devices[0].basic.attributes.mock-accel\.example\.com/uuid.stringValue}')
  numa=$(kubectl get $slice -o jsonpath='{.spec.devices[0].basic.attributes.mock-accel\.example\.com/numaNode.intValue}')
  pci=$(kubectl get $slice -o jsonpath='{.spec.devices[0].basic.attributes.mock-accel\.example\.com/pciAddress.stringValue}')

  if [ -z "$uuid" ] || [ -z "$numa" ] || [ -z "$pci" ]; then
    echo "✗ FAIL: $slice missing required attributes"
    exit 1
  fi
done

echo "✓ PASS: All ResourceSlices have required attributes"
```

---

### Scenario 2: Device Allocation

**Goal**: Verify device allocation writes to sysfs status register and generates CDI spec.

**Setup**:
```bash
# Apply basic allocation example
kubectl apply -f docs/examples/basic-allocation.yaml

# Wait for pod to be Running
kubectl wait --for=condition=Ready pod/basic-allocation-test --timeout=60s
```

**Validation**:
```bash
# Get allocated device name
DEVICE=$(kubectl exec basic-allocation-test -- env | grep MOCK_ACCEL_DEVICE | cut -d= -f2)

# Check sysfs status register (should be 1 = allocated)
NODE_IP=192.168.122.211  # Or extract from pod.spec.nodeName
sshpass -p "test123" ssh fedora@$NODE_IP "cat /sys/class/mock-accel/$DEVICE/status"
# Expected: 1

# Verify CDI spec exists
sshpass -p "test123" ssh fedora@$NODE_IP "ls -la /var/run/cdi/ | grep $DEVICE"
# Expected: example.com_mock-accel-<device>.json

# Check CDI spec content
sshpass -p "test123" ssh fedora@$NODE_IP "cat /var/run/cdi/example.com_mock-accel-$DEVICE.json" | jq .

# Verify environment variables in container
kubectl exec basic-allocation-test -- env | grep MOCK_ACCEL
# Expected:
# MOCK_ACCEL_DEVICE=mock0
# MOCK_ACCEL_UUID=NODE1-NUMA0-PF
# MOCK_ACCEL_PCI=0000:11:00.0

# Verify sysfs mount in container
kubectl exec basic-allocation-test -- ls /sys/class/mock-accel/$DEVICE/
# Expected: capabilities, device, memory_size, numa_node, status, uuid
```

**Test Deallocation**:
```bash
# Delete pod
kubectl delete -f docs/examples/basic-allocation.yaml

# Wait for pod to terminate
kubectl wait --for=delete pod/basic-allocation-test --timeout=60s

# Check sysfs status register (should be 0 = free)
sshpass -p "test123" ssh fedora@$NODE_IP "cat /sys/class/mock-accel/$DEVICE/status"
# Expected: 0

# Verify CDI spec removed
sshpass -p "test123" ssh fedora@$NODE_IP "ls /var/run/cdi/ | grep $DEVICE"
# Expected: (no output)
```

---

### Scenario 3: NUMA Topology Awareness

**Goal**: Verify allocation respects NUMA locality constraints.

**Setup**:
```bash
# Apply NUMA locality example
kubectl apply -f docs/examples/numa-locality.yaml

# Wait for pod to be Running
kubectl wait --for=condition=Ready pod/numa-locality-test --timeout=60s
```

**Validation**:
```bash
# Extract device names from environment
kubectl exec numa-locality-test -- env | grep MOCK_ACCEL_DEVICE

# Verify all devices on same NUMA node
kubectl exec numa-locality-test -- sh -c 'cat /sys/class/mock-accel/*/numa_node | sort -u'
# Expected: Single value (0 or 1)

# Verify NUMA node count
UNIQUE_NUMA=$(kubectl exec numa-locality-test -- sh -c 'cat /sys/class/mock-accel/*/numa_node | sort -u | wc -l')
if [ "$UNIQUE_NUMA" -eq 1 ]; then
  echo "✓ PASS: All devices on same NUMA node"
else
  echo "✗ FAIL: Devices span $UNIQUE_NUMA NUMA nodes"
fi
```

**Test Cross-NUMA Allocation**:
```bash
# Modify claim to request devices from different NUMA nodes
cat <<EOF | kubectl apply -f -
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: cross-numa-claim
spec:
  devices:
    requests:
    - name: numa0-device
      deviceClassName: mock-accel-pf
      count: 1
      selectors:
      - cel:
          expression: device.attributes["mock-accel.example.com/numaNode"].intValue == 0
    - name: numa1-device
      deviceClassName: mock-accel-pf
      count: 1
      selectors:
      - cel:
          expression: device.attributes["mock-accel.example.com/numaNode"].intValue == 1
EOF

# Create test pod
# ... verify devices from both NUMA nodes
```

---

### Scenario 4: SR-IOV Testing

**Goal**: Verify VF allocation and parent PF relationship.

**Prerequisites**:
```bash
# Enable VFs on a PF device
NODE_IP=192.168.122.211
sshpass -p "test123" ssh fedora@$NODE_IP "echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs"

# Verify VFs appeared
sshpass -p "test123" ssh fedora@$NODE_IP "ls /sys/class/mock-accel/ | grep mock0_vf"
# Expected: mock0_vf0, mock0_vf1

# Wait for ResourceSlices to update
kubectl get resourceslices | grep _vf
# Expected: VF ResourceSlices appear within rescan interval (default 30s)
```

**Validation**:
```bash
# Apply SR-IOV VF allocation example
kubectl apply -f docs/examples/sriov-vf-allocation.yaml

# Wait for pod
kubectl wait --for=condition=Ready pod/sriov-vf-test --timeout=60s

# Verify VF parent relationship
kubectl exec sriov-vf-test -- sh -c 'for d in /sys/class/mock-accel/*; do echo "$(basename $d) -> physfn: $(readlink $d/device/physfn 2>/dev/null | xargs basename || echo N/A)"; done'

# Expected output:
# mock0_vf0 -> physfn: 0000:11:00.0
# mock0_vf1 -> physfn: 0000:11:00.0

# Verify all VFs from same parent
UNIQUE_PARENTS=$(kubectl exec sriov-vf-test -- sh -c 'readlink /sys/class/mock-accel/*/device/physfn 2>/dev/null | xargs -n1 basename | sort -u | wc -l')
if [ "$UNIQUE_PARENTS" -eq 1 ]; then
  echo "✓ PASS: All VFs from same parent PF"
else
  echo "✗ FAIL: VFs from $UNIQUE_PARENTS different parent PFs"
fi
```

**Cleanup**:
```bash
# Delete pod
kubectl delete -f docs/examples/sriov-vf-allocation.yaml

# Disable VFs
sshpass -p "test123" ssh fedora@$NODE_IP "echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs"

# Verify VFs removed
sshpass -p "test123" ssh fedora@$NODE_IP "ls /sys/class/mock-accel/ | grep _vf"
# Expected: (no output)
```

---

## Performance Testing

### Scan Performance

**Goal**: Measure device scanning latency.

**Test Script**:
```bash
#!/bin/bash

echo "=== Device Scan Performance Test ==="

# Get controller pod
CONTROLLER_POD=$(kubectl get pods -n mock-device -l app=mock-accel-controller -o name | head -1)

# Extract scan latency from logs
kubectl logs -n mock-device $CONTROLLER_POD --tail=1000 | grep "Discovered" | tail -5

# Expected output:
# I0105 12:00:00.123456       1 scanner.go:100] Discovered 6 devices
# (Latency should be < 100ms for 6 devices)

# Benchmark with time command on node
NODE_IP=192.168.122.211
sshpass -p "test123" ssh fedora@$NODE_IP "time ls /sys/class/mock-accel/" 2>&1 | grep real
# Expected: real 0m0.002s (< 10ms for directory listing)
```

**Expected Benchmarks**:
- Scan 6 devices: < 100ms
- Scan 100 devices: < 1 second
- sysfs read per device: < 5ms

---

### Allocation Throughput

**Goal**: Measure allocation performance under load.

**Test Script**:
```bash
#!/bin/bash
set -e

echo "=== Allocation Throughput Test ==="

PODS=10
START_TIME=$(date +%s)

# Create ResourceClaim template
cat <<EOF > /tmp/claim-template.yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: CLAIM_NAME
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
  name: POD_NAME
spec:
  resourceClaims:
  - name: accel
    resourceClaimName: CLAIM_NAME
  containers:
  - name: app
    image: busybox:latest
    command: ["sleep", "300"]
    resources:
      claims:
      - name: accel
  restartPolicy: Never
EOF

# Create pods
for i in $(seq 1 $PODS); do
  sed "s/CLAIM_NAME/claim-$i/g; s/POD_NAME/pod-$i/g" /tmp/claim-template.yaml | kubectl apply -f -
done

# Wait for all pods to be Running
kubectl wait --for=condition=Ready pod -l batch=perf-test --timeout=300s

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
THROUGHPUT=$(echo "scale=2; $PODS / $DURATION" | bc)

echo "✓ Allocated $PODS devices in $DURATION seconds"
echo "✓ Throughput: $THROUGHPUT allocations/second"

# Cleanup
kubectl delete pod -l batch=perf-test
kubectl delete resourceclaim -l batch=perf-test
```

**Expected Results**:
- 10 pods: < 30 seconds (0.33 pods/sec)
- 100 pods: < 5 minutes (0.33 pods/sec)
- Limited by Kubernetes scheduler, not DRA driver

---

## Debugging Tools

### Inspect ResourceSlices

```bash
# List all ResourceSlices for mock-accel driver
kubectl get resourceslices -l driver=mock-accel.example.com

# Show detailed view with custom columns
kubectl get resourceslices -l driver=mock-accel.example.com -o custom-columns=\
NAME:.metadata.name,\
NODE:.spec.nodeName,\
DEVICE:.spec.devices[0].name,\
NUMA:.spec.devices[0].basic.attributes.mock-accel\.example\.com/numaNode.intValue,\
PCI:.spec.devices[0].basic.attributes.mock-accel\.example\.com/pciAddress.stringValue

# Dump full YAML for inspection
kubectl get resourceslice <name> -o yaml

# Filter by node
kubectl get resourceslices -l driver=mock-accel.example.com,node=mock-cluster-node1
```

---

### Check Device Status

**Helper Script** (`scripts/check-device-status.sh`):
```bash
#!/bin/bash
# Usage: ./check-device-status.sh <node-ip> [device-name]

NODE_IP=${1:-192.168.122.211}
DEVICE=${2:-}

if [ -z "$DEVICE" ]; then
  # Show all devices
  echo "=== All Devices on $NODE_IP ==="
  sshpass -p "test123" ssh fedora@$NODE_IP "
    for d in /sys/class/mock-accel/*; do
      device=\$(basename \"\$d\")
      status=\$(cat \"\$d/status\")
      numa=\$(cat \"\$d/numa_node\")
      uuid=\$(cat \"\$d/uuid\")
      pci=\$(readlink \"\$d/device\" | xargs basename)
      echo \"Device: \$device\"
      echo \"  Status: \$status (0=free, 1=allocated)\"
      echo \"  UUID:   \$uuid\"
      echo \"  PCI:    \$pci\"
      echo \"  NUMA:   \$numa\"
      echo \"\"
    done
  "
else
  # Show specific device
  echo "=== Device $DEVICE on $NODE_IP ==="
  sshpass -p "test123" ssh fedora@$NODE_IP "
    d=/sys/class/mock-accel/$DEVICE
    if [ ! -d \"\$d\" ]; then
      echo \"ERROR: Device $DEVICE not found\"
      exit 1
    fi
    status=\$(cat \"\$d/status\")
    numa=\$(cat \"\$d/numa_node\")
    uuid=\$(cat \"\$d/uuid\")
    memory=\$(cat \"\$d/memory_size\")
    caps=\$(cat \"\$d/capabilities\")
    pci=\$(readlink \"\$d/device\" | xargs basename)
    echo \"Status:       \$status (0=free, 1=allocated)\"
    echo \"UUID:         \$uuid\"
    echo \"PCI Address:  \$pci\"
    echo \"NUMA Node:    \$numa\"
    echo \"Memory Size:  \$memory bytes\"
    echo \"Capabilities: \$caps\"
  "
fi
```

**Usage**:
```bash
# Check all devices on a node
./scripts/check-device-status.sh 192.168.122.211

# Check specific device
./scripts/check-device-status.sh 192.168.122.211 mock0
```

---

### Monitor CDI Specs

```bash
# List all CDI specs
NODE_IP=192.168.122.211
sshpass -p "test123" ssh fedora@$NODE_IP "ls -lh /var/run/cdi/"

# Watch CDI directory for changes
sshpass -p "test123" ssh fedora@$NODE_IP "watch -n 1 'ls -lh /var/run/cdi/'"

# Inspect CDI spec content
sshpass -p "test123" ssh fedora@$NODE_IP "cat /var/run/cdi/example.com_mock-accel-mock0.json" | jq .

# Verify CDI spec format
sshpass -p "test123" ssh fedora@$NODE_IP "cat /var/run/cdi/example.com_mock-accel-mock0.json" | jq '.cdiVersion, .kind, .devices[0].name'
# Expected:
# "0.8.0"
# "example.com/mock-accel"
# "mock0"
```

---

### Driver Logs Filtering

```bash
# Controller logs
kubectl logs -n mock-device deployment/mock-accel-controller --tail=100

# Filter for errors
kubectl logs -n mock-device deployment/mock-accel-controller --tail=1000 | grep -i error

# Filter for device changes
kubectl logs -n mock-device deployment/mock-accel-controller | grep "Device count changed"

# Node agent logs (specific node)
NODE_AGENT_POD=$(kubectl get pods -n mock-device -l app=mock-accel-node-agent --field-selector spec.nodeName=mock-cluster-node1 -o name | head -1)
kubectl logs -n mock-device $NODE_AGENT_POD --tail=100

# Follow logs in real-time
kubectl logs -n mock-device deployment/mock-accel-controller -f

# Filter for allocation/deallocation events
kubectl logs -n mock-device $NODE_AGENT_POD | grep -E "(PrepareResources|UnprepareResources)"
```

**Log Verbosity Levels**:
- V(2): Important state changes
- V(3): Operational events
- V(4): Detailed operation flow
- V(5): Routine operations (scans, builds)
- V(6): Per-resource details

**Increase verbosity**:
```bash
# Edit deployment and add --v=5 flag
kubectl edit deployment -n mock-device mock-accel-controller

# Or use kubectl patch
kubectl patch deployment -n mock-device mock-accel-controller --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--v=5"}
]'
```

---

## Common Issues

### Issue: Devices Not Discovered

**Symptoms**: `kubectl get resourceslices` shows no mock-accel slices.

**Debug Steps**:

1. **Check controller pod status**:
```bash
kubectl get pods -n mock-device -l app=mock-accel-controller
# Should be Running
```

2. **Check controller logs**:
```bash
kubectl logs -n mock-device deployment/mock-accel-controller --tail=50
# Look for "Discovered N devices" messages
```

3. **Verify kernel module loaded**:
```bash
sshpass -p "test123" ssh fedora@192.168.122.211 "lsmod | grep mock_accel"
# Should show mock_accel module
```

4. **Check sysfs devices exist**:
```bash
sshpass -p "test123" ssh fedora@192.168.122.211 "ls -la /sys/class/mock-accel/"
# Should show mock0, mock1, etc.
```

5. **Verify PCI devices present**:
```bash
sshpass -p "test123" ssh fedora@192.168.122.211 "lspci -nn | grep 1de5"
# Expected: 11:00.0 [1de5:0001], 21:00.0 [1de5:0001], etc.
```

**Resolution**:
- If module not loaded: Check KMM worker pod logs
- If sysfs empty: Restart kernel module: `sudo rmmod mock_accel && sudo modprobe mock_accel`
- If PCI devices missing: Check QEMU is running with vfio-user devices
- If controller pod not running: Check RBAC permissions

---

### Issue: Allocation Fails

**Symptoms**: Pod stuck in Pending, events show allocation error.

**Debug Steps**:

1. **Check pod events**:
```bash
kubectl describe pod <pod-name>
# Look for events related to resource allocation
```

2. **Check ResourceClaim status**:
```bash
kubectl get resourceclaim <claim-name> -o yaml
# Check .status.allocation field
```

3. **Verify node agent running**:
```bash
kubectl get pods -n mock-device -l app=mock-accel-node-agent
# Should have 1 pod per node in Running state
```

4. **Check node agent logs**:
```bash
NODE_AGENT_POD=$(kubectl get pods -n mock-device -l app=mock-accel-node-agent -o name | head -1)
kubectl logs -n mock-device $NODE_AGENT_POD --tail=100
# Look for PrepareResources errors
```

5. **Verify device availability**:
```bash
# Check if devices are already allocated
./scripts/check-device-status.sh 192.168.122.211
# All devices status should be 0 (free)
```

**Common Causes**:
- CEL expression syntax error → Check expression against API reference
- No devices match selector → Verify attribute names and values
- All devices allocated → Check device status, delete unused pods
- Permission denied writing status → Check node agent has root privileges

**Resolution**:
```bash
# Fix CEL expression (example: missing driver prefix)
# ❌ device.attributes["numaNode"].intValue == 0
# ✅ device.attributes["mock-accel.example.com/numaNode"].intValue == 0

# Free allocated devices by deleting pods
kubectl delete pod --all -n <namespace>

# Restart node agent if stuck
kubectl delete pod -n mock-device -l app=mock-accel-node-agent
```

---

### Issue: CDI Specs Not Applied

**Symptoms**: Container has no MOCK_ACCEL_* environment variables or sysfs mounts.

**Debug Steps**:

1. **Verify CDI spec exists**:
```bash
POD_NODE=$(kubectl get pod <pod-name> -o jsonpath='{.spec.nodeName}')
NODE_IP=$(kubectl get node $POD_NODE -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
DEVICE=<device-name>

sshpass -p "test123" ssh fedora@$NODE_IP "ls -la /var/run/cdi/ | grep $DEVICE"
# Should show example.com_mock-accel-<device>.json
```

2. **Inspect CDI spec content**:
```bash
sshpass -p "test123" ssh fedora@$NODE_IP "cat /var/run/cdi/example.com_mock-accel-$DEVICE.json" | jq .
# Verify .devices[0].containerEdits.env contains MOCK_ACCEL_* variables
```

3. **Check container runtime**:
```bash
sshpass -p "test123" ssh fedora@$NODE_IP "sudo k3s crictl info | grep -A5 cdi"
# Verify CDI is enabled
```

4. **Verify crun (not runc)**:
```bash
sshpass -p "test123" ssh fedora@$NODE_IP "sudo k3s crictl info | grep defaultRuntimeName"
# Expected: "defaultRuntimeName": "crun"
```

**Common Causes**:
- CDI spec not generated → Check node agent logs for errors
- Wrong CDI version → Verify spec has `"cdiVersion": "0.8.0"`
- Runtime doesn't support CDI → Ensure containerd 1.7+ with crun
- Spec created after container start → CDI applied at container creation only

**Resolution**:
```bash
# Recreate pod to pick up CDI spec
kubectl delete pod <pod-name>
kubectl apply -f <pod-yaml>

# Verify crun installation
sshpass -p "test123" ssh fedora@$NODE_IP "which crun"
sshpass -p "test123" ssh fedora@$NODE_IP "crun --version"

# Check k3s configuration
sshpass -p "test123" ssh fedora@$NODE_IP "sudo systemctl cat k3s | grep default-runtime"
# Should contain: --default-runtime crun
```

---

## CI/CD Integration

### GitHub Actions Workflow

**File**: `.github/workflows/e2e-test.yml`

```yaml
name: E2E Tests

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  e2e-test:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y qemu-system-x86 sshpass jq bc

    - name: Build vfio-user server
      run: |
        cd libvfio-user
        mkdir -p build && cd build
        cmake -DCMAKE_BUILD_TYPE=Debug ..
        make
        cd ../../vfio-user
        make

    - name: Build kernel module image
      run: |
        cd kernel-driver
        make build-image

    - name: Build DRA driver image
      run: |
        cd dra-driver
        make build-image

    - name: Start NUMA cluster
      run: |
        ./scripts/start-numa-cluster.sh

    - name: Setup k3s cluster
      run: |
        ./scripts/setup-k3s-cluster.sh

    - name: Deploy kernel module
      run: |
        ./scripts/deploy-kmm-module.sh

    - name: Wait for devices
      run: |
        timeout 300 bash -c 'until sshpass -p "test123" ssh -o StrictHostKeyChecking=no fedora@192.168.122.211 "ls /sys/class/mock-accel/ | grep mock0" 2>/dev/null; do sleep 5; done'

    - name: Deploy DRA driver
      run: |
        cd dra-driver
        make load-image
        make deploy

    - name: Wait for ResourceSlices
      run: |
        timeout 300 bash -c 'until kubectl get resourceslices -l driver=mock-accel.example.com 2>/dev/null | grep mock0; do sleep 5; done'

    - name: Run basic allocation test
      run: |
        kubectl apply -f docs/examples/basic-allocation.yaml
        kubectl wait --for=condition=Ready pod/basic-allocation-test --timeout=120s
        kubectl exec basic-allocation-test -- env | grep MOCK_ACCEL_DEVICE
        kubectl delete -f docs/examples/basic-allocation.yaml

    - name: Run NUMA locality test
      run: |
        kubectl apply -f docs/examples/numa-locality.yaml
        kubectl wait --for=condition=Ready pod/numa-locality-test --timeout=120s
        UNIQUE_NUMA=$(kubectl exec numa-locality-test -- sh -c 'cat /sys/class/mock-accel/*/numa_node | sort -u | wc -l')
        if [ "$UNIQUE_NUMA" -ne 1 ]; then
          echo "FAIL: Devices not on same NUMA node"
          exit 1
        fi
        kubectl delete -f docs/examples/numa-locality.yaml

    - name: Run SR-IOV test
      run: |
        NODE_IP=192.168.122.211
        sshpass -p "test123" ssh -o StrictHostKeyChecking=no fedora@$NODE_IP "echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs"
        sleep 10  # Wait for ResourceSlices to update
        kubectl apply -f docs/examples/sriov-vf-allocation.yaml
        kubectl wait --for=condition=Ready pod/sriov-vf-test --timeout=120s
        UNIQUE_PARENTS=$(kubectl exec sriov-vf-test -- sh -c 'readlink /sys/class/mock-accel/*/device/physfn 2>/dev/null | xargs -n1 basename | sort -u | wc -l')
        if [ "$UNIQUE_PARENTS" -ne 1 ]; then
          echo "FAIL: VFs not from same parent"
          exit 1
        fi
        kubectl delete -f docs/examples/sriov-vf-allocation.yaml
        sshpass -p "test123" ssh fedora@$NODE_IP "echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs"

    - name: Collect logs on failure
      if: failure()
      run: |
        kubectl get pods -A
        kubectl get resourceslices
        kubectl logs -n mock-device deployment/mock-accel-controller --tail=200
        kubectl logs -n mock-device daemonset/mock-accel-node-agent --tail=200
        ./scripts/status-cluster.sh

    - name: Cleanup
      if: always()
      run: |
        ./scripts/stop-numa-cluster.sh
```

---

### Test Automation Script

**File**: `scripts/run-all-tests.sh`

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Mock Device E2E Test Suite ==="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
  local test_name="$1"
  local test_cmd="$2"

  echo "Running: $test_name"
  if eval "$test_cmd"; then
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗ FAIL${NC}: $test_name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  echo ""
}

# Test 1: Device Discovery
run_test "Device Discovery" "
  EXPECTED=12
  ACTUAL=\$(kubectl get resourceslices -l driver=mock-accel.example.com --no-headers | wc -l)
  [ \"\$ACTUAL\" -eq \"\$EXPECTED\" ]
"

# Test 2: Basic Allocation
run_test "Basic Allocation" "
  kubectl apply -f $PROJECT_DIR/docs/examples/basic-allocation.yaml >/dev/null 2>&1
  kubectl wait --for=condition=Ready pod/basic-allocation-test --timeout=120s >/dev/null 2>&1
  kubectl exec basic-allocation-test -- env | grep -q MOCK_ACCEL_DEVICE
  RESULT=\$?
  kubectl delete -f $PROJECT_DIR/docs/examples/basic-allocation.yaml >/dev/null 2>&1
  [ \$RESULT -eq 0 ]
"

# Test 3: NUMA Locality
run_test "NUMA Locality" "
  kubectl apply -f $PROJECT_DIR/docs/examples/numa-locality.yaml >/dev/null 2>&1
  kubectl wait --for=condition=Ready pod/numa-locality-test --timeout=120s >/dev/null 2>&1
  UNIQUE_NUMA=\$(kubectl exec numa-locality-test -- sh -c 'cat /sys/class/mock-accel/*/numa_node | sort -u | wc -l')
  kubectl delete -f $PROJECT_DIR/docs/examples/numa-locality.yaml >/dev/null 2>&1
  [ \"\$UNIQUE_NUMA\" -eq 1 ]
"

# Test 4: PCIe Locality
run_test "PCIe Bus Locality" "
  kubectl apply -f $PROJECT_DIR/docs/examples/pcie-locality.yaml >/dev/null 2>&1
  kubectl wait --for=condition=Ready pod/pcie-locality-test --timeout=120s >/dev/null 2>&1
  UNIQUE_BUSES=\$(kubectl exec pcie-locality-test -- sh -c 'readlink /sys/class/mock-accel/*/device | xargs -n1 basename | cut -d: -f2 | sort -u | wc -l')
  kubectl delete -f $PROJECT_DIR/docs/examples/pcie-locality.yaml >/dev/null 2>&1
  [ \"\$UNIQUE_BUSES\" -eq 1 ]
"

# Test 5: SR-IOV VF Allocation
run_test "SR-IOV VF Allocation" "
  NODE_IP=192.168.122.211
  sshpass -p 'test123' ssh -o StrictHostKeyChecking=no fedora@\$NODE_IP 'echo 2 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs' >/dev/null 2>&1
  sleep 10
  kubectl apply -f $PROJECT_DIR/docs/examples/sriov-vf-allocation.yaml >/dev/null 2>&1
  kubectl wait --for=condition=Ready pod/sriov-vf-test --timeout=120s >/dev/null 2>&1
  UNIQUE_PARENTS=\$(kubectl exec sriov-vf-test -- sh -c 'readlink /sys/class/mock-accel/*/device/physfn 2>/dev/null | xargs -n1 basename | sort -u | wc -l')
  kubectl delete -f $PROJECT_DIR/docs/examples/sriov-vf-allocation.yaml >/dev/null 2>&1
  sshpass -p 'test123' ssh fedora@\$NODE_IP 'echo 0 | sudo tee /sys/class/mock-accel/mock0/sriov_numvfs' >/dev/null 2>&1
  [ \"\$UNIQUE_PARENTS\" -eq 1 ]
"

# Summary
echo "=== Test Summary ==="
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
  exit 1
fi

echo "All tests passed!"
```

**Usage**:
```bash
# Make executable
chmod +x scripts/run-all-tests.sh

# Run all tests
./scripts/run-all-tests.sh
```

---

## References

- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [mock-device Integration Guide](integration-guide.md)
- [mock-device API Reference](api-reference.md)
- [mock-device Usage Examples](examples/)
- [mock-device Project README](../README.md)
