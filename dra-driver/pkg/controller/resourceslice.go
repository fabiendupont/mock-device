package controller

import (
	"fmt"

	resourcev1 "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/klog/v2"

	"github.com/fabiendupont/mock-device/dra-driver/pkg/discovery"
)

const (
	driverName = "mock-accel.example.com"
)

// ResourceSliceBuilder builds ResourceSlice objects from discovered devices
type ResourceSliceBuilder struct {
	nodeName   string
	generation int64
}

// NewResourceSliceBuilder creates a new ResourceSlice builder
func NewResourceSliceBuilder(nodeName string) *ResourceSliceBuilder {
	return &ResourceSliceBuilder{
		nodeName:   nodeName,
		generation: 1,
	}
}

// Build creates one ResourceSlice per device with complete topology information
func (b *ResourceSliceBuilder) Build(devices map[string]*discovery.DiscoveredDevice) ([]*resourcev1.ResourceSlice, error) {
	if len(devices) == 0 {
		klog.V(4).Info("No devices to build ResourceSlices from")
		return []*resourcev1.ResourceSlice{}, nil
	}

	slices := make([]*resourcev1.ResourceSlice, 0, len(devices))

	for _, dev := range devices {
		slice := b.buildSliceForDevice(dev)
		slices = append(slices, slice)
	}

	klog.V(4).Infof("Built %d ResourceSlices (one per device)", len(slices))
	return slices, nil
}

// buildSliceForDevice creates a ResourceSlice for a single device with complete topology info
func (b *ResourceSliceBuilder) buildSliceForDevice(dev *discovery.DiscoveredDevice) *resourcev1.ResourceSlice {
	sliceName := fmt.Sprintf("%s-%s-%s", driverName, b.nodeName, dev.Name)

	klog.V(5).Infof("Building ResourceSlice %s for device %s (NUMA=%d, PCI=%s)",
		sliceName, dev.Name, dev.NumaNode, dev.PCIAddress)

	nodeNamePtr := b.nodeName
	slice := &resourcev1.ResourceSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name: sliceName,
			Labels: map[string]string{
				"driver": driverName,
				"node":   b.nodeName,
				"device": dev.Name,
			},
		},
		Spec: resourcev1.ResourceSliceSpec{
			NodeName: &nodeNamePtr,
			Pool: resourcev1.ResourcePool{
				Name:               dev.Name, // Each device is its own pool
				Generation:         b.generation,
				ResourceSliceCount: 1,
			},
			Driver:  driverName,
			Devices: []resourcev1.Device{b.buildDevice(dev)},
		},
	}

	return slice
}

// buildDevice creates a Device entry for a ResourceSlice with complete topology attributes
func (b *ResourceSliceBuilder) buildDevice(dev *discovery.DiscoveredDevice) resourcev1.Device {
	device := resourcev1.Device{
		Name:       dev.Name,
		Attributes: make(map[resourcev1.QualifiedName]resourcev1.DeviceAttribute),
		Capacity:   make(map[resourcev1.QualifiedName]resourcev1.DeviceCapacity),
	}

	// Basic device attributes (prefixed with driver domain for v1 CEL access)
	device.Attributes[driverName+"/uuid"] = resourcev1.DeviceAttribute{
		StringValue: &dev.UUID,
	}

	device.Attributes[driverName+"/memory"] = resourcev1.DeviceAttribute{
		IntValue: &dev.MemorySize,
	}

	device.Attributes[driverName+"/deviceType"] = resourcev1.DeviceAttribute{
		StringValue: &dev.DeviceType,
	}

	device.Attributes[driverName+"/pciAddress"] = resourcev1.DeviceAttribute{
		StringValue: &dev.PCIAddress,
	}

	// Topology attributes for meta-DRA driver
	numaNodeInt64 := int64(dev.NumaNode)
	device.Attributes[driverName+"/numaNode"] = resourcev1.DeviceAttribute{
		IntValue: &numaNodeInt64,
	}

	// Add physfn for VFs
	if dev.DeviceType == "vf" && dev.PhysFn != "" {
		device.Attributes[driverName+"/physfn"] = resourcev1.DeviceAttribute{
			StringValue: &dev.PhysFn,
		}
	}

	// Add capabilities as integer
	capsInt64 := int64(dev.Capabilities)
	device.Attributes[driverName+"/capabilities"] = resourcev1.DeviceAttribute{
		IntValue: &capsInt64,
	}

	// Add capacity (memory as allocatable resource)
	device.Capacity[driverName+"/memory"] = resourcev1.DeviceCapacity{
		Value: *resource.NewQuantity(dev.MemorySize, resource.BinarySI),
	}

	return device
}

// groupByNuma groups devices by NUMA node
func groupByNuma(devices map[string]*discovery.DiscoveredDevice) map[int][]*discovery.DiscoveredDevice {
	groups := make(map[int][]*discovery.DiscoveredDevice)
	for _, dev := range devices {
		groups[dev.NumaNode] = append(groups[dev.NumaNode], dev)
	}
	return groups
}

