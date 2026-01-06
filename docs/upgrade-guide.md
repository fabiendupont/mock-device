# Mock Device Upgrade Guide

## Overview

This guide provides instructions for upgrading mock-device components between versions.

---

## Upgrade Strategy

### Semantic Versioning

Mock-device follows [Semantic Versioning](https://semver.org/):
- **MAJOR** version: Breaking changes, incompatible API changes
- **MINOR** version: New features, backward-compatible
- **PATCH** version: Bug fixes, backward-compatible

### Unified Versioning

All components (DRA driver, kernel module, vfio-user server) share the same version number. When upgrading, upgrade all components together.

---

## Upgrade Procedures

### Helm Chart Upgrades

#### Patch Version Upgrade (e.g., 0.1.0 → 1.0.1)

Patch upgrades are safe and can be done without downtime:

```bash
# Update to new patch version
helm upgrade mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.1 \
  --namespace mock-device \
  --reuse-values
```

#### Minor Version Upgrade (e.g., 0.1.0 → 1.1.0)

Minor upgrades add features but maintain backward compatibility:

```bash
# Review release notes for new features
# Check if any new configuration options are available

# Upgrade with existing values
helm upgrade mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.1.0 \
  --namespace mock-device \
  --reuse-values

# Or provide new values file
helm upgrade mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.1.0 \
  --namespace mock-device \
  --values my-values.yaml
```

#### Major Version Upgrade (e.g., 1.x.x → 2.0.0)

Major upgrades may contain breaking changes. Follow migration guide for specific version.

```bash
# IMPORTANT: Review migration guide first
# Check: docs/release-notes/v2.0.0.md

# Backup current configuration
helm get values mock-device -n mock-device > backup-values.yaml

# Uninstall old version (if migration guide requires)
helm uninstall mock-device -n mock-device

# Install new version
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 2.0.0 \
  --namespace mock-device \
  --values migrated-values.yaml
```

---

### Manual Deployment Upgrades

#### Update Container Images

1. **Update DRA driver image tags**:

   Edit `dra-driver/deployments/controller.yaml` and `node-agent.yaml`:
   ```yaml
   image: ghcr.io/fabiendupont/mock-accel-dra-driver:v1.0.1
   ```

2. **Update kernel module image**:

   Edit `kmm/module.yaml`:
   ```yaml
   containerImage: "ghcr.io/fabiendupont/mock-accel-module:v1.0.1-fc43"
   ```

3. **Apply updates**:
   ```bash
   kubectl apply -f dra-driver/deployments/controller.yaml
   kubectl apply -f dra-driver/deployments/node-agent.yaml
   kubectl apply -f kmm/module.yaml
   ```

4. **Verify rollout**:
   ```bash
   kubectl rollout status daemonset/mock-device-controller -n mock-device
   kubectl rollout status daemonset/mock-device-node-agent -n mock-device
   ```

---

### Kernel Module Upgrades

Kernel module upgrades are managed automatically by KMM when using Helm charts.

#### Manual Kernel Module Upgrade

If not using KMM:

1. **Unload old module**:
   ```bash
   # On each node
   sudo rmmod mock_accel
   ```

2. **Install new module**:
   ```bash
   # Build or download new module
   sudo insmod mock-accel.ko
   ```

3. **Verify**:
   ```bash
   lsmod | grep mock_accel
   modinfo mock_accel | grep version
   ```

---

## Rollback Procedures

### Helm Rollback

If an upgrade causes issues, rollback to previous version:

```bash
# List release history
helm history mock-device -n mock-device

# Rollback to previous revision
helm rollback mock-device -n mock-device

# Or rollback to specific revision
helm rollback mock-device 3 -n mock-device
```

### Manual Rollback

1. **Revert to old image tags**
2. **Apply old manifests**
3. **Verify pods are running old version**:
   ```bash
   kubectl get pods -n mock-device -o jsonpath='{.items[*].spec.containers[*].image}'
   ```

---

## Version Compatibility Matrix

See [Compatibility Guide](compatibility.md) for detailed compatibility information.

---

## Pre-Upgrade Checklist

Before upgrading, verify:

- [ ] Read release notes for target version
- [ ] Check compatibility matrix for Kubernetes version
- [ ] Backup Helm values: `helm get values mock-device -n mock-device > backup.yaml`
- [ ] No active workloads using devices (or plan for brief downtime)
- [ ] KMM operator compatible (if using kernel module deployment)
- [ ] Test upgrade in non-production environment first (recommended)

---

## Post-Upgrade Verification

After upgrading, verify:

```bash
# Check pod versions
kubectl get pods -n mock-device -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'

# Check ResourceSlices
kubectl get resourceslices -l driver=mock-accel.example.com

# Check controller logs for errors
kubectl logs -n mock-device -l app=mock-accel-controller --tail=50

# Check node agent logs
kubectl logs -n mock-device -l app=mock-accel-node-agent --tail=50

# Test device allocation with test pod
kubectl apply -f docs/examples/basic-allocation.yaml
kubectl wait --for=condition=Ready pod/basic-allocation-test --timeout=60s
kubectl delete -f docs/examples/basic-allocation.yaml
```

---

## Breaking Changes

### v0.1.0 → v0.2.0 (Hypothetical Example)

**Breaking Changes**: None (backward compatible)

**New Features**:
- New DeviceClass for NUMA-aware allocation
- Additional device attributes for power consumption

**Migration Steps**:
1. Standard Helm upgrade (no manual steps required)
2. Optionally enable new DeviceClasses in values.yaml

---

## Deprecated Features

### Current Deprecations

No features are currently deprecated in v0.1.0.

### Deprecation Policy

- Features are deprecated at least one MINOR version before removal
- Deprecation warnings appear in release notes and logs
- Deprecated features are supported for at least 6 months
- Major version bumps may remove deprecated features

---

## Support Lifecycle

| Version | Release Date | End of Support | Notes |
|---------|--------------|----------------|-------|
| 0.1.x   | 2026-01-06   | TBD            | Current alpha |

**Support policy**:
- Latest MAJOR.MINOR version: Full support
- Previous MINOR version (N-1): Security fixes for 6 months
- Older versions: Best-effort community support

---

## Upgrade FAQs

### Q: Can I upgrade DRA driver without upgrading kernel module?

**A**: Not recommended. All components share the same version and should be upgraded together for compatibility.

### Q: Will upgrading cause downtime for running workloads?

**A**:
- **DRA driver**: DaemonSet rolling update causes brief disruption (pods restarted one node at a time)
- **Kernel module**: May require node drain and module reload (brief downtime)
- **Running pods with devices**: Not affected during upgrade, but new allocations may be paused briefly

### Q: How do I upgrade if I use a private registry?

**A**: Pull new images to your registry, then update Helm values:
```bash
helm upgrade mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.1 \
  --set draDriver.controller.image.repository=myregistry.io/mock-accel-dra-driver \
  --set draDriver.controller.image.tag=v1.0.1
```

### Q: Can I skip versions (e.g., 0.1.0 → 1.2.0)?

**A**: Yes for MINOR and PATCH versions. For MAJOR versions, review migration guide for any multi-version upgrade considerations.

---

## Troubleshooting Upgrades

### Issue: Pods Stuck in Pending After Upgrade

**Cause**: ResourceSlices not published by new controller version

**Resolution**:
```bash
# Check controller logs
kubectl logs -n mock-device -l app=mock-accel-controller

# Restart controller pods
kubectl rollout restart daemonset/mock-device-controller -n mock-device
```

### Issue: Kernel Module Not Loading After Upgrade

**Cause**: KMM using old image or kernel version mismatch

**Resolution**:
```bash
# Check Module status
kubectl get module -n mock-device -o yaml

# Verify kernel mappings match node kernel version
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kernelVersion}'

# Update kernel mappings if needed
helm upgrade mock-device ... --set kernelModule.kernelMappings[0].regexp='^.*\.fc44\.x86_64$'
```

---

## Next Steps

- [Installation Guide](installation-guide.md) - Fresh installation instructions
- [Compatibility Guide](compatibility.md) - Version compatibility matrix
- [Release Notes](release-notes/) - Detailed changelog for each version

---

## Support

For upgrade issues:
- **GitHub Issues**: https://github.com/fabiendupont/mock-device/issues
- **Release Notes**: https://github.com/fabiendupont/mock-device/releases
