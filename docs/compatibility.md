# Mock Device Compatibility Guide

## Overview

This guide provides compatibility information for mock-device components across different Kubernetes versions, kernel versions, and runtime environments.

---

## Component Version Compatibility

All mock-device components share the same version number and **must be deployed together**.

| Mock Device Version | DRA Driver | Kernel Module | vfio-user Server | Helm Chart |
|---------------------|------------|---------------|------------------|------------|
| 0.1.x               | v0.1.x     | v0.1.x        | v0.1.x           | 0.1.x      |

**Important**: Do not mix versions across components. Always upgrade all components together using the same release version.

---

## Kubernetes Compatibility

### Kubernetes Version Requirements

| Mock Device Version | Min Kubernetes | Max Kubernetes | DRA API Version | Notes |
|---------------------|----------------|----------------|-----------------|-------|
| 0.1.x               | 1.29.0         | 1.32.x         | v1alpha3        | DRA feature gate required |

### Feature Gates

Mock-device requires the following Kubernetes feature gates:

```yaml
# Kubernetes 1.29+
DynamicResourceAllocation: true  # Enabled by default in 1.29+
```

### API Group Compatibility

| Mock Device Version | resource.k8s.io API | deviceclass API | Notes |
|---------------------|---------------------|-----------------|-------|
| 0.1.x               | v1alpha3            | v1              | Stable DeviceClass API |

---

## Container Runtime Compatibility

### Supported Runtimes

| Runtime    | Min Version | CDI Support | Notes |
|------------|-------------|-------------|-------|
| containerd | 1.7.0       | ✅ Yes      | **Recommended** |
| CRI-O      | 1.28.0      | ✅ Yes      | Supported |
| Docker     | Not supported | ❌ No    | No CDI support |

### Default Runtime Requirements

**CRITICAL**: Mock-device requires **crun** as the default container runtime (not runc).

| Runtime Binary | Min Version | finit_module Support | KMM Compatible |
|----------------|-------------|----------------------|----------------|
| crun           | 1.8.0       | ✅ Yes               | ✅ Yes         |
| runc           | Any         | ❌ No (blocked by seccomp) | ❌ No     |

**Why crun is required:**
- KMM worker pods need the `finit_module` syscall to load kernel modules
- runc blocks `finit_module` via seccomp even with SYS_MODULE capability
- crun allows `finit_module` with just SYS_MODULE capability

**Configuration:**
```bash
# k3s with crun (recommended)
curl -sfL https://get.k3s.io | sh -s - --default-runtime crun

# Verify
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'
# Expected: containerd://1.7.x-crun
```

---

## Kernel Compatibility

### Kernel Version Requirements

| Mock Device Version | Min Kernel | Tested Kernels | Architecture |
|---------------------|------------|----------------|--------------|
| 0.1.x               | 6.11.0     | 6.11.x (Fedora 43) | x86_64, aarch64 |

### Kernel Module Images

Pre-built kernel module images are available for specific distributions:

| Image Tag              | Kernel Version       | Distribution | Architecture |
|------------------------|----------------------|--------------|--------------|
| v0.1.0-fc43            | 6.11.0-300.fc43.x86_64 | Fedora 43    | x86_64       |

**Custom Kernel Support:**

To build for a custom kernel:

```dockerfile
# Build your own kernel module image
FROM registry.fedoraproject.org/fedora:43
RUN dnf install -y kernel-devel-$(uname -r) gcc make
COPY kernel-driver/ /build/
RUN cd /build && make
```

Update Helm values:

```yaml
kernelModule:
  kernelMappings:
    - regexp: '^6\.12\..*\.fc44\.x86_64$'
      containerImage: "myregistry.io/mock-accel-module:v0.1.0-fc44"
```

---

## Kernel Module Manager (KMM) Compatibility

### KMM Operator Version

| Mock Device Version | Min KMM Version | Max KMM Version | Notes |
|---------------------|-----------------|-----------------|-------|
| 0.1.x               | 2.4.0           | 2.x.x           | cert-manager required |

### cert-manager Requirements

KMM requires cert-manager:

