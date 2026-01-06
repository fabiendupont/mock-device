package discovery

import (
	"os"
	"path/filepath"
	"testing"
)

// setupMockSysfs creates a mock sysfs directory structure for testing
func setupMockSysfs(t *testing.T) string {
	tmpDir := t.TempDir()

	// Create mock devices
	devices := []struct {
		name         string
		uuid         string
		memorySize   string
		capabilities string
		numaNode     string
		pciAddr      string
	}{
		{
			name:         "mock0",
			uuid:         "NODE1-NUMA0-PF",
			memorySize:   "17179869184",
			capabilities: "0x00000001",
			numaNode:     "0",
			pciAddr:      "0000:11:00.0",
		},
		{
			name:         "mock0_vf0",
			uuid:         "NODE1-NUMA0-VF0",
			memorySize:   "2147483648",
			capabilities: "0x00000001",
			numaNode:     "0",
			pciAddr:      "0000:11:00.1",
		},
		{
			name:         "mock1",
			uuid:         "NODE1-NUMA1-PF",
			memorySize:   "17179869184",
			capabilities: "0x00000001",
			numaNode:     "1",
			pciAddr:      "0000:21:00.0",
		},
	}

	for _, dev := range devices {
		devDir := filepath.Join(tmpDir, dev.name)
		if err := os.MkdirAll(devDir, 0755); err != nil {
			t.Fatalf("Failed to create device directory: %v", err)
		}

		// Write attributes
		writeAttr(t, devDir, "uuid", dev.uuid)
		writeAttr(t, devDir, "memory_size", dev.memorySize)
		writeAttr(t, devDir, "capabilities", dev.capabilities)

		// Create PCI device symlink structure
		pciDir := filepath.Join(tmpDir, "..", "pci", dev.pciAddr)
		if err := os.MkdirAll(pciDir, 0755); err != nil {
			t.Fatalf("Failed to create PCI directory: %v", err)
		}
		writeAttr(t, pciDir, "numa_node", dev.numaNode)

		// Create device symlink
		deviceLink := filepath.Join(devDir, "device")
		if err := os.Symlink(pciDir, deviceLink); err != nil {
			t.Fatalf("Failed to create device symlink: %v", err)
		}
	}

	return tmpDir
}

func writeAttr(t *testing.T, dir, name, value string) {
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(value), 0644); err != nil {
		t.Fatalf("Failed to write %s: %v", name, err)
	}
}

func TestDeviceScanner_Scan(t *testing.T) {
	sysfsPath := setupMockSysfs(t)

	scanner := NewDeviceScanner("test-node")
	scanner.SetSysfsPath(sysfsPath)

	devices, err := scanner.Scan()
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}

	if len(devices) != 3 {
		t.Errorf("Expected 3 devices, got %d", len(devices))
	}

	// Test PF device (mock0)
	mock0, ok := devices["mock0"]
	if !ok {
		t.Fatal("Device mock0 not found")
	}

	if mock0.UUID != "NODE1-NUMA0-PF" {
		t.Errorf("Expected UUID 'NODE1-NUMA0-PF', got '%s'", mock0.UUID)
	}

	if mock0.MemorySize != 17179869184 {
		t.Errorf("Expected memory size 17179869184, got %d", mock0.MemorySize)
	}

	if mock0.DeviceType != "pf" {
		t.Errorf("Expected device type 'pf', got '%s'", mock0.DeviceType)
	}

	if mock0.NumaNode != 0 {
		t.Errorf("Expected NUMA node 0, got %d", mock0.NumaNode)
	}

	if mock0.PCIAddress != "0000:11:00.0" {
		t.Errorf("Expected PCI address '0000:11:00.0', got '%s'", mock0.PCIAddress)
	}

	if mock0.Capabilities != 1 {
		t.Errorf("Expected capabilities 1, got %d", mock0.Capabilities)
	}

	if mock0.PhysFn != "" {
		t.Errorf("Expected empty PhysFn for PF, got '%s'", mock0.PhysFn)
	}

	// Test VF device (mock0_vf0)
	vf0, ok := devices["mock0_vf0"]
	if !ok {
		t.Fatal("Device mock0_vf0 not found")
	}

	if vf0.DeviceType != "vf" {
		t.Errorf("Expected device type 'vf', got '%s'", vf0.DeviceType)
	}

	if vf0.PhysFn != "mock0" {
		t.Errorf("Expected PhysFn 'mock0', got '%s'", vf0.PhysFn)
	}

	if vf0.MemorySize != 2147483648 {
		t.Errorf("Expected memory size 2147483648, got %d", vf0.MemorySize)
	}
}

func TestDeviceScanner_ScanNonexistentPath(t *testing.T) {
	scanner := NewDeviceScanner("test-node")
	scanner.SetSysfsPath("/nonexistent/path")

	devices, err := scanner.Scan()
	if err != nil {
		t.Fatalf("Expected no error for nonexistent path, got: %v", err)
	}

	if len(devices) != 0 {
		t.Errorf("Expected 0 devices for nonexistent path, got %d", len(devices))
	}
}

func TestDetectDeviceType(t *testing.T) {
	tests := []struct {
		name     string
		expected string
	}{
		{"mock0", "pf"},
		{"mock1", "pf"},
		{"mock0_vf0", "vf"},
		{"mock0_vf1", "vf"},
		{"mock1_vf0", "vf"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := detectDeviceType(tt.name)
			if result != tt.expected {
				t.Errorf("detectDeviceType(%s) = %s, expected %s", tt.name, result, tt.expected)
			}
		})
	}
}

func TestExtractPhysFnName(t *testing.T) {
	tests := []struct {
		vfName   string
		expected string
	}{
		{"mock0_vf0", "mock0"},
		{"mock0_vf1", "mock0"},
		{"mock1_vf0", "mock1"},
		{"mock1_vf15", "mock1"},
		{"mock0", "mock0"}, // Not a VF, returns original
	}

	for _, tt := range tests {
		t.Run(tt.vfName, func(t *testing.T) {
			result := extractPhysFnName(tt.vfName)
			if result != tt.expected {
				t.Errorf("extractPhysFnName(%s) = %s, expected %s", tt.vfName, result, tt.expected)
			}
		})
	}
}
