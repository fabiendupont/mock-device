package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/klog/v2"

	"github.com/fabiendupont/mock-device/dra-driver/pkg/controller"
	"github.com/fabiendupont/mock-device/dra-driver/pkg/nodeagent"
	"github.com/fabiendupont/mock-device/dra-driver/pkg/version"
)

var (
	mode           = flag.String("mode", "", "Operation mode: 'controller' or 'node-agent'")
	driverName     = flag.String("driver-name", "mock-accel.example.com", "DRA driver name")
	pluginSocket   = flag.String("plugin-socket", "/var/lib/kubelet/plugins/mock-accel.example.com/dra.sock", "Path to kubelet plugin socket (node-agent mode)")
	rescanInterval = flag.Duration("rescan-interval", 30*time.Second, "Interval between device rescans (controller mode)")
	showVersion    = flag.Bool("version", false, "Show version and exit")
)

func main() {
	klog.InitFlags(nil)
	flag.Parse()

	if *showVersion {
		fmt.Printf("mock-accel DRA driver version %s\n", version.GetFullVersion())
		os.Exit(0)
	}

	if *mode == "" {
		klog.Fatal("--mode flag is required (controller or node-agent)")
	}

	// Get node name from environment
	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		klog.Fatal("NODE_NAME environment variable must be set")
	}

	klog.Infof("Starting mock-accel DRA driver in %s mode", *mode)
	klog.Infof("Version: %s", version.GetFullVersion())
	klog.Infof("Driver name: %s", *driverName)
	klog.Infof("Node name: %s", nodeName)

	// Setup signal handling
	stopCh := setupSignalHandler()

	var err error
	switch *mode {
	case "controller":
		err = runController(nodeName, stopCh)
	case "node-agent":
		err = runNodeAgent(nodeName, stopCh)
	default:
		klog.Fatalf("Invalid mode: %s (must be 'controller' or 'node-agent')", *mode)
	}

	if err != nil {
		klog.Fatalf("Error running %s: %v", *mode, err)
	}

	klog.Info("Exiting")
}

// runController runs the controller mode
func runController(nodeName string, stopCh <-chan struct{}) error {
	klog.Info("Running in controller mode")

	ctrl, err := controller.NewController(nodeName, *rescanInterval)
	if err != nil {
		return fmt.Errorf("failed to create controller: %w", err)
	}

	return ctrl.Run(stopCh)
}

// runNodeAgent runs the node agent mode
func runNodeAgent(nodeName string, stopCh <-chan struct{}) error {
	klog.Info("Running in node-agent mode")

	agent := nodeagent.NewNodeAgent(*driverName)

	// Create context that cancels when stop signal is received
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		<-stopCh
		klog.Info("Received stop signal, canceling context")
		cancel()
	}()

	return agent.StartPlugin(ctx, nodeName, *pluginSocket)
}

// setupSignalHandler registers for SIGTERM and SIGINT and returns a stop channel
func setupSignalHandler() <-chan struct{} {
	stop := make(chan struct{})
	c := make(chan os.Signal, 2)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		close(stop)
		<-c
		os.Exit(1) // Second signal, exit immediately
	}()
	return stop
}
