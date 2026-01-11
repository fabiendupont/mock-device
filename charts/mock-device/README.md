# mock-device Helm Chart

Kubernetes DRA driver and kernel module for mock PCIe accelerator devices.

## TL;DR

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device --version 0.2.0
```

## Introduction

This chart deploys the mock-device DRA driver for Kubernetes Dynamic Resource Allocation (DRA). It enables testing of DRA drivers with mock PCIe accelerator devices without requiring real hardware.

## Prerequisites

- Kubernetes 1.29+ with DRA API enabled
- Helm 3.14+
- Container runtime with CDI support (containerd 1.7+, crun)
- Kernel Module Manager (KMM) 2.4+ (if using `kernelModule.enabled=true`)

## Installing the Chart

### Standard Installation (DRA driver only)

Assumes kernel module is already installed on nodes:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.2.0 \
  --namespace mock-device --create-namespace
```

### Full Installation (DRA driver + KMM kernel module)

Deploys both DRA driver and kernel module via KMM using pre-built images:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.2.0 \
  --namespace mock-device --create-namespace \
  --set kernelModule.enabled=true \
  --set kernelModule.mode=prebuilt \
  --set kernelModule.prebuilt.image.tag=v0.2.0-fc43
```

### In-Cluster Build Mode

Build kernel module dynamically for any kernel version:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.2.0 \
  --namespace mock-device --create-namespace \
  --set kernelModule.enabled=true \
  --set kernelModule.mode=build
```

This mode compiles the kernel module inside the Kubernetes cluster, automatically adapting to the running kernel version without requiring pre-built images.

### Custom Image Registry

Use images from a private registry:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.2.0 \
  --namespace mock-device --create-namespace \
  --set draDriver.controller.image.repository=myregistry.io/mock-accel-dra-driver \
  --set draDriver.nodeAgent.image.repository=myregistry.io/mock-accel-dra-driver
```

## Uninstalling the Chart

```bash
helm uninstall mock-device -n mock-device
kubectl delete namespace mock-device
```

## Configuration

The following table lists the configurable parameters of the mock-device chart and their default values.

### Global Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.imagePullSecrets` | Image pull secrets for private registries | `[]` |

### Namespace Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace.create` | Create the namespace | `true` |
| `namespace.name` | Namespace name | `mock-device` |

### DRA Driver Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `draDriver.name` | DRA driver name | `mock-accel.example.com` |
| `draDriver.controller.enabled` | Enable controller deployment | `true` |
| `draDriver.controller.image.repository` | Controller image repository | `ghcr.io/fabiendupont/mock-accel-dra-driver` |
| `draDriver.controller.image.tag` | Controller image tag (overrides Chart.appVersion) | `""` |
| `draDriver.controller.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `draDriver.controller.rescanInterval` | Device rescan interval | `30s` |
| `draDriver.controller.verbosity` | Log verbosity (0-10) | `5` |
| `draDriver.controller.resources` | Resource limits/requests | See values.yaml |
| `draDriver.nodeAgent.enabled` | Enable node agent deployment | `true` |
| `draDriver.nodeAgent.image.repository` | Node agent image repository | `ghcr.io/fabiendupont/mock-accel-dra-driver` |
| `draDriver.nodeAgent.image.tag` | Node agent image tag (overrides Chart.appVersion) | `""` |
| `draDriver.nodeAgent.verbosity` | Log verbosity (0-10) | `5` |
| `draDriver.nodeAgent.pluginSocket` | Kubelet plugin socket path | `/var/lib/kubelet/plugins/mock-accel.example.com` |
| `draDriver.nodeAgent.resources` | Resource limits/requests | See values.yaml |

### Kernel Module Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `kernelModule.enabled` | Enable kernel module deployment via KMM | `false` |
| `kernelModule.moduleName` | Kernel module name | `mock-accel` |
| `kernelModule.image.repository` | Module image repository | `ghcr.io/fabiendupont/mock-accel-module` |
| `kernelModule.image.tag` | Module image tag | `v1.0.0-fc43` |
| `kernelModule.kernelMappings` | Kernel version to image mappings | See values.yaml |
| `kernelModule.firmware.enabled` | Enable firmware ConfigMap creation | `true` |
| `kernelModule.firmware.configMapName` | Firmware ConfigMap name | `mock-accel-firmware` |

### Device Classes Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `deviceClasses[0].name` | Physical Functions DeviceClass | `mock-accel-pf` |
| `deviceClasses[0].enabled` | Enable PF DeviceClass | `true` |
| `deviceClasses[1].name` | Virtual Functions DeviceClass | `mock-accel-vf` |
| `deviceClasses[1].enabled` | Enable VF DeviceClass | `true` |

### RBAC Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `rbac.create` | Create RBAC resources | `true` |
| `serviceAccount.create` | Create service accounts | `true` |
| `serviceAccount.annotations` | Annotations for service accounts | `{}` |

## Kernel Module Deployment Modes

The Helm chart supports two modes for deploying the kernel module via KMM:

### Pre-Built Mode (Default)

Uses pre-compiled container images for specific kernel versions:

**Advantages:**
- Fast deployment (no compilation time)
- Predictable, tested images
- Lower cluster resource usage

**Disadvantages:**
- Requires maintaining images for each kernel version
- Cannot automatically support new kernel releases
- Must rebuild and push images when kernel updates

**Configuration:**
```yaml
kernelModule:
  enabled: true
  mode: prebuilt  # Default
  prebuilt:
    image:
      repository: ghcr.io/fabiendupont/mock-accel-module
      tag: v1.0.0-fc43
    kernelMappings:
      - regexp: '^.*\.fc43\.x86_64$'
        containerImage: "ghcr.io/fabiendupont/mock-accel-module:v1.0.0-fc43"