| Component      | Min Version | Installation |
|----------------|-------------|--------------|
| cert-manager   | 1.16.0      | `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml` |

---

## Operating System Compatibility

### SELinux Requirements

| OS Feature | Required State | Notes |
|------------|----------------|-------|
| SELinux    | Permissive     | Enforcing mode blocks KMM module loading |

**Configuration:**

```bash
# Set SELinux to permissive (required for KMM)
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

### Tested Distributions

| Distribution       | Version | Kernel         | Status |
|-------------------|---------|----------------|--------|
| Fedora            | 43      | 6.11.0         | ✅ Fully tested |
| RHEL              | 9.x     | 5.14.x         | ⚠️ Untested (kernel too old) |
| Ubuntu            | 24.04   | 6.8.x          | ⚠️ Untested (kernel too old) |

---

## Consumer Compatibility

### k8s-dra-driver-nodepartition Integration

Mock-device is designed to integrate with meta-DRA drivers like k8s-dra-driver-nodepartition:

| Mock Device Version | Node Partition DRA Version | Compatibility |
|---------------------|----------------------------|---------------|
| 0.1.x               | All versions               | ✅ Fully compatible |

**Integration Requirements:**
- Mock-device publishes standard ResourceSlices with topology attributes
- Meta-driver reads ResourceSlices and parses `pool.name` for NUMA topology
- No version-specific dependencies

**ResourceSlice Schema Compatibility:**

```yaml
apiVersion: resource.k8s.io/v1alpha3
kind: ResourceSlice
spec:
  nodeName: <node>
  pool:
    name: numa0  # NUMA node grouping (required for meta-driver)
  driver: mock-accel.example.com
  devices:
    - name: mock0
      basic:
        attributes:
          uuid: {stringValue: "..."}
          memory: {intValue: 17179869184}
          deviceType: {stringValue: "pf"}
          pciAddress: {stringValue: "..."}
          numa_node: {intValue: 0}  # Topology info
```

Meta-drivers expect:
- ✅ `pool.name` with NUMA node identifier
- ✅ `basic.attributes` with standard device properties
- ✅ Topology attributes (numa_node, pciAddress)

---

## Helm Chart Compatibility

### Helm Version Requirements

| Mock Device Version | Min Helm Version | Max Helm Version | Notes |
|---------------------|------------------|------------------|-------|
| 0.1.x               | 3.14.0           | 3.x.x            | OCI registry support required |

### Helm Chart API Version

| Chart Version | Helm API Version | Kubernetes API Compatibility |
|---------------|------------------|------------------------------|
| 0.1.x         | v2               | 1.29+ (resource.k8s.io/v1alpha3) |

---

## Networking Requirements

### Required Ports

| Component      | Port  | Protocol | Purpose |
|----------------|-------|----------|---------|
| kubelet        | 10250 | TCP      | Node Agent gRPC plugin |
| API Server     | 6443  | TCP      | Controller API access |

### Network Policies

Mock-device does not require specific network policies. All communication is node-local (kubelet ↔ Node Agent).

---

## Storage Requirements

### Node Storage Paths

| Path                                      | Required | Purpose |
|-------------------------------------------|----------|---------|
| `/sys/class/mock-accel/`                  | ✅ Yes   | Device sysfs (kernel module) |
| `/var/lib/kubelet/plugins/mock-accel.example.com/` | ✅ Yes | Kubelet plugin socket |
| `/var/run/cdi/`                           | ✅ Yes   | CDI spec files |

### Persistent Storage

Mock-device does **not** require persistent storage. All state is ephemeral (sysfs-based).

---

## Upgrade Paths

### Supported Upgrade Paths

| From Version | To Version | Direct Upgrade | Notes |
|--------------|------------|----------------|-------|
| 0.1.0        | 0.1.x      | ✅ Yes         | Patch upgrades (backward compatible) |
| 0.1.x        | 1.1.0      | ✅ Yes         | Minor upgrades (backward compatible) |
| 1.x.x        | 2.0.0      | ⚠️ Check migration guide | Major upgrades (breaking changes possible) |

See [Upgrade Guide](upgrade-guide.md) for detailed procedures.

---

## Known Limitations

### Current Limitations (v0.1.x)

1. **Kernel Module**:
   - Pre-built images only for Fedora 43 (6.11.x kernels)
   - Custom kernel builds required for other distributions

2. **Architecture Support**:
   - DRA driver: amd64, arm64
   - Kernel module: amd64 only (pre-built images)
   - vfio-user server: amd64 only (C code, buildable for arm64)

3. **Runtime Requirements**:
   - crun runtime mandatory (runc not supported)
   - SELinux must be permissive (enforcing mode not supported)

4. **Device Limits**:
   - Maximum devices per node: Limited by sysfs (tested up to 32 devices)
   - Maximum VFs per PF: 16 (configured in vfio-user server)

---

## Deprecation Notices

### v0.1.0

No features are currently deprecated.

### Future Deprecations

- **DRA API v1alpha3**: Kubernetes will promote DRA to v1beta1 in 1.32+
  - Mock-device will add v1beta1 support in v1.1.0
  - v1alpha3 support will be deprecated in v2.0.0

---

## Version Support Policy

| Version Type | Support Duration | Updates Provided |
|--------------|------------------|------------------|
| Latest MAJOR.MINOR | Indefinite | Full support (features + bug fixes) |
| Previous MINOR (N-1) | 6 months | Security fixes only |
| Older versions | Best-effort | Community support only |

**Example:**
- v0.2.0 released → v0.2.x fully supported
- v0.1.x receives security fixes for 6 months
- v0.0.x community support only

---

## Compatibility Matrix Summary

### Quick Reference

| Component | Minimum Version | Recommended Version |
|-----------|-----------------|---------------------|
| Kubernetes | 1.29.0 | 1.31.x |
| containerd | 1.7.0 | 1.7.x |
| crun | 1.8.0 | Latest |
| Kernel | 6.11.0 | 6.11.x (Fedora 43) |
| KMM Operator | 2.4.0 | 2.4.x |
| cert-manager | 1.16.0 | 1.16.x |
| Helm | 3.14.0 | 3.15.x |

---

## Testing Compatibility

Before deploying to production, verify compatibility:

```bash
# Check Kubernetes version
kubectl version --short
# Client: v1.31.x
# Server: v1.31.x

