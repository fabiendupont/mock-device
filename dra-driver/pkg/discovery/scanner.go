package discovery

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"k8s.io/klog/v2"
)

const (
	defaultSysfsPath = "/sys/class/mock-accel"
)

// DiscoveredDevice represents a mock-accel device discovered from sysfs
type DiscoveredDevice struct {
	Name         string // "mock0", "mock0_vf0", etc.
	UUID         string
	MemorySize   int64
	NumaNode     int
	DeviceType   string // "pf" or "vf"
	PCIAddress   string // "0000:11:00.0"
	Capabilities uint32
	PhysFn       string // Parent PF name for VFs (e.g., "mock0")
}

// DeviceScanner scans sysfs for mock-accel devices
type DeviceScanner struct {
	sysfsPath string
	nodeName  string
	lastScan  map[string]*DiscoveredDevice // Reused map to reduce allocations
}

// NewDeviceScanner creates a new device scanner
func NewDeviceScanner(nodeName string) *DeviceScanner {
	return &DeviceScanner{
		sysfsPath: defaultSysfsPath,
		nodeName:  nodeName,
	}
}

// SetSysfsPath allows overriding the default sysfs path (for testing)
func (s *DeviceScanner) SetSysfsPath(path string) {
	s.sysfsPath = path
}

// Scan discovers all mock-accel devices on the system
func (s *DeviceScanner) Scan() (map[string]*DiscoveredDevice, error) {
	klog.V(5).Infof("Scanning for devices at %s", s.sysfsPath)

	// Check if sysfs path exists
	if _, err := os.Stat(s.sysfsPath); os.IsNotExist(err) {
		klog.Warningf("Sysfs path %s does not exist, no devices found", s.sysfsPath)
		return make(map[string]*DiscoveredDevice), nil
	}

	entries, err := os.ReadDir(s.sysfsPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read sysfs directory: %w", err)
	}

	// Initialize or clear the reused map
	if s.lastScan == nil {
		s.lastScan = make(map[string]*DiscoveredDevice, 16)
	} else {
		// Clear existing entries for reuse
		for k := range s.lastScan {
			delete(s.lastScan, k)
		}
	}

	for _, entry := range entries {
		devName := entry.Name()
		devPath := filepath.Join(s.sysfsPath, devName)

		// Check if the entry is a directory or a symlink (sysfs devices are often symlinks)
		info, err := os.Stat(devPath)
		if err != nil {
			klog.V(6).Infof("Skipping %s: stat error: %v", devName, err)
			continue
		}
		if !info.IsDir() {
			klog.V(6).Infof("Skipping %s: not a directory", devName)
			continue
		}

		dev, err := s.scanDevice(devName, devPath)
		if err != nil {
			klog.Errorf("Failed to scan device %s: %v", devName, err)
			continue
		}

		s.lastScan[devName] = dev
		klog.V(6).Infof("Discovered device %s: NUMA=%d, Type=%s, PCI=%s, UUID=%s",
			devName, dev.NumaNode, dev.DeviceType, dev.PCIAddress, dev.UUID)
	}

	klog.V(5).Infof("Discovered %d devices", len(s.lastScan))
	return s.lastScan, nil
}

// scanDevice reads properties of a single device
func (s *DeviceScanner) scanDevice(devName, devPath string) (*DiscoveredDevice, error) {
	dev := &DiscoveredDevice{
		Name: devName,
	}

	var err error

	// Read UUID
	dev.UUID, err = s.readRequiredSysfsString(devPath, "uuid", "uuid")
	if err != nil {
		return nil, err
	}

	// Read memory_size
	dev.MemorySize, err = s.readRequiredSysfsInt64(devPath, "memory_size", "memory_size")
	if err != nil {
		return nil, err
	}

	// Read capabilities (optional for backward compatibility)
	caps, err := readSysfsUint32(devPath, "capabilities")
	if err != nil {
		klog.V(6).Infof("Device %s has no capabilities attribute, defaulting to 0", devName)
		caps = 0
	}
	dev.Capabilities = caps

	// Read NUMA node
	dev.NumaNode, err = readNumaNode(devPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read numa_node: %w", err)
	}

	// Read PCI address
	dev.PCIAddress, err = readPCIAddress(devPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read PCI address: %w", err)
	}

	// Determine device type from naming convention
	dev.DeviceType = detectDeviceType(devName)

	// For VFs, extract parent PF name
	if dev.DeviceType == "vf" {
		dev.PhysFn = parsePhysFnName(devName)
	}

	return dev, nil
}

// readRequiredSysfsString reads a required sysfs string attribute with consistent error handling
func (s *DeviceScanner) readRequiredSysfsString(devPath, attr, displayName string) (string, error) {
	val, err := readSysfsString(devPath, attr)
	if err != nil {
		return "", fmt.Errorf("failed to read %s: %w", displayName, err)
	}
	return val, nil
}

// readRequiredSysfsInt64 reads a required sysfs int64 attribute with consistent error handling
func (s *DeviceScanner) readRequiredSysfsInt64(devPath, attr, displayName string) (int64, error) {
	val, err := readSysfsInt64(devPath, attr)
	if err != nil {
		return 0, fmt.Errorf("failed to read %s: %w", displayName, err)
	}
	return val, nil
}

// detectDeviceType determines if device is PF or VF based on naming
// VF naming convention: <pfname>_vf<N> where N is digits
// Examples: mock0_vf0, mock1_vf15
func detectDeviceType(name string) string {
	if idx := strings.LastIndex(name, "_vf"); idx != -1 {
		suffix := name[idx+3:] // After "_vf"
		// Verify suffix is all digits (valid VF number)
		if len(suffix) > 0 && isDigits(suffix) {
			return "vf"
		}
	}
	return "pf"
}

// isDigits checks if a string contains only digit characters
func isDigits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// parsePhysFnName extracts parent PF name from VF name
// e.g., "mock0_vf0" -> "mock0"
func parsePhysFnName(vfName string) string {
	parts := strings.Split(vfName, "_vf")
	if len(parts) >= 1 {
		return parts[0]
	}
	return ""
}

// extractPhysFnName is a public wrapper for parsePhysFnName (used by tests)
func extractPhysFnName(vfName string) string {
	return parsePhysFnName(vfName)
}
