# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-01-06

### Added
- Initial release of mock-device monorepo
- DRA driver (controller + node agent) for Kubernetes Dynamic Resource Allocation
- Kernel module (mock-accel.ko) for PCIe device emulation via vfio-user
- vfio-user server for userspace device emulation with libvfio-user
- Helm chart for streamlined Kubernetes deployment
- Comprehensive documentation:
  - Installation guide with Helm, manual YAML, and binary methods
  - Integration guide for meta-DRA drivers (Node Partition DRA)
  - Testing guide with E2E test scenarios
  - API reference for ResourceSlice schema and sysfs interface
  - Extension guide for adding custom device attributes
- GitHub Actions CI/CD pipeline:
  - Automated builds and tests on PRs and main branch
  - Release automation on git tag push
  - Multi-platform container images (amd64, arm64)
  - OCI Helm chart registry
- Unified versioning across all components (single VERSION file)
- Version injection mechanisms for Go, C kernel module, and C userspace
- Automated version bumping script

### Components
- **DRA Driver**: v0.1.0
  - Controller DaemonSet for device discovery and ResourceSlice publishing
  - Node Agent DaemonSet for kubelet plugin and CDI generation
  - Support for Physical Functions (PF) and Virtual Functions (VF)
  - NUMA topology awareness with pool grouping
  - SR-IOV support with parent PF tracking
- **Kernel Module**: v0.1.0 (Fedora 43)
  - PCI driver for vfio-user emulated devices
  - sysfs interface for device attributes and allocation status
  - SR-IOV support (numvfs, totalvfs)
  - Firmware loading support (passphrase generation)
- **vfio-user Server**: v0.1.0
  - PCIe config space emulation
  - BAR0 register emulation (UUID, memory size, capabilities, status)
  - SR-IOV capability structure
  - Passphrase generator feature

### Compatibility
- **Kubernetes**: 1.29+ (DRA v1alpha3 API)
- **Container Runtime**: containerd 1.7+ with CDI support, crun runtime
- **Kernel**: 6.11+ (Fedora 43)
- **KMM Operator**: 2.4+ (optional, for kernel module deployment)

### Integration
- Compatible with [k8s-dra-driver-nodepartition](https://github.com/fabiendupont/k8s-dra-driver-nodepartition) for meta-DRA orchestration
- Exposes standard DRA ResourceSlices with topology attributes
- Supports CEL-based DeviceClass selectors for flexible device matching

### Container Images
- `ghcr.io/fabiendupont/mock-accel-dra-driver:v0.1.0`
- `ghcr.io/fabiendupont/mock-accel-module:v0.1.0-fc43`

### Helm Chart
- `oci://ghcr.io/fabiendupont/charts/mock-device:0.1.0`

### Release Artifacts
- Source tarballs (full, vfio-user, kernel-driver, dra-driver)
- Binaries (dra-driver-linux-amd64, dra-driver-linux-arm64, mock-accel-server-linux-amd64)
- SHA256 checksums

[Unreleased]: https://github.com/fabiendupont/mock-device/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/fabiendupont/mock-device/releases/tag/v0.1.0
