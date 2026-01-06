package nodeagent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	cdispec "tags.cncf.io/container-device-interface/specs-go"
)

func setupMockSysfsForCDI(t *testing.T) string {
	tmpDir := t.TempDir()

	// Create mock device with required attributes
	devDir := filepath.Join(tmpDir, "mock0")
	if err := os.MkdirAll(devDir, 0755); err != nil {
		t.Fatalf("Failed to create device directory: %v", err)
	}

	// Write attributes
	attrs := map[string]string{
		"uuid":         "NODE1-NUMA0-PF",
		"memory_size":  "17179869184",
		"capabilities": "0x00000001",
	}

	for name, value := range attrs {
		path := filepath.Join(devDir, name)
		if err := os.WriteFile(path, []byte(value), 0644); err != nil {
			t.Fatalf("Failed to write %s: %v", name, err)
		}
	}

	// Create PCI device symlink
	pciDir := filepath.Join(tmpDir, "..", "pci", "0000:11:00.0")
	if err := os.MkdirAll(pciDir, 0755); err != nil {
		t.Fatalf("Failed to create PCI directory: %v", err)
	}

	deviceLink := filepath.Join(devDir, "device")
	if err := os.Symlink(pciDir, deviceLink); err != nil {
		t.Fatalf("Failed to create device symlink: %v", err)
	}

	return tmpDir
}

func TestCDIGenerator_GenerateSpec(t *testing.T) {
	sysfsPath := setupMockSysfsForCDI(t)
	cdiDir := t.TempDir()

	generator := NewCDIGenerator()
	generator.sysfsPath = sysfsPath
	generator.SetCDIDir(cdiDir)

	// Generate CDI spec
	cdiDevice, err := generator.GenerateSpec("mock0")
	if err != nil {
		t.Fatalf("GenerateSpec failed: %v", err)
	}

	// Verify CDI device reference (format: vendor/class=device)
	expectedRef := "example.com/mock-accel=mock0"
	if cdiDevice != expectedRef {
		t.Errorf("Expected CDI device reference '%s', got '%s'", expectedRef, cdiDevice)
	}

	// Verify CDI spec file was created
	cdiPath := generator.getCDIPath("mock0")
	if _, err := os.Stat(cdiPath); os.IsNotExist(err) {
		t.Fatalf("CDI spec file not created at %s", cdiPath)
	}

	// Read and parse CDI spec
	data, err := os.ReadFile(cdiPath)
	if err != nil {
		t.Fatalf("Failed to read CDI spec: %v", err)
	}

	var spec cdispec.Spec
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatalf("Failed to unmarshal CDI spec: %v", err)
	}

	// Verify CDI spec contents
	if spec.Version != cdiVersion {
		t.Errorf("Expected CDI version '%s', got '%s'", cdiVersion, spec.Version)
	}

	if spec.Kind != cdiVendor {
		t.Errorf("Expected CDI kind '%s', got '%s'", cdiVendor, spec.Kind)
	}

	if len(spec.Devices) != 1 {
		t.Fatalf("Expected 1 device in CDI spec, got %d", len(spec.Devices))
	}

	device := spec.Devices[0]
	if device.Name != "mock0" {
		t.Errorf("Expected device name 'mock0', got '%s'", device.Name)
	}

	// Verify environment variables
	expectedEnvVars := map[string]bool{
		"MOCK_ACCEL_UUID=NODE1-NUMA0-PF":  true,
		"MOCK_ACCEL_PCI=0000:11:00.0":     true,
		"MOCK_ACCEL_DEVICE=mock0":         true,
	}

	if len(device.ContainerEdits.Env) != len(expectedEnvVars) {
		t.Errorf("Expected %d env vars, got %d", len(expectedEnvVars), len(device.ContainerEdits.Env))
	}

	for _, env := range device.ContainerEdits.Env {
		if !expectedEnvVars[env] {
			t.Errorf("Unexpected environment variable: %s", env)
		}
	}

	// Verify mounts
	if len(device.ContainerEdits.Mounts) != 1 {
		t.Fatalf("Expected 1 mount, got %d", len(device.ContainerEdits.Mounts))
	}

	mount := device.ContainerEdits.Mounts[0]
	expectedHostPath := filepath.Join(sysfsPath, "mock0")
	if mount.HostPath != expectedHostPath {
		t.Errorf("Expected host path '%s', got '%s'", expectedHostPath, mount.HostPath)
	}

	if mount.ContainerPath != expectedHostPath {
		t.Errorf("Expected container path '%s', got '%s'", expectedHostPath, mount.ContainerPath)
	}

	// Verify read-only mount
	hasRO := false
	for _, opt := range mount.Options {
		if opt == "ro" {
			hasRO = true
			break
		}
	}
	if !hasRO {
		t.Error("Expected mount to have 'ro' option")
	}
}

