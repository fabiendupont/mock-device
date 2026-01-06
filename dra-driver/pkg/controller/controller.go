package controller

import (
	"context"
	"fmt"
	"sync"
	"time"

	resourcev1 "k8s.io/api/resource/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"

	"github.com/fabiendupont/mock-device/dra-driver/pkg/discovery"
)

// Controller manages device discovery and ResourceSlice publication
type Controller struct {
	clientset       *kubernetes.Clientset
	scanner         *discovery.DeviceScanner
	builder         *ResourceSliceBuilder
	rescanInterval  time.Duration
	ctx             context.Context
	reconcileMu     sync.Mutex // Protects concurrent reconciliation
	lastDeviceCount int        // Track device count for logging optimization
}

// NewController creates a new controller instance
func NewController(nodeName string, rescanInterval time.Duration) (*Controller, error) {
	// Create in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to create in-cluster config: %w", err)
	}

	// Create clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create clientset: %w", err)
	}

	scanner := discovery.NewDeviceScanner(nodeName)
	builder := NewResourceSliceBuilder(nodeName)

	return &Controller{
		clientset:      clientset,
		scanner:        scanner,
		builder:        builder,
		rescanInterval: rescanInterval,
		ctx:            context.Background(),
	}, nil
}

// Run starts the controller main loop
func (c *Controller) Run(stopCh <-chan struct{}) error {
	klog.Info("Starting mock-accel DRA controller")

	// Initial scan and publish
	if err := c.reconcile(); err != nil {
		klog.Errorf("Initial reconciliation failed: %v", err)
	}

	// Start periodic rescan
	ticker := time.NewTicker(c.rescanInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if err := c.reconcile(); err != nil {
				klog.Errorf("Reconciliation failed: %v", err)
			}
		case <-stopCh:
			klog.Info("Stopping controller")
			return nil
		}
	}
}

// reconcile scans for devices and updates ResourceSlices
func (c *Controller) reconcile() error {
	// Protect against concurrent reconciliation
	c.reconcileMu.Lock()
	defer c.reconcileMu.Unlock()

	klog.V(5).Info("Starting reconciliation")

	// Scan for devices
	devices, err := c.scanner.Scan()
	if err != nil {
		return fmt.Errorf("failed to scan devices: %w", err)
	}

	// Log device count changes at V(4), routine scans at V(5)
	if c.lastDeviceCount != len(devices) {
		klog.V(4).Infof("Device count changed: %d -> %d", c.lastDeviceCount, len(devices))
		c.lastDeviceCount = len(devices)
	} else {
		klog.V(5).Infof("Scanned %d devices (no change)", len(devices))
	}

	// Build ResourceSlices
	slices, err := c.builder.Build(devices)
	if err != nil {
		return fmt.Errorf("failed to build ResourceSlices: %w", err)
	}

	klog.V(5).Infof("Built %d ResourceSlices", len(slices))

	// Update ResourceSlices in API server
	for _, slice := range slices {
		if err := c.createOrUpdateResourceSlice(slice); err != nil {
			klog.Errorf("Failed to update ResourceSlice %s: %v", slice.Name, err)
		}
	}

	klog.V(5).Info("Reconciliation complete")
	return nil
}

// createOrUpdateResourceSlice creates or updates a ResourceSlice
func (c *Controller) createOrUpdateResourceSlice(slice *resourcev1.ResourceSlice) error {
	// Try to get existing slice
	existing, err := c.clientset.ResourceV1().ResourceSlices().Get(
		c.ctx,
		slice.Name,
		metav1.GetOptions{},
	)

	if err != nil {
		// Slice doesn't exist, create it
		_, err = c.clientset.ResourceV1().ResourceSlices().Create(
			c.ctx,
			slice,
			metav1.CreateOptions{},
		)
		if err != nil {
			return fmt.Errorf("failed to create ResourceSlice: %w", err)
		}
		klog.V(5).Infof("Created ResourceSlice %s", slice.Name)
		return nil
	}

	// Slice exists, update it
	slice.ResourceVersion = existing.ResourceVersion
	_, err = c.clientset.ResourceV1().ResourceSlices().Update(
		c.ctx,
		slice,
		metav1.UpdateOptions{},
	)
	if err != nil {
		return fmt.Errorf("failed to update ResourceSlice: %w", err)
	}
	klog.V(5).Infof("Updated ResourceSlice %s", slice.Name)
	return nil
}
