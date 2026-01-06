# DRA Driver Testing

This directory contains tests for the mock-accel DRA driver.

## Unit Tests

Unit tests are located alongside the source code in `pkg/` subdirectories:

- **pkg/discovery/scanner_test.go**: Device discovery tests with mock sysfs
- **pkg/controller/resourceslice_test.go**: ResourceSlice builder tests
- **pkg/nodeagent/allocator_test.go**: Sysfs allocator tests
- **pkg/nodeagent/cdi_test.go**: CDI spec generation tests

### Running Unit Tests

```bash
# Run all unit tests
make test

# Run tests with verbose output
go test -v ./pkg/...

# Run tests with coverage
go test -cover ./pkg/...

# Run specific package tests
go test ./pkg/discovery/
go test ./pkg/controller/
go test ./pkg/nodeagent/
```

### Test Coverage

Each test package creates isolated mock environments:

**scanner_test.go**:
- Creates temporary sysfs directory structure
- Writes mock device attributes (uuid, memory_size, capabilities)
- Creates mock PCI device symlinks with numa_node
- Validates device discovery, PF/VF detection, and attribute parsing

**resourceslice_test.go**:
- Tests NUMA grouping logic
- Validates ResourceSlice structure and metadata
- Verifies device attributes (uuid, memory, deviceType, pciAddress, physfn)
- Checks capacity reporting

**allocator_test.go**:
- Creates mock status files in temporary sysfs
- Tests Allocate() writes "1" to status register
- Tests Deallocate() writes "0" to status register
- Tests GetStatus() reads current allocation state
- Validates error handling for nonexistent devices

**cdi_test.go**:
- Tests CDI spec JSON generation
- Validates environment variables (MOCK_ACCEL_UUID, MOCK_ACCEL_PCI, MOCK_ACCEL_DEVICE)
- Verifies sysfs mount with read-only option
- Tests spec file creation at correct path
- Tests RemoveSpec() cleanup

## Integration Tests

### E2E Test Manifests

The `e2e-test.yaml` file contains complete end-to-end test scenarios:

1. **Physical Function Test** (`test-mock-accel-pf`)
   - Requests 1 PF device via `mock-accel-pf` DeviceClass
   - Validates environment variables are set
   - Verifies sysfs device directory is mounted
   - Reads and validates device attributes

2. **Virtual Function Test** (`test-mock-accel-vf`)
   - Requests 1 VF device via `mock-accel-vf` DeviceClass
   - Validates VF-specific device access

3. **Memory-Filtered VF Test** (`test-mock-accel-vf-2gb`)
   - Requests VF with at least 2GB memory
   - Validates memory_size attribute meets requirement
   - Tests CEL expression filtering

### Running E2E Tests

**Prerequisites:**
1. k3s cluster with crun runtime (see `../scripts/setup-k3s-cluster.sh`)
2. mock-accel kernel module loaded via KMM (see `../scripts/deploy-kmm-module.sh`)
3. DRA driver deployed (see `../deployments/`)

**Deploy tests:**

```bash
# Apply all test resources
kubectl apply -f test/e2e-test.yaml

# Check ResourceClaim status
kubectl get resourceclaims
kubectl describe resourceclaim test-pf-claim

# Check pod status
kubectl get pods
kubectl describe pod test-mock-accel-pf

# View test output
kubectl logs test-mock-accel-pf

# Cleanup
kubectl delete -f test/e2e-test.yaml
```

### Manual Verification Steps

**1. Verify ResourceSlices Published:**
```bash
kubectl get resourceslices
kubectl describe resourceslice mock-accel.example.com-mock-cluster-node1-numa0
```

Expected output should show:
- Driver: `mock-accel.example.com`
- Pool name: `numa0` or `numa1`
- Devices with attributes: uuid, memory, deviceType, pciAddress, capabilities

**2. Verify Device Allocation on Node:**
```bash
# SSH into node
ssh fedora@<node-ip>

# Check status register (should be "1" when allocated)
cat /sys/class/mock-accel/mock0/status

# Check CDI spec file exists
ls -la /var/run/cdi/
cat /var/run/cdi/mock-accel_example_com-mock0.json
```

**3. Verify Container Device Access:**
```bash
# Check environment variables
kubectl exec test-mock-accel-pf -- env | grep MOCK_ACCEL

# Check sysfs mount
kubectl exec test-mock-accel-pf -- ls -la /sys/class/mock-accel/

# Read device attributes from within pod
kubectl exec test-mock-accel-pf -- cat /sys/class/mock-accel/mock0/uuid
```

**4. Verify Deallocation:**
```bash
# Delete the pod
kubectl delete pod test-mock-accel-pf

# Check status register is reset (should be "0")
ssh fedora@<node-ip> cat /sys/class/mock-accel/mock0/status

# Check CDI spec removed
ssh fedora@<node-ip> ls /var/run/cdi/
```

## Troubleshooting Tests

### Unit Tests Fail

```bash
# Run with verbose output to see failure details
go test -v ./pkg/...

# Check for missing dependencies
go mod tidy
go mod verify

# Verify Go version
go version  # Should be 1.23+
```

### E2E Test Pod Pending

```bash
# Check ResourceClaim events
kubectl describe resourceclaim test-pf-claim

# Check for available devices in ResourceSlices
kubectl get resourceslices -o yaml

# Verify DRA driver pods are running
kubectl get pods -n mock-device
kubectl logs -n mock-device -l app=mock-accel-node-agent
```

### E2E Test Pod ContainerCreating

```bash
# Check pod events
kubectl describe pod test-mock-accel-pf

# Look for CDI-related errors
kubectl logs -n kube-system -l component=kubelet

# Verify CDI spec was created
ssh fedora@<node-ip> "sudo cat /var/run/cdi/*.json"
```

### E2E Test Fails Inside Container

```bash
# Get detailed logs
kubectl logs test-mock-accel-pf

# Check environment variables
kubectl exec test-mock-accel-pf -- env

# Check if sysfs is mounted
kubectl exec test-mock-accel-pf -- mount | grep mock-accel

# Interactive debugging
kubectl exec -it test-mock-accel-pf -- sh
```

## Test Maintenance

### Adding New Unit Tests

1. Create `*_test.go` file in the same directory as the code
2. Use `t.TempDir()` for isolated test environments
3. Follow existing test patterns (setupMockSysfs, etc.)
4. Verify all edge cases and error conditions

### Adding New E2E Tests

1. Create new ResourceClaim with appropriate DeviceClass
2. Create Pod with resourceClaims reference
3. Add validation logic in container command
4. Document expected behavior in comments

### CI/CD Integration

The unit tests can be integrated into CI pipelines:

```yaml
# Example GitHub Actions workflow
- name: Run Tests
  run: |
    cd dra-driver
    go test -v -race -coverprofile=coverage.out ./pkg/...
    go tool cover -html=coverage.out -o coverage.html
```

## Test Matrix

| Test Type | Component | Coverage | Runtime |
|-----------|-----------|----------|---------|
| Unit | Device Scanner | Full | <1s |
| Unit | ResourceSlice Builder | Full | <1s |
| Unit | Sysfs Allocator | Full | <1s |
| Unit | CDI Generator | Full | <1s |
| E2E | PF Allocation | Full flow | ~30s |
| E2E | VF Allocation | Full flow | ~30s |
| E2E | Memory Filtering | Full flow | ~30s |

## References

- [Kubernetes DRA Testing Guide](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [Go Testing Package](https://pkg.go.dev/testing)
- [CDI Specification](https://github.com/cncf-tags/container-device-interface)
