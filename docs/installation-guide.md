# Mock Device Installation Guide

## Overview

This guide provides step-by-step instructions for installing mock-device components for Kubernetes DRA testing.

## Prerequisites

### Required
- **Kubernetes**: 1.29+ with DRA API enabled
- **Container Runtime**: containerd 1.7+ with CDI support
  - **crun**: Required as default runtime (not runc) for KMM module loading
- **Helm**: 3.14+ (for Helm installation method)

### Optional
- **Kernel Module Manager (KMM)**: 2.4+ (for automated kernel module deployment)
- **SELinux**: Permissive mode (required for KMM module loading)

---

## Installation Methods

### Method 1: Helm Chart (Recommended)

The fastest and easiest way to install mock-device is using the official Helm chart.

#### Install DRA Driver Only

Assumes kernel module is already loaded on nodes:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.1.0 \
  --namespace mock-device --create-namespace
```

#### Install DRA Driver + Kernel Module (via KMM)

Deploys both DRA driver and kernel module automatically:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.1.0 \
  --namespace mock-device --create-namespace \
  --set kernelModule.enabled=true \
  --set kernelModule.image.tag=v0.1.0-fc43
```

**Note**: Requires KMM operator to be installed. See [KMM Installation](#kmm-operator-installation) below.

#### Custom Image Registry

Use images from a private registry:

```bash
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device \
  --version 0.1.0 \
  --namespace mock-device --create-namespace \
  --set draDriver.controller.image.repository=myregistry.io/mock-accel-dra-driver \
  --set draDriver.nodeAgent.image.repository=myregistry.io/mock-accel-dra-driver
```

---

### Method 2: Manual YAML Deployment

For environments where Helm is not available or when manual control is preferred.

#### Step 1: Download Release Manifests

```bash
VERSION=v0.1.0
wget https://github.com/fabiendupont/mock-device/archive/refs/tags/${VERSION}.tar.gz
tar -xzf ${VERSION}.tar.gz
cd mock-device-${VERSION#v}
```

#### Step 2: Apply Kubernetes Manifests

```bash
# Create namespace
kubectl create namespace mock-device

# Apply RBAC resources
kubectl apply -f dra-driver/deployments/rbac.yaml

# Apply controller
kubectl apply -f dra-driver/deployments/controller.yaml

# Apply node agent
kubectl apply -f dra-driver/deployments/node-agent.yaml

# Apply DeviceClasses
kubectl apply -f dra-driver/deployments/deviceclass.yaml
```

#### Step 3: Deploy Kernel Module (via KMM)

If using KMM for kernel module deployment:

```bash
# Update image tag in module manifest
sed -i "s|containerImage:.*|containerImage: \"ghcr.io/fabiendupont/mock-accel-module:v0.1.0-fc43\"|" kmm/module.yaml

# Apply Module CR
kubectl apply -f kmm/module.yaml
```

---

### Method 3: Binary Installation (Development)

For development environments or manual testing outside Kubernetes.

#### Download Binaries

```bash
VERSION=v0.1.0
ARCH=amd64  # or arm64

# DRA driver binary
wget https://github.com/fabiendupont/mock-device/releases/download/${VERSION}/dra-driver-linux-${ARCH}
chmod +x dra-driver-linux-${ARCH}

# vfio-user server binary
wget https://github.com/fabiendupont/mock-device/releases/download/${VERSION}/mock-accel-server-linux-${ARCH}
chmod +x mock-accel-server-linux-${ARCH}
```

#### Run DRA Driver Locally

```bash
# Controller mode
./dra-driver-linux-${ARCH} \
  --mode=controller \
  --driver-name=mock-accel.example.com \
  --rescan-interval=30s \
  --v=5

# Node agent mode (separate terminal/process)
./dra-driver-linux-${ARCH} \
  --mode=node-agent \
  --driver-name=mock-accel.example.com \
  --plugin-socket=/var/lib/kubelet/plugins/mock-accel.example.com \
  --v=5
```

---

## KMM Operator Installation

Kernel Module Manager is required if you want automated kernel module deployment.

### Install cert-manager (Required by KMM)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=180s deployment -n cert-manager cert-manager-webhook
```

### Install KMM Operator

```bash
kubectl apply -k https://github.com/kubernetes-sigs/kernel-module-management/config/default?ref=v2.4.1

# Verify KMM is running
kubectl get pods -n kmm-operator-system
```

### Configure SELinux (Required for KMM)

KMM requires SELinux to be in permissive mode:

```bash
# On each node
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

---

## Verification

### Check Installation Status

```bash
# Check DaemonSets are running
kubectl get daemonset -n mock-device

# Expected output:
# NAME                          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
# mock-device-controller        2         2         2       2            2           <none>          1m
# mock-device-node-agent        2         2         2       2            2           <none>          1m
```

### Check ResourceSlices

```bash
# ResourceSlices should be published by the controller
kubectl get resourceslices -l driver=mock-accel.example.com

# Expected output: One ResourceSlice per device
# NAME                                                      NODE          DRIVER
# mock-accel.example.com-node1-mock0                       node1         mock-accel.example.com
# mock-accel.example.com-node1-mock1                       node1         mock-accel.example.com
```

### Check DeviceClasses

```bash
kubectl get deviceclass | grep mock-accel

# Expected output:
# mock-accel-pf         <none>         1m
# mock-accel-vf         <none>         1m
```

### Check Kernel Module (if using KMM)

```bash
# Check Module status
kubectl get module -n mock-device

# Check if module is loaded on nodes
kubectl get pods -n mock-device -l kmm.node.kubernetes.io/module.name=mock-accel

# Verify module is loaded (SSH to node)
ssh node1 lsmod | grep mock_accel
```

### Check sysfs Devices

```bash
# SSH to a node and check sysfs
ssh node1 ls -la /sys/class/mock-accel/

# Expected output:
# mock0  mock1  mock2  ...
```

---

## Test Device Allocation

### Create Test ResourceClaim

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

### Create Test Pod

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
  restartPolicy: Never
EOF
```

### Verify Device Allocation

```bash
# Wait for pod to be Running
kubectl wait --for=condition=Ready pod/test-pod --timeout=60s

# Check environment variables
kubectl exec test-pod -- env | grep MOCK_ACCEL

# Expected output:
# MOCK_ACCEL_DEVICE=mock0
# MOCK_ACCEL_UUID=NODE1-NUMA0-PF
# MOCK_ACCEL_PCI=0000:11:00.0

# Verify sysfs mount in container
kubectl exec test-pod -- ls /sys/class/mock-accel/
```

### Cleanup Test Resources

```bash
kubectl delete pod test-pod
kubectl delete resourceclaim test-claim
```

---

## Configuration

### Helm Values

See the [Helm Chart README](../charts/mock-device/README.md) for complete configuration options.

Common customizations:

```yaml
# Custom driver name
draDriver:
  name: custom-mock.example.com

# Adjust resource limits
draDriver:
  controller:
    resources:
      limits:
        cpu: 500m
        memory: 512Mi

# Increase log verbosity
draDriver:
  controller:
    verbosity: 10
  nodeAgent:
    verbosity: 10

# Multiple distro kernel modules
kernelModule:
  kernelMappings:
    - regexp: '^.*\.fc43\.x86_64$'
      containerImage: "ghcr.io/fabiendupont/mock-accel-module:v0.1.0-fc43"
    - regexp: '^.*\.fc44\.x86_64$'
      containerImage: "ghcr.io/fabiendupont/mock-accel-module:v0.1.0-fc44"
```

---

## Troubleshooting

### Devices Not Discovered

**Symptoms**: `kubectl get resourceslices` shows no mock-accel slices.

**Debug Steps**:

1. Check controller pod status:
   ```bash
   kubectl get pods -n mock-device -l app=mock-accel-controller
   ```

2. Check controller logs:
   ```bash
   kubectl logs -n mock-device -l app=mock-accel-controller --tail=50
   ```

3. Verify kernel module is loaded:
   ```bash
   ssh node1 lsmod | grep mock_accel
   ```

4. Check sysfs devices exist:
   ```bash
   ssh node1 ls /sys/class/mock-accel/
   ```

**Resolution**:
- If module not loaded: Check KMM worker pod logs
- If sysfs empty: Verify vfio-user server is running and devices attached to QEMU
- If controller not running: Check RBAC permissions

---

### Kernel Module Fails to Load

**Symptoms**: KMM worker pods fail, module not loaded.

**Debug Steps**:

1. Verify crun is default runtime:
   ```bash
   kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'
   # Should contain "crun"
   ```

2. Check SELinux mode:
   ```bash
   ssh node1 getenforce
   # Should output: Permissive
   ```

3. Check KMM worker logs:
   ```bash
   kubectl logs -n mock-device -l kmm.node.kubernetes.io/module.name=mock-accel
   ```

**Resolution**:
- Ensure k3s/k8s configured with `--default-runtime crun`
- Set SELinux to permissive mode
- Check kernel version matches KMM kernel mapping

---

### Pod Fails to Get Device

**Symptoms**: Pod stuck in Pending, allocation error in events.

**Debug Steps**:

1. Check pod events:
   ```bash
   kubectl describe pod <pod-name>
   ```

2. Check ResourceClaim status:
   ```bash
   kubectl get resourceclaim <claim-name> -o yaml
   ```

3. Check node agent logs:
   ```bash
   kubectl logs -n mock-device -l app=mock-accel-node-agent --tail=100
   ```

4. Verify device availability:
   ```bash
   ssh node1 cat /sys/class/mock-accel/mock0/status
   # 0 = free, 1 = allocated
   ```

**Resolution**:
- Check CEL expression syntax in DeviceClass
- Verify devices match selector criteria
- Free allocated devices by deleting pods
- Restart node agent if stuck

---

## Uninstallation

### Helm Installation

```bash
helm uninstall mock-device -n mock-device
kubectl delete namespace mock-device

# Optionally, remove DeviceClasses (cluster-scoped)
kubectl delete deviceclass mock-accel-pf mock-accel-vf
```

### Manual Installation

```bash
kubectl delete -f dra-driver/deployments/deviceclass.yaml
kubectl delete -f dra-driver/deployments/node-agent.yaml
kubectl delete -f dra-driver/deployments/controller.yaml
kubectl delete -f dra-driver/deployments/rbac.yaml
kubectl delete -f kmm/module.yaml
kubectl delete namespace mock-device
```

---

## Next Steps

- **Integration Guide**: See [Integration Guide](integration-guide.md) for using mock-device with meta-DRA drivers
- **Testing Guide**: See [Testing Guide](testing-guide.md) for E2E testing scenarios
- **API Reference**: See [API Reference](api-reference.md) for ResourceSlice schema and device attributes
- **Upgrade Guide**: See [Upgrade Guide](upgrade-guide.md) for version upgrade procedures

---

## Support

For issues and questions:
- **GitHub Issues**: https://github.com/fabiendupont/mock-device/issues
- **Documentation**: https://github.com/fabiendupont/mock-device/blob/main/docs/
