# Contributing to Mock Device

Thank you for your interest in contributing to the mock-device project!

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Building Components](#building-components)
- [Testing](#testing)
- [Release Process](#release-process)
- [Submitting Changes](#submitting-changes)
- [Coding Standards](#coding-standards)

---

## Code of Conduct

Be respectful, professional, and collaborative. We follow the [Kubernetes Code of Conduct](https://kubernetes.io/community/code-of-conduct/).

---

## Getting Started

### Prerequisites

**Development Tools:**
- Git
- Go 1.24+
- GCC, Make
- CMake (for libvfio-user)
- Docker (for container builds)
- Helm 3.14+
- kubectl

**Testing Environment:**
- QEMU 7.0+ (with vfio-user support)
- Kubernetes 1.29+ (k3s recommended for testing)
- Linux kernel 6.11+ (for kernel module testing)

### Clone Repository

```bash
git clone https://github.com/fabiendupont/mock-device.git
cd mock-device

# Clone libvfio-user submodule
git submodule update --init --recursive
```

---

## Development Workflow

### 1. Fork and Branch

```bash
# Fork on GitHub, then clone your fork
git clone https://github.com/<your-username>/mock-device.git
cd mock-device

# Add upstream remote
git remote add upstream https://github.com/fabiendupont/mock-device.git

# Create feature branch
git checkout -b feature/my-feature
```

### 2. Make Changes

Follow [Coding Standards](#coding-standards) when making changes.

### 3. Test Locally

See [Testing](#testing) section for comprehensive testing instructions.

### 4. Commit and Push

```bash
# Stage changes
git add .

# Commit with descriptive message
git commit -m "feat: add new device attribute for power consumption"

# Push to your fork
git push origin feature/my-feature
```

**Commit Message Format:**

Follow [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Test updates
- `chore:` - Build, CI, or tooling changes

### 5. Open Pull Request

- Go to GitHub and create a Pull Request from your fork to `fabiendupont/mock-device:main`
- Fill in the PR template with description and testing details
- Wait for CI checks to pass
- Address review feedback

---

## Building Components

### DRA Driver (Go)

```bash
cd dra-driver

# Download dependencies
go mod download

# Run tests
go test -v ./...

# Build binary
make build

# Build container image
make build-image

# Load image into k3s
make load-image
```

### Kernel Module (C)

```bash
cd kernel-driver

# Build module (requires kernel headers)
make

# Build container image
make build-image

# Load into k3s
make load-image
```

### vfio-user Server (C)

```bash
# Build libvfio-user (one-time)
cd libvfio-user
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Debug ..
make
cd ../..

# Build server
cd vfio-user
make

# Run server
./mock-accel-server -v -u TEST-UUID /tmp/test.sock
```

### Helm Chart

```bash
cd charts/mock-device

# Lint chart
helm lint .

# Render templates (dry-run)
helm template test .

# Package chart
helm package .

# Test installation (local chart)
helm install mock-device . --dry-run --debug
```

---

## Testing

### Unit Tests

```bash
# Go tests (DRA driver)
cd dra-driver
go test -v -race -coverprofile=coverage.out ./...
go tool cover -html=coverage.out
```

### Integration Tests

```bash
# Start NUMA cluster (2 nodes, NUMA topology)
./scripts/start-numa-cluster.sh

# Setup k3s with crun
./scripts/setup-k3s-cluster.sh

# Deploy kernel module via KMM
./scripts/deploy-kmm-module.sh

# Check cluster status
./scripts/status-cluster.sh

# Deploy DRA driver
cd dra-driver
make deploy

# Verify ResourceSlices
kubectl get resourceslices -l driver=mock-accel.example.com

# Test device allocation
kubectl apply -f docs/examples/basic-allocation.yaml
kubectl wait --for=condition=Ready pod/basic-allocation-test --timeout=60s
kubectl logs basic-allocation-test

# Cleanup
kubectl delete -f docs/examples/basic-allocation.yaml
cd ..
./scripts/stop-numa-cluster.sh
```

### Manual Testing

See [Testing Guide](docs/testing-guide.md) for comprehensive test scenarios.

---

## Release Process

### Versioning

Mock-device follows [Semantic Versioning](https://semver.org/):
- **MAJOR**: Breaking changes, incompatible API changes
- **MINOR**: New features, backward-compatible
- **PATCH**: Bug fixes, backward-compatible

All components share the same version number (unified versioning).

### Release Steps

**Maintainers only.**

#### 1. Prepare Release

Update version and changelog:

```bash
# Bump version (major, minor, patch, or specific version)
./scripts/bump-version.sh 0.2.0

# This updates:
# - VERSION file
# - charts/mock-device/Chart.yaml
# - charts/mock-device/values.yaml
```

Update CHANGELOG.md:

```bash
# Edit CHANGELOG.md
vim CHANGELOG.md

# Add new version entry under [Unreleased]
## [0.2.0] - YYYY-MM-DD

### Added
- New feature X

### Fixed
- Bug Y

### Changed
- Improvement Z
```

#### 2. Commit Changes

```bash
# Stage all version changes
git add VERSION CHANGELOG.md charts/

# Commit with version bump message
git commit -m "chore: bump version to v0.2.0"

# Push to main
git push origin main
```

#### 3. Create Git Tag

```bash
# Create annotated tag
git tag -a v0.2.0 -m "Release v0.2.0"

# Push tag (triggers release workflow)
git push origin v0.2.0
```

#### 4. Monitor Release Workflow

GitHub Actions will automatically:
1. Verify VERSION file matches tag
2. Run tests
3. Build binaries (amd64, arm64)
4. Build container images (multi-platform)
5. Create source tarballs
6. Package Helm chart
7. Publish to ghcr.io (images + Helm chart)
8. Create GitHub Release with all artifacts

Monitor at: https://github.com/fabiendupont/mock-device/actions

#### 5. Verify Release

```bash
# Check GitHub Release created
# https://github.com/fabiendupont/mock-device/releases/tag/v0.2.0

# Pull container image
docker pull ghcr.io/fabiendupont/mock-accel-dra-driver:v0.2.0

# Pull Helm chart
helm pull oci://ghcr.io/fabiendupont/charts/mock-device --version 0.2.0

# Test installation
helm install mock-device oci://ghcr.io/fabiendupont/charts/mock-device --version 0.2.0
```

#### 6. Announce Release

- Update project README if needed
- Notify downstream consumers (e.g., k8s-dra-driver-nodepartition team)
- Post announcement (if applicable)

### Hotfix Releases

For critical bug fixes:

```bash
# Create hotfix branch from release tag
git checkout -b hotfix/0.1.1 v0.1.0

# Fix bug
vim dra-driver/pkg/controller/controller.go
git commit -m "fix: critical allocation bug"

# Bump patch version
./scripts/bump-version.sh patch

# Update CHANGELOG
vim CHANGELOG.md

# Commit and tag
git commit -am "chore: bump version to v0.1.1"
git tag -a v0.1.1 -m "Release v0.1.1 (hotfix)"

# Push
git push origin hotfix/0.1.1
git push origin v0.1.1

# Merge back to main
git checkout main
git merge hotfix/0.1.1
git push origin main
```

---

## Submitting Changes

### Pull Request Guidelines

**Before submitting:**
- [ ] Code follows [Coding Standards](#coding-standards)
- [ ] Tests added/updated for new features or bug fixes
- [ ] Documentation updated (README, guides, API reference)
- [ ] Commit messages follow Conventional Commits format
- [ ] CI checks pass (linting, tests, builds)

**PR Description should include:**
- **What**: Brief summary of changes
- **Why**: Motivation and context
- **How**: Implementation approach
- **Testing**: How you tested the changes
- **Breaking Changes**: If applicable

**Example PR Description:**

```markdown
## What
Add power consumption attribute to device sysfs interface.

## Why
Enable DRA drivers to make power-aware allocation decisions.

## How
- Updated vfio-user server to expose power_consumption register (BAR0 offset 0x30)
- Modified kernel driver to read register and expose via sysfs
- Added `power` attribute to ResourceSlice

## Testing
- Unit tests for sysfs attribute parsing
- Integration test with NUMA cluster
- Verified ResourceSlice includes power attribute

## Breaking Changes
None - backward compatible addition.
```

### Review Process

1. Maintainer reviews code and provides feedback
2. Author addresses feedback
3. Maintainer approves PR
4. PR merged to main via squash or rebase
5. Changes included in next release

---

## Coding Standards

### Go (DRA Driver)

**Style:**
- Follow [Effective Go](https://golang.org/doc/effective_go.html)
- Run `gofmt` before committing
- Use `golangci-lint` for linting

**Conventions:**
```go
// Package comments
package controller

// Exported function with doc comment
// DeviceScanner scans sysfs for mock-accel devices.
func DeviceScanner() error {
    // Implementation
}

// Use structured logging
klog.V(2).InfoS("Scanned devices", "count", len(devices), "node", nodeName)
```

**Testing:**
```go
// Table-driven tests
func TestDeviceScanner(t *testing.T) {
    tests := []struct {
        name    string
        sysfs   string
        want    int
        wantErr bool
    }{
        // Test cases
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Test logic
        })
    }
}
```

### C (Kernel Module, vfio-user Server)

**Style:**
- Follow [Linux Kernel Coding Style](https://www.kernel.org/doc/html/latest/process/coding-style.html)
- Use tabs (8-space width) for indentation
- 80-column line limit (soft limit)

**Conventions:**
```c
/* Multi-line comment
 * with proper formatting
 */

// Single-line comment for brief notes

#define DRV_VERSION "0.1.0"
#define BAR0_SIZE 4096

struct mock_accel_dev {
    struct pci_dev *pdev;
    void __iomem *bar0;
    char uuid[37];
};

static int mock_accel_probe(struct pci_dev *pdev,
                             const struct pci_device_id *id)
{
    struct mock_accel_dev *dev;
    int ret;

    /* Implementation */
    return 0;
}
```

### Helm Charts

**Structure:**
- Use `_helpers.tpl` for reusable template functions
- Parameterize all configurable values in `values.yaml`
- Add comments for complex template logic

**Conventions:**
```yaml
# values.yaml - use camelCase
draDriver:
  controller:
    image:
      repository: ghcr.io/fabiendupont/mock-accel-dra-driver
      tag: v0.1.0
```

```yaml
# templates/ - use template functions
{{- define "mock-device.fullname" -}}
{{- .Chart.Name }}-{{ .Release.Name }}
{{- end }}

# Use consistent indentation (2 spaces)
spec:
  template:
    spec:
      containers:
      - name: controller
        image: {{ include "mock-device.draDriver.image" . }}
```

### Documentation

**Markdown:**
- Use GitHub-flavored Markdown
- Code blocks with language hints: ` ```bash ` , ` ```yaml `
- Tables for structured data
- Links to related docs

**Structure:**
- Clear headings (H2 for major sections, H3 for subsections)
- Table of Contents for long documents
- Examples for all features
- Troubleshooting sections

---

## Issue Reporting

### Bug Reports

Use the bug report template and include:
- **Description**: Clear summary of the bug
- **Steps to Reproduce**: Minimal reproduction steps
- **Expected Behavior**: What should happen
- **Actual Behavior**: What actually happens
- **Environment**:
  - Kubernetes version
  - Container runtime and version
  - Kernel version
  - Mock-device version
- **Logs**: Relevant logs (controller, node agent, KMM)

### Feature Requests

Use the feature request template and include:
- **Use Case**: Why is this feature needed?
- **Proposed Solution**: How should it work?
- **Alternatives**: Other approaches considered
- **Impact**: Breaking changes? Backward compatibility?

---

## Questions and Support

- **GitHub Issues**: https://github.com/fabiendupont/mock-device/issues
- **Documentation**: https://github.com/fabiendupont/mock-device/blob/main/docs/

---

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