```

### In-Cluster Build Mode

Compiles kernel module dynamically inside the Kubernetes cluster:

**Advantages:**
- Works with any kernel version automatically
- No pre-built image maintenance required
- Always builds for exact running kernel

**Disadvantages:**
- Slower initial deployment (compilation time ~2-5 minutes)
- Requires build tools and resources in cluster
- Uses cluster CPU/memory for compilation

**Configuration:**
```yaml
kernelModule:
  enabled: true
  mode: build
  build:
    dockerfile:
      configMapEnabled: true  # Use embedded Dockerfile
    buildArgs:
      - name: KERNEL_VERSION
        value: ""  # Auto-detect from node
    kernelMappings:
      - regexp: '^.*$'  # Match all kernels
```

**Build Process:**
1. KMM detects node kernel version
2. Creates builder pod with Dockerfile from ConfigMap
3. Compiles mock-accel.ko for detected kernel
4. Caches built image locally (or pushes to registry if configured)
5. Creates worker pod to load the module

### Hybrid Approach

Use pre-built for production, in-cluster build for development/testing:

```bash
# Production with pre-built
helm install mock-device-prod . \
  --set kernelModule.enabled=true \
  --set kernelModule.mode=prebuilt

# Development with in-cluster build
helm install mock-device-dev . \
  --set kernelModule.enabled=true \
  --set kernelModule.mode=build
```

## Examples

### Minimal Installation (DRA driver only)

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.0 \
  --set kernelModule.enabled=false
```

### Full Installation with Custom Verbosity

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.0 \
  --set kernelModule.enabled=true \
  --set draDriver.controller.verbosity=10 \
  --set draDriver.nodeAgent.verbosity=10
```

### Multi-Distro Kernel Module Support

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.0 \
  --set kernelModule.enabled=true \
  --set-json 'kernelModule.kernelMappings=[
    {"regexp":"^.*\\.fc43\\.x86_64$","containerImage":"ghcr.io/fabiendupont/mock-accel-module:v1.0.0-fc43"},
    {"regexp":"^.*\\.fc44\\.x86_64$","containerImage":"ghcr.io/fabiendupont/mock-accel-module:v1.0.0-fc44"}
  ]'
```

## Verification

After installation, verify the deployment:

```bash
# Check DaemonSets
kubectl get daemonset -n mock-device

# Check ResourceSlices
kubectl get resourceslices -l driver=mock-accel.example.com

# Check DeviceClasses
kubectl get deviceclass | grep mock-accel

# Check pods
kubectl get pods -n mock-device
```

## Testing Device Allocation

Create a test ResourceClaim:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: test-claim
  namespace: default
spec:
  devices:
    requests:
    - name: accel
      deviceClassName: mock-accel-pf
      count: 1
EOF
```

Create a test pod using the claim:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: default
spec:
  resourceClaims:
  - name: accel
    resourceClaimName: test-claim
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "env | grep MOCK_ACCEL && sleep 3600"]
    resources:
      claims:
      - name: accel
EOF
```

Verify device was allocated:

```bash
kubectl exec test-pod -- env | grep MOCK_ACCEL
# Expected output:
# MOCK_ACCEL_UUID=...
# MOCK_ACCEL_PCI=...
# MOCK_ACCEL_DEVICE=...
```

## Character Device Interface

The mock-accel kernel driver creates `/dev/mockN` character devices for each PCIe device, providing standard Linux device node access:

**File Operations:**
- `read()` - Returns device information and sample passphrase
- `ioctl(MOCK_ACCEL_IOC_STATUS)` - Read device status register
- `ioctl(MOCK_ACCEL_IOC_PASSPHRASE)` - Generate cryptographic passphrase (1-12 words)

**Example Usage:**

```bash
# SSH into a node
kubectl debug node/<node-name> -it --image=busybox

# Read device information
cat /dev/mock0
# Mock Accelerator Device
# UUID: ...
# Memory: 17179869184 bytes
# Status: 0x00000001
# NUMA Node: 0
# Wordlist: 7776 words loaded
# Sample Passphrase (6 words): countdown-gigabyte-headway-armchair-untouched-raft

# Check permissions
ls -l /dev/mock*
# crw-------. 1 root root 239, 0 Jan 10 20:27 /dev/mock0
```

