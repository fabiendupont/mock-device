package nodeagent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	cdispec "tags.cncf.io/container-device-interface/specs-go"
	"k8s.io/klog/v2"
)

const (
	cdiVendor  = "example.com/mock-accel"  // CDI kind format: vendor/class
	cdiVersion = "0.8.0"
	cdiDir     = "/var/run/cdi"
)

// CDIGenerator generates Container Device Interface specs
type CDIGenerator struct {
	sysfsPath string
	cdiDir    string
}

// NewCDIGenerator creates a new CDI spec generator
func NewCDIGenerator() *CDIGenerator {
	return &CDIGenerator{
		sysfsPath: defaultSysfsPath,
		cdiDir:    cdiDir,
	}
}

// SetCDIDir allows overriding the default CDI directory (for testing)
func (g *CDIGenerator) SetCDIDir(dir string) {
	g.cdiDir = dir
}

// GenerateSpec creates a CDI spec for a device and writes it to disk
func (g *CDIGenerator) GenerateSpec(deviceName string) (string, error) {
	klog.V(5).Infof("Generating CDI spec for device %s", deviceName)

	// Read device information from sysfs
	devPath := filepath.Join(g.sysfsPath, deviceName)

	uuid, err := g.readSysfsAttr(devPath, "uuid")
	if err != nil {
		return "", fmt.Errorf("failed to read uuid: %w", err)
	}

	pciAddr, err := g.readPCIAddress(devPath)
	if err != nil {
		return "", fmt.Errorf("failed to read PCI address: %w", err)
	}

	// Create CDI spec
	spec := &cdispec.Spec{
		Version: cdiVersion,
		Kind:    cdiVendor,
		Devices: []cdispec.Device{
			{
				Name: deviceName,
				ContainerEdits: cdispec.ContainerEdits{
					Env: []string{
						fmt.Sprintf("MOCK_ACCEL_UUID=%s", uuid),
						fmt.Sprintf("MOCK_ACCEL_PCI=%s", pciAddr),
						fmt.Sprintf("MOCK_ACCEL_DEVICE=%s", deviceName),
					},
					Mounts: []*cdispec.Mount{
						{
							HostPath:      devPath,
							ContainerPath: devPath,
							Options:       []string{"ro", "bind"},
						},
					},
				},
			},
		},
	}

	// Write CDI spec to file
	cdiPath := g.getCDIPath(deviceName)
	if err := g.writeCDISpec(spec, cdiPath); err != nil {
		return "", fmt.Errorf("failed to write CDI spec: %w", err)
	}

	// Return CDI device reference (format: vendor/class=device per CDI spec)
	cdiDevice := fmt.Sprintf("%s=%s", cdiVendor, deviceName)
	klog.V(4).Infof("Generated CDI spec for device %s: %s", deviceName, cdiDevice)
	return cdiDevice, nil
}

// RemoveSpec removes the CDI spec file for a device
func (g *CDIGenerator) RemoveSpec(deviceName string) error {
	cdiPath := g.getCDIPath(deviceName)

	klog.V(5).Infof("Removing CDI spec %s", cdiPath)

	if err := os.Remove(cdiPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove CDI spec: %w", err)
	}

	klog.V(4).Infof("Removed CDI spec for device %s", deviceName)
	return nil
}

// getCDIPath returns the path to the CDI spec file for a device
func (g *CDIGenerator) getCDIPath(deviceName string) string {
	// CDI spec filename format: <vendor>-<device>.json
	// Replace slash in vendor/class with underscore for filename
	vendorFilename := strings.ReplaceAll(cdiVendor, "/", "_")
	filename := fmt.Sprintf("%s-%s.json", vendorFilename, deviceName)
	return filepath.Join(g.cdiDir, filename)
}

// writeCDISpec writes a CDI spec to disk as JSON
func (g *CDIGenerator) writeCDISpec(spec *cdispec.Spec, path string) error {
	// Ensure CDI directory exists
	if err := os.MkdirAll(g.cdiDir, 0755); err != nil {
		return fmt.Errorf("failed to create CDI directory: %w", err)
	}

	// Marshal spec to JSON
	data, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal CDI spec: %w", err)
	}

	// Write to file
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("failed to write CDI spec file: %w", err)
	}

	klog.V(5).Infof("Wrote CDI spec to %s", path)
	return nil
}

// readSysfsAttr reads a sysfs attribute
func (g *CDIGenerator) readSysfsAttr(devPath, attr string) (string, error) {
	attrPath := filepath.Join(devPath, attr)
	data, err := os.ReadFile(attrPath)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// readPCIAddress reads the PCI address from the device symlink
func (g *CDIGenerator) readPCIAddress(devPath string) (string, error) {
	deviceLink := filepath.Join(devPath, "device")
	target, err := os.Readlink(deviceLink)
	if err != nil {
		return "", err
	}
	return filepath.Base(target), nil
}
