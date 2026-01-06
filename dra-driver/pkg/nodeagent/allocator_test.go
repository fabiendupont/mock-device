package nodeagent

import (
	"os"
	"path/filepath"
	"testing"
)

func setupMockSysfsForAllocator(t *testing.T) string {
	tmpDir := t.TempDir()

	// Create mock devices with status files
	devices := []string{"mock0", "mock1", "mock0_vf0"}

	for _, dev := range devices {
		devDir := filepath.Join(tmpDir, dev)
		if err := os.MkdirAll(devDir, 0755); err != nil {
			t.Fatalf("Failed to create device directory: %v", err)
		}

		// Create status file initialized to "0" (free)
		statusPath := filepath.Join(devDir, "status")
		if err := os.WriteFile(statusPath, []byte("0"), 0644); err != nil {
			t.Fatalf("Failed to create status file: %v", err)
		}
	}

	return tmpDir
}

func TestSysfsAllocator_Allocate(t *testing.T) {
	sysfsPath := setupMockSysfsForAllocator(t)

	allocator := NewSysfsAllocator()
	allocator.SetSysfsPath(sysfsPath)

	// Test allocating a device
	err := allocator.Allocate("mock0")
	if err != nil {
		t.Fatalf("Allocate failed: %v", err)
	}

	// Verify status was set to "1"
	statusPath := filepath.Join(sysfsPath, "mock0", "status")
	data, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("Failed to read status: %v", err)
	}

	if string(data) != StatusAllocated {
		t.Errorf("Expected status '%s', got '%s'", StatusAllocated, string(data))
	}
}

func TestSysfsAllocator_Deallocate(t *testing.T) {
	sysfsPath := setupMockSysfsForAllocator(t)

	allocator := NewSysfsAllocator()
	allocator.SetSysfsPath(sysfsPath)

	// First allocate
	if err := allocator.Allocate("mock0"); err != nil {
		t.Fatalf("Allocate failed: %v", err)
	}

	// Then deallocate
	err := allocator.Deallocate("mock0")
	if err != nil {
		t.Fatalf("Deallocate failed: %v", err)
	}

	// Verify status was set back to "0"
	statusPath := filepath.Join(sysfsPath, "mock0", "status")
	data, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("Failed to read status: %v", err)
	}

	if string(data) != StatusFree {
		t.Errorf("Expected status '%s', got '%s'", StatusFree, string(data))
	}
}

func TestSysfsAllocator_GetStatus(t *testing.T) {
	sysfsPath := setupMockSysfsForAllocator(t)

	allocator := NewSysfsAllocator()
	allocator.SetSysfsPath(sysfsPath)

	// Test getting initial status (free)
	status, err := allocator.GetStatus("mock0")
	if err != nil {
		t.Fatalf("GetStatus failed: %v", err)
	}

	if status != "0" {
		t.Errorf("Expected initial status '0', got '%s'", status)
	}

	// Allocate and check again
	if err := allocator.Allocate("mock0"); err != nil {
		t.Fatalf("Allocate failed: %v", err)
	}

	status, err = allocator.GetStatus("mock0")
	if err != nil {
		t.Fatalf("GetStatus failed: %v", err)
	}

	if status != StatusAllocated {
		t.Errorf("Expected status '%s' after allocation, got '%s'", StatusAllocated, status)
	}
}

func TestSysfsAllocator_AllocateNonexistent(t *testing.T) {
	sysfsPath := setupMockSysfsForAllocator(t)

	allocator := NewSysfsAllocator()
	allocator.SetSysfsPath(sysfsPath)

	// Try to allocate non-existent device
	err := allocator.Allocate("nonexistent")
	if err == nil {
		t.Error("Expected error for nonexistent device, got nil")
	}
}

func TestSysfsAllocator_MultipleDevices(t *testing.T) {
	sysfsPath := setupMockSysfsForAllocator(t)

	allocator := NewSysfsAllocator()
	allocator.SetSysfsPath(sysfsPath)

	// Allocate multiple devices
	devices := []string{"mock0", "mock1", "mock0_vf0"}

	for _, dev := range devices {
		if err := allocator.Allocate(dev); err != nil {
			t.Fatalf("Failed to allocate %s: %v", dev, err)
		}
	}

	// Verify all are allocated
	for _, dev := range devices {
		status, err := allocator.GetStatus(dev)
		if err != nil {
			t.Fatalf("Failed to get status for %s: %v", dev, err)
		}

		if status != StatusAllocated {
			t.Errorf("Device %s: expected status '%s', got '%s'", dev, StatusAllocated, status)
		}
	}

	// Deallocate one
	if err := allocator.Deallocate("mock1"); err != nil {
		t.Fatalf("Failed to deallocate mock1: %v", err)
	}

	// Verify mock1 is free but others are still allocated
	status, _ := allocator.GetStatus("mock1")
	if status != StatusFree {
		t.Errorf("mock1: expected status '%s' after deallocation, got '%s'", StatusFree, status)
	}

	status, _ = allocator.GetStatus("mock0")
	if status != StatusAllocated {
		t.Errorf("mock0: expected status '%s' (should still be allocated), got '%s'", StatusAllocated, status)
	}
}