# Check container runtime
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'
# Expected: containerd://1.7.x-crun

# Check kernel version (SSH to nodes)
ssh node1 uname -r
# Expected: 6.11.0-300.fc43.x86_64

# Check SELinux mode
ssh node1 getenforce
# Expected: Permissive

# Check KMM operator
kubectl get pods -n kmm-operator-system
# Expected: All Running

# Check cert-manager
kubectl get pods -n cert-manager
# Expected: All Running
```

---

## Compatibility Issues and Resolutions

### Issue: runc Runtime Blocks Module Loading

**Symptoms**: KMM worker pods fail with "Operation not permitted" when calling `finit_module`.

**Resolution**:
```bash
# Reconfigure k3s with crun
curl -sfL https://get.k3s.io | sh -s - --default-runtime crun
```

### Issue: SELinux Enforcing Blocks Module Loading

**Symptoms**: KMM worker pods fail with SELinux AVC denial logs.

**Resolution**:
```bash
# Set SELinux to permissive
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

### Issue: Kernel Version Mismatch

**Symptoms**: KMM Module shows "NoMatchingKernelMapping" status.

**Resolution**:
```bash
# Check node kernel version
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kernelVersion}'

# Update Helm values with correct kernel mapping
helm upgrade mock-device ... \
  --set kernelModule.kernelMappings[0].regexp='^6\.12\..*\.fc44\.x86_64$' \
  --set kernelModule.kernelMappings[0].containerImage='...:v0.1.0-fc44'
```

---

## Next Steps

- [Installation Guide](installation-guide.md) - Install mock-device
- [Upgrade Guide](upgrade-guide.md) - Upgrade between versions
- [API Reference](api-reference.md) - ResourceSlice schema and sysfs interface

---

## Support

For compatibility questions:
- **GitHub Issues**: https://github.com/fabiendupont/mock-device/issues
- **Documentation**: https://github.com/fabiendupont/mock-device/blob/main/docs/
