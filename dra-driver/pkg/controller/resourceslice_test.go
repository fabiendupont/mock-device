package controller

import (
	"testing"

	"github.com/fabiendupont/mock-device/dra-driver/pkg/discovery"
)

func TestResourceSliceBuilder_Build(t *testing.T) {
	builder := NewResourceSliceBuilder("test-node")

	devices := map[string]*discovery.DiscoveredDevice{
		"mock0": {
			Name:         "mock0",
			UUID:         "NODE1-NUMA0-PF",
			MemorySize:   17179869184,
			NumaNode:     0,
			DeviceType:   "pf",
			PCIAddress:   "0000:11:00.0",
			Capabilities: 1,
		},
		"mock0_vf0": {
			Name:         "mock0_vf0",
			UUID:         "NODE1-NUMA0-VF0",
			MemorySize:   2147483648,
			NumaNode:     0,
			DeviceType:   "vf",
			PCIAddress:   "0000:11:00.1",
			Capabilities: 1,
			PhysFn:       "mock0",
		},
		"mock1": {
			Name:         "mock1",
			UUID:         "NODE1-NUMA1-PF",
			MemorySize:   17179869184,
			NumaNode:     1,
			DeviceType:   "pf",
			PCIAddress:   "0000:21:00.0",
			Capabilities: 1,
		},
	}

	slices, err := builder.Build(devices)
	if err != nil {
		t.Fatalf("Build failed: %v", err)
	}

	// Should create 3 slices (one per device: mock0, mock0_vf0, mock1)
	if len(slices) != 3 {
		t.Errorf("Expected 3 ResourceSlices, got %d", len(slices))
	}

	// Verify slices have correct structure
	for _, slice := range slices {
		if slice.Spec.NodeName == nil || *slice.Spec.NodeName != "test-node" {
			t.Errorf("Expected NodeName 'test-node', got '%v'", slice.Spec.NodeName)
		}

		if slice.Spec.Driver != driverName {
			t.Errorf("Expected Driver '%s', got '%s'", driverName, slice.Spec.Driver)
		}

		if slice.Spec.Pool.Generation != 1 {
			t.Errorf("Expected Generation 1, got %d", slice.Spec.Pool.Generation)
		}

		// Check devices
		if len(slice.Spec.Devices) == 0 {
			t.Error("Expected devices in slice, got 0")
		}

		for _, dev := range slice.Spec.Devices {
			// Verify required attributes (using fully qualified names)
			if _, ok := dev.Attributes[driverName+"/uuid"]; !ok {
				t.Errorf("Device %s missing uuid attribute", dev.Name)
			}
			if _, ok := dev.Attributes[driverName+"/memory"]; !ok {
				t.Errorf("Device %s missing memory attribute", dev.Name)
			}
			if _, ok := dev.Attributes[driverName+"/deviceType"]; !ok {
				t.Errorf("Device %s missing deviceType attribute", dev.Name)
			}
			if _, ok := dev.Attributes[driverName+"/pciAddress"]; !ok {
				t.Errorf("Device %s missing pciAddress attribute", dev.Name)
			}

			// Verify capacity
			if _, ok := dev.Capacity[driverName+"/memory"]; !ok {
				t.Errorf("Device %s missing memory capacity", dev.Name)
			}
		}
	}
}

func TestResourceSliceBuilder_BuildEmpty(t *testing.T) {
	builder := NewResourceSliceBuilder("test-node")

	devices := map[string]*discovery.DiscoveredDevice{}

	slices, err := builder.Build(devices)
	if err != nil {
		t.Fatalf("Build failed: %v", err)
	}

	if len(slices) != 0 {
		t.Errorf("Expected 0 ResourceSlices for empty devices, got %d", len(slices))
	}
}

func TestGroupByNuma(t *testing.T) {
	devices := map[string]*discovery.DiscoveredDevice{
		"mock0": {NumaNode: 0},
		"mock1": {NumaNode: 0},
		"mock2": {NumaNode: 1},
		"mock3": {NumaNode: 1},
		"mock4": {NumaNode: 1},
	}

	groups := groupByNuma(devices)

	if len(groups) != 2 {
		t.Errorf("Expected 2 NUMA groups, got %d", len(groups))
	}

	if len(groups[0]) != 2 {
		t.Errorf("Expected 2 devices in NUMA 0, got %d", len(groups[0]))
	}

	if len(groups[1]) != 3 {
		t.Errorf("Expected 3 devices in NUMA 1, got %d", len(groups[1]))
	}
}

func TestBuildDevice_VF(t *testing.T) {
	builder := NewResourceSliceBuilder("test-node")

	dev := &discovery.DiscoveredDevice{
		Name:         "mock0_vf0",
		UUID:         "TEST-VF",
		MemorySize:   2147483648,
		NumaNode:     0,
		DeviceType:   "vf",
		PCIAddress:   "0000:11:00.1",
		Capabilities: 1,
		PhysFn:       "mock0",
	}

	device := builder.buildDevice(dev)

	// Verify VF has physfn attribute (using fully qualified name)
	physfn, ok := device.Attributes[driverName+"/physfn"]
	if !ok {
		t.Error("VF device missing physfn attribute")
	}

	if physfn.StringValue == nil || *physfn.StringValue != "mock0" {
		t.Errorf("Expected physfn 'mock0', got %v", physfn.StringValue)
	}

	// Verify deviceType
	deviceType, ok := device.Attributes[driverName+"/deviceType"]
	if !ok {
		t.Error("Device missing deviceType attribute")
	}

	if deviceType.StringValue == nil || *deviceType.StringValue != "vf" {
		t.Errorf("Expected deviceType 'vf', got %v", deviceType.StringValue)
	}
}

func TestBuildDevice_PF(t *testing.T) {
	builder := NewResourceSliceBuilder("test-node")

	dev := &discovery.DiscoveredDevice{
		Name:         "mock0",
		UUID:         "TEST-PF",
		MemorySize:   17179869184,
		NumaNode:     0,
		DeviceType:   "pf",
		PCIAddress:   "0000:11:00.0",
		Capabilities: 1,
	}

	device := builder.buildDevice(dev)

	// Verify PF does not have physfn attribute (using fully qualified name)
	if _, ok := device.Attributes[driverName+"/physfn"]; ok {
		t.Error("PF device should not have physfn attribute")
	}

	// Verify deviceType
	deviceType, ok := device.Attributes[driverName+"/deviceType"]
	if !ok {
		t.Error("Device missing deviceType attribute")
	}

	if deviceType.StringValue == nil || *deviceType.StringValue != "pf" {
		t.Errorf("Expected deviceType 'pf', got %v", deviceType.StringValue)
	}

	// Verify memory capacity
	memoryCap, ok := device.Capacity[driverName+"/memory"]
	if !ok {
		t.Error("Device missing memory capacity")
	}

	expectedBytes := int64(17179869184)
	if memoryCap.Value.Value() != expectedBytes {
		t.Errorf("Expected memory capacity %d, got %d", expectedBytes, memoryCap.Value.Value())
	}
}
