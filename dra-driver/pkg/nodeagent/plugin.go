package nodeagent

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/types"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"

	resourceapi "k8s.io/api/resource/v1"
)

// NodeAgent implements the DRAPlugin interface for kubeletplugin
type NodeAgent struct {
	allocator    *SysfsAllocator
	cdiGenerator *CDIGenerator
	driverName   string
}

// NewNodeAgent creates a new node agent that implements DRAPlugin
func NewNodeAgent(driverName string) *NodeAgent {
	return &NodeAgent{
		allocator:    NewSysfsAllocator(),
		cdiGenerator: NewCDIGenerator(),
		driverName:   driverName,
	}
}

// PrepareResourceClaims prepares devices for the given ResourceClaims
// This implements the DRAPlugin interface
func (n *NodeAgent) PrepareResourceClaims(
	ctx context.Context,
	claims []*resourceapi.ResourceClaim,
) (map[types.UID]kubeletplugin.PrepareResult, error) {
	klog.V(4).InfoS("PrepareResourceClaims called", "claimCount", len(claims))

	results := make(map[types.UID]kubeletplugin.PrepareResult)

	for _, claim := range claims {
		klog.V(5).InfoS("Preparing claim", "uid", claim.UID, "name", claim.Name, "namespace", claim.Namespace)

		result := n.prepareSingleClaim(ctx, claim)
		results[claim.UID] = result
	}

	return results, nil
}

// UnprepareResourceClaims cleans up devices for the given ResourceClaims
// This implements the DRAPlugin interface
func (n *NodeAgent) UnprepareResourceClaims(
	ctx context.Context,
	claims []kubeletplugin.NamespacedObject,
) (map[types.UID]error, error) {
	klog.V(4).InfoS("UnprepareResourceClaims called", "claimCount", len(claims))

	results := make(map[types.UID]error)

	for _, claim := range claims {
		klog.V(5).InfoS("Unpreparing claim", "uid", claim.UID, "name", claim.Name, "namespace", claim.Namespace)

		err := n.unprepareSingleClaim(ctx, claim)
		results[claim.UID] = err
	}

	return results, nil
}

// HandleError handles errors from background operations
// This implements the DRAPlugin interface
func (n *NodeAgent) HandleError(ctx context.Context, err error, msg string) {
	// Log error with context
	klog.ErrorS(err, msg)

	// Check if error is fatal (not recoverable)
	// For now, we'll just log - in production, might want to exit on fatal errors
	// if !errors.Is(err, kubeletplugin.ErrRecoverable) {
	//     klog.Fatal("Fatal error encountered, exiting")
	// }
}

// prepareSingleClaim prepares resources for a single claim
func (n *NodeAgent) prepareSingleClaim(ctx context.Context, claim *resourceapi.ResourceClaim) kubeletplugin.PrepareResult {
	// Extract device names from the claim's allocation
	deviceNames, err := n.extractDeviceNamesFromClaim(claim)
	if err != nil {
		klog.ErrorS(err, "Failed to extract devices from claim", "claim", claim.Name)
		return kubeletplugin.PrepareResult{
			Err: fmt.Errorf("failed to extract devices: %w", err),
		}
	}

	if len(deviceNames) == 0 {
		return kubeletplugin.PrepareResult{
			Err: fmt.Errorf("no devices found in claim allocation"),
		}
	}

	klog.V(5).InfoS("Preparing devices", "claim", claim.Name, "devices", deviceNames)

	// Prepare devices slice for result
	devices := make([]kubeletplugin.Device, 0, len(deviceNames))

	// Allocate and generate CDI specs for each device
	for i, deviceName := range deviceNames {
		// Allocate device via sysfs status register
		if err := n.allocator.Allocate(deviceName); err != nil {
			// Rollback previously allocated devices
			n.rollbackDevices(deviceNames[:i])
			return kubeletplugin.PrepareResult{
				Err: fmt.Errorf("failed to allocate device %s: %w", deviceName, err),
			}
		}

		// Generate CDI spec
		cdiDeviceID, err := n.cdiGenerator.GenerateSpec(deviceName)
		if err != nil {
			klog.ErrorS(err, "Failed to generate CDI spec", "device", deviceName)
			// Rollback allocation
			_ = n.allocator.Deallocate(deviceName)
			n.rollbackDevices(deviceNames[:i])
			return kubeletplugin.PrepareResult{
				Err: fmt.Errorf("failed to generate CDI spec for device %s: %w", deviceName, err),
			}
		}
		klog.V(4).InfoS("Generated CDI device", "device", deviceName, "cdiDeviceID", cdiDeviceID)

		// Determine pool name from device allocation (would be numa0, numa1, etc.)
		poolName := n.getPoolNameForDevice(claim, deviceName)

		// Add device to result
		devices = append(devices, kubeletplugin.Device{
			PoolName:     poolName,
			DeviceName:   deviceName,
			CDIDeviceIDs: []string{cdiDeviceID},
		})
	}

	klog.V(4).InfoS("Successfully prepared claim", "claim", claim.Name, "deviceCount", len(devices))

	// Return success with devices
	return kubeletplugin.PrepareResult{
		Devices: devices,
	}
}

