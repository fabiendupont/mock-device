package nodeagent

import (
	"fmt"
	"os"
	"path/filepath"

	"k8s.io/klog/v2"
)

const (
	// Status register values
	StatusFree      = "0"
	StatusAllocated = "1"

	defaultSysfsPath = "/sys/class/mock-accel"
)

// SysfsAllocator manages device allocation via sysfs status register
type SysfsAllocator struct {
	sysfsPath string
}

// NewSysfsAllocator creates a new sysfs allocator
func NewSysfsAllocator() *SysfsAllocator {
	return &SysfsAllocator{
		sysfsPath: defaultSysfsPath,
	}
}

// SetSysfsPath allows overriding the default sysfs path (for testing)
func (a *SysfsAllocator) SetSysfsPath(path string) {
	a.sysfsPath = path
}

// Allocate marks a device as allocated by writing to its status register
func (a *SysfsAllocator) Allocate(deviceName string) error {
	statusPath := filepath.Join(a.sysfsPath, deviceName, "status")

	klog.V(5).Infof("Allocating device %s (writing %s to %s)", deviceName, StatusAllocated, statusPath)

	err := os.WriteFile(statusPath, []byte(StatusAllocated), 0644)
	if err != nil {
		return fmt.Errorf("failed to write status for device %s: %w", deviceName, err)
	}

	klog.V(4).Infof("Successfully allocated device %s", deviceName)
	return nil
}

// Deallocate marks a device as free by writing to its status register
func (a *SysfsAllocator) Deallocate(deviceName string) error {
	statusPath := filepath.Join(a.sysfsPath, deviceName, "status")

	klog.V(5).Infof("Deallocating device %s (writing %s to %s)", deviceName, StatusFree, statusPath)

	err := os.WriteFile(statusPath, []byte(StatusFree), 0644)
	if err != nil {
		return fmt.Errorf("failed to write status for device %s: %w", deviceName, err)
	}

	klog.V(4).Infof("Successfully deallocated device %s", deviceName)
	return nil
}

// GetStatus reads the current allocation status of a device
func (a *SysfsAllocator) GetStatus(deviceName string) (string, error) {
	statusPath := filepath.Join(a.sysfsPath, deviceName, "status")

	data, err := os.ReadFile(statusPath)
	if err != nil {
		return "", fmt.Errorf("failed to read status for device %s: %w", deviceName, err)
	}

	status := string(data)
	klog.V(5).Infof("Device %s status: %s", deviceName, status)
	return status, nil
}
