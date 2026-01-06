package nodeagent

import (
	"context"
	"fmt"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"
)

// StartPlugin starts the kubelet DRA plugin using the kubeletplugin helper
func (n *NodeAgent) StartPlugin(ctx context.Context, nodeName, pluginDir string) error {
	klog.InfoS("Starting DRA plugin", "driver", n.driverName, "node", nodeName, "pluginDir", pluginDir)

	// Create in-cluster Kubernetes client
	config, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("failed to create in-cluster config: %w", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("failed to create clientset: %w", err)
	}

	// Start the kubelet plugin with required options
	// The kubelet expects plugins in:
	// - /var/lib/kubelet/plugins_registry for registration
	// - /var/lib/kubelet/plugins/<driver-name> for driver socket (dra.sock)
	helper, err := kubeletplugin.Start(
		ctx,
		n, // DRAPlugin implementation
		kubeletplugin.DriverName(n.driverName),
		kubeletplugin.KubeClient(clientset),
		kubeletplugin.NodeName(nodeName),
		kubeletplugin.RegistrarDirectoryPath("/var/lib/kubelet/plugins_registry"),
		kubeletplugin.PluginDataDirectoryPath(pluginDir),
	)
	if err != nil {
		return fmt.Errorf("failed to start kubelet plugin: %w", err)
	}

	klog.InfoS("DRA plugin started successfully")

	// Wait for context cancellation
	<-ctx.Done()
	klog.InfoS("Shutting down DRA plugin")

	// Stop the helper (this blocks until shutdown is complete)
	helper.Stop()

	klog.InfoS("DRA plugin stopped")
	return nil
}