func TestCDIGenerator_RemoveSpec(t *testing.T) {
	sysfsPath := setupMockSysfsForCDI(t)
	cdiDir := t.TempDir()

	generator := NewCDIGenerator()
	generator.sysfsPath = sysfsPath
	generator.SetCDIDir(cdiDir)

	// Generate spec first
	_, err := generator.GenerateSpec("mock0")
	if err != nil {
		t.Fatalf("GenerateSpec failed: %v", err)
	}

	cdiPath := generator.getCDIPath("mock0")

	// Verify file exists
	if _, err := os.Stat(cdiPath); os.IsNotExist(err) {
		t.Fatal("CDI spec file should exist before removal")
	}

	// Remove spec
	err = generator.RemoveSpec("mock0")
	if err != nil {
		t.Fatalf("RemoveSpec failed: %v", err)
	}

	// Verify file is gone
	if _, err := os.Stat(cdiPath); !os.IsNotExist(err) {
		t.Error("CDI spec file should not exist after removal")
	}
}

func TestCDIGenerator_RemoveNonexistentSpec(t *testing.T) {
	cdiDir := t.TempDir()

	generator := NewCDIGenerator()
	generator.SetCDIDir(cdiDir)

	// Try to remove non-existent spec (should not error)
	err := generator.RemoveSpec("nonexistent")
	if err != nil {
		t.Errorf("RemoveSpec should not error for nonexistent spec, got: %v", err)
	}
}

func TestGetCDIPath(t *testing.T) {
	cdiDir := "/var/run/cdi"

	generator := NewCDIGenerator()
	generator.SetCDIDir(cdiDir)

	path := generator.getCDIPath("mock0")

	expected := filepath.Join(cdiDir, "example.com_mock-accel-mock0.json")
	if path != expected {
		t.Errorf("Expected CDI path '%s', got '%s'", expected, path)
	}
}

func TestCDIGenerator_MultipleDevices(t *testing.T) {
	sysfsPath := setupMockSysfsForCDI(t)
	cdiDir := t.TempDir()

	// Create second device
	devDir := filepath.Join(sysfsPath, "mock1")
	if err := os.MkdirAll(devDir, 0755); err != nil {
		t.Fatalf("Failed to create device directory: %v", err)
	}

	if err := os.WriteFile(filepath.Join(devDir, "uuid"), []byte("NODE1-NUMA1-PF"), 0644); err != nil {
		t.Fatalf("Failed to write uuid file: %v", err)
	}

	pciDir2 := filepath.Join(sysfsPath, "..", "pci", "0000:21:00.0")
	if err := os.MkdirAll(pciDir2, 0755); err != nil {
		t.Fatalf("Failed to create PCI directory: %v", err)
	}
	if err := os.Symlink(pciDir2, filepath.Join(devDir, "device")); err != nil {
		t.Fatalf("Failed to create device symlink: %v", err)
	}

	generator := NewCDIGenerator()
	generator.sysfsPath = sysfsPath
	generator.SetCDIDir(cdiDir)

	// Generate specs for both devices
	_, err1 := generator.GenerateSpec("mock0")
	_, err2 := generator.GenerateSpec("mock1")

	if err1 != nil || err2 != nil {
		t.Fatalf("Failed to generate specs: %v, %v", err1, err2)
	}

	// Verify both CDI files exist
	path1 := generator.getCDIPath("mock0")
	path2 := generator.getCDIPath("mock1")

	if _, err := os.Stat(path1); os.IsNotExist(err) {
		t.Error("CDI spec for mock0 not created")
	}

	if _, err := os.Stat(path2); os.IsNotExist(err) {
		t.Error("CDI spec for mock1 not created")
	}

	// Remove one and verify the other remains
	if err := generator.RemoveSpec("mock0"); err != nil {
		t.Fatalf("Failed to remove CDI spec: %v", err)
	}

	if _, err := os.Stat(path1); !os.IsNotExist(err) {
		t.Error("CDI spec for mock0 should be removed")
	}

	if _, err := os.Stat(path2); os.IsNotExist(err) {
		t.Error("CDI spec for mock1 should still exist")
	}
}
