# mock-device Helm Chart

Kubernetes DRA driver and kernel module for mock PCIe accelerator devices.

## TL;DR

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device --version 1.0.0
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
  --version 1.0.0 \
  --namespace mock-device --create-namespace
```

### Full Installation (DRA driver + KMM kernel module)

Deploys both DRA driver and kernel module via KMM:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.0 \
  --namespace mock-device --create-namespace \
  --set kernelModule.enabled=true \
  --set kernelModule.image.tag=v1.0.0-fc43
```

### Custom Image Registry

Use images from a private registry:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 1.0.0 \
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

## More Information

- [Project Repository](https://github.com/fabiendupont/mock-device)
- [Integration Guide](https://github.com/fabiendupont/mock-device/blob/main/docs/integration-guide.md)
- [Testing Guide](https://github.com/fabiendupont/mock-device/blob/main/docs/testing-guide.md)
- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