**Passphrase Generation:**

The driver provides an ioctl interface for generating cryptographically secure passphrases using the EFF long wordlist (7,776 words). See the [firmware README](https://github.com/fabiendupont/mock-device/blob/main/firmware/README.md) for details.

## Firmware Management

The kernel module loads the EFF long wordlist (7,776 words) as firmware during initialization for passphrase generation.

**Firmware Deployment:**

When using KMM (`kernelModule.enabled=true`), firmware is **embedded in the container image**:

```dockerfile
# Containerfile
COPY charts/mock-device/firmware/mock-accel-wordlist.txt /lib/firmware/
```

No additional configuration is required. The firmware is automatically available when the module loads.

**Firmware ConfigMap:**

The Helm chart creates a ConfigMap containing the firmware for documentation purposes:

```bash
kubectl get configmap mock-accel-firmware -n mock-device
```

This ConfigMap is **NOT mounted** by KMM (firmware comes from the container image). It can be used for:
- Documentation and reference
- Custom deployment scenarios
- Debugging firmware content

**Verify Firmware:**

```bash
# Check container image includes firmware
kubectl run test --rm -it --image=ghcr.io/fabiendupont/mock-accel-module:v1.0.0-fc43 \
  -- ls -lh /lib/firmware/mock-accel-wordlist.txt
# -rw-r--r--. 1 root root 61K ... /lib/firmware/mock-accel-wordlist.txt

# Check kernel logs on node
kubectl debug node/<node-name> -it --image=busybox
dmesg | grep firmware
# mock-accel 0000:11:00.0: Loaded 7776 words from firmware
```

**Manual Firmware Installation:**

If loading the module manually (without KMM), copy firmware to `/lib/firmware/`:

```bash
# On each node
sudo cp /path/to/mock-accel-wordlist.txt /lib/firmware/
sudo insmod /path/to/mock-accel.ko
```

See the [firmware README](https://github.com/fabiendupont/mock-device/blob/main/firmware/README.md) for firmware download and detailed information.

## Troubleshooting

### Devices Not Discovered

Check if kernel module is loaded:

```bash
# On each node
lsmod | grep mock_accel
```

If not loaded and KMM is enabled, check KMM worker pods:

```bash
kubectl get pods -n mock-device -l kmm.node.kubernetes.io/module.name=mock-accel
kubectl logs -n mock-device <kmm-worker-pod>
```

### ResourceSlices Not Published

Check controller logs:

```bash
kubectl logs -n mock-device -l app=mock-accel-controller
```

### Pod Fails to Get Device

Check node agent logs:

```bash
kubectl logs -n mock-device -l app=mock-accel-node-agent
```

Verify sysfs devices exist:

```bash
# On node
ls /sys/class/mock-accel/
```

### Firmware Loading Failed

Check kernel logs for firmware errors:

```bash
# On node
dmesg | grep -i firmware
# Expected: "mock-accel 0000:11:00.0: Loaded 7776 words from firmware"
# Error: "mock-accel 0000:11:00.0: Failed to load wordlist firmware: -2"
```

If firmware loading fails (-2 = ENOENT):

**For KMM deployments:**
1. Verify firmware is in the container image:
   ```bash
   kubectl run test --rm -it --image=ghcr.io/fabiendupont/mock-accel-module:v1.0.0-fc43 \
     -- ls -lh /lib/firmware/mock-accel-wordlist.txt
   ```

2. Check KMM worker pod logs:
   ```bash
   kubectl logs -n mock-device -l kmm.node.kubernetes.io/module.name=mock-accel
   ```

**For manual deployments:**
1. Copy firmware to `/lib/firmware/` on each node:
   ```bash
   sudo cp firmware/mock-accel-wordlist.txt /lib/firmware/
   ```

2. Reload module:
   ```bash
   sudo rmmod mock_accel
   sudo insmod mock_accel.ko
   ```

**Note:** The module continues to work without firmware, but passphrase generation will be disabled.

### Character Devices Not Created

Check if character devices exist:

```bash
# On node
ls -l /dev/mock*
# Expected: crw-------. 1 root root 239, X ... /dev/mockX
```

If missing:

1. Check module loaded successfully:
   ```bash
   lsmod | grep mock_accel
   dmesg | grep mock-accel
   ```

2. Verify PCI devices detected:
   ```bash
   lspci -nn | grep 1de5
   ls /sys/class/mock-accel/
   ```

3. Check major number allocation:
   ```bash
   cat /proc/devices | grep mock
   # Expected: 239 mock-accel
   ```

## More Information

- [Project Repository](https://github.com/fabiendupont/mock-device)
- [Integration Guide](https://github.com/fabiendupont/mock-device/blob/main/docs/integration-guide.md)
- [Testing Guide](https://github.com/fabiendupont/mock-device/blob/main/docs/testing-guide.md)
- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
