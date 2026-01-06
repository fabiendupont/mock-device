package discovery

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// readSysfsString reads a string value from a sysfs attribute
func readSysfsString(devPath, attr string) (string, error) {
	attrPath := filepath.Join(devPath, attr)
	data, err := os.ReadFile(attrPath)
	if err != nil {
		return "", fmt.Errorf("failed to read %s: %w", attrPath, err)
	}
	return strings.TrimSpace(string(data)), nil
}

// readSysfsInt64 reads an int64 value from a sysfs attribute
func readSysfsInt64(devPath, attr string) (int64, error) {
	str, err := readSysfsString(devPath, attr)
	if err != nil {
		return 0, err
	}
	val, err := strconv.ParseInt(str, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse %s as int64: %w", attr, err)
	}
	return val, nil
}

// readSysfsUint32 reads a uint32 value from a sysfs attribute (supports hex)
func readSysfsUint32(devPath, attr string) (uint32, error) {
	str, err := readSysfsString(devPath, attr)
	if err != nil {
		return 0, err
	}

	// Handle both decimal and hex (0x prefix)
	base := 10
	if strings.HasPrefix(str, "0x") || strings.HasPrefix(str, "0X") {
		base = 16
		str = str[2:]
	}

	val, err := strconv.ParseUint(str, base, 32)
	if err != nil {
		return 0, fmt.Errorf("failed to parse %s as uint32: %w", attr, err)
	}
	return uint32(val), nil
}

// readNumaNode reads the NUMA node from the device symlink
func readNumaNode(devPath string) (int, error) {
	// device symlink points to PCI device path
	deviceLink := filepath.Join(devPath, "device")
	numaPath := filepath.Join(deviceLink, "numa_node")

	data, err := os.ReadFile(numaPath)
	if err != nil {
		return 0, fmt.Errorf("failed to read numa_node: %w", err)
	}

	numaNode, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0, fmt.Errorf("failed to parse numa_node: %w", err)
	}
	return numaNode, nil
}

// readPCIAddress extracts the PCI address from the device symlink
func readPCIAddress(devPath string) (string, error) {
	// device symlink points to PCI device path
	// e.g., /sys/class/mock-accel/mock0/device -> ../../../0000:11:00.0
	deviceLink := filepath.Join(devPath, "device")
	target, err := os.Readlink(deviceLink)
	if err != nil {
		return "", fmt.Errorf("failed to read device symlink: %w", err)
	}

	// Extract PCI address from path (last component)
	pciAddr := filepath.Base(target)
	return pciAddr, nil
}