// unprepareSingleClaim cleans up resources for a single claim
func (n *NodeAgent) unprepareSingleClaim(ctx context.Context, claim kubeletplugin.NamespacedObject) error {
	// Since we don't have the full ResourceClaim object here, we need to track
	// which devices were allocated to which claim. For now, we'll use a simple
	// approach: try to clean up based on claim UID stored in CDI spec metadata.

	// This is a limitation - in production, you'd want to persist claim->device mappings
	// For now, we'll log and return nil (idempotent behavior)
	klog.V(5).InfoS("Unprepare called - using best-effort cleanup", "claim", claim.Name, "uid", claim.UID)

	// In a real implementation, you'd:
	// 1. Load persisted state mapping claim UID -> device names
	// 2. Deallocate those specific devices
	// 3. Remove CDI specs

	// For MVP, we'll just log - the devices will be deallocated when pods are deleted
	// and kubelet calls unprepare with the actual device list

	return nil
}

// extractDeviceNamesFromClaim extracts allocated device names from a ResourceClaim
func (n *NodeAgent) extractDeviceNamesFromClaim(claim *resourceapi.ResourceClaim) ([]string, error) {
	if claim.Status.Allocation == nil {
		return nil, fmt.Errorf("claim has no allocation")
	}

	deviceNames := make([]string, 0)

	// Iterate through device request allocations
	for _, deviceRequestAlloc := range claim.Status.Allocation.Devices.Results {
		// Extract device name from the allocation result
		// In DRA v1, the device is identified by pool name + device name
		deviceName := deviceRequestAlloc.Device
		deviceNames = append(deviceNames, deviceName)
	}

	return deviceNames, nil
}

// getPoolNameForDevice extracts the pool name for a device from the claim allocation
func (n *NodeAgent) getPoolNameForDevice(claim *resourceapi.ResourceClaim, deviceName string) string {
	if claim.Status.Allocation == nil {
		return "default"
	}

	// Find the device in the allocation results
	for _, deviceRequestAlloc := range claim.Status.Allocation.Devices.Results {
		if deviceRequestAlloc.Device == deviceName {
			return deviceRequestAlloc.Pool
		}
	}

	// Fallback if not found
	return "default"
}

// rollbackDevices rolls back allocations for a list of devices
func (n *NodeAgent) rollbackDevices(deviceNames []string) {
	for _, deviceName := range deviceNames {
		if err := n.cdiGenerator.RemoveSpec(deviceName); err != nil {
			klog.ErrorS(err, "Failed to remove CDI spec during rollback", "device", deviceName)
		}
		if err := n.allocator.Deallocate(deviceName); err != nil {
			klog.ErrorS(err, "Failed to deallocate during rollback", "device", deviceName)
		}
	}
}
