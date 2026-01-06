.PHONY: build build-image load-image deploy undeploy clean test

VERSION ?= $(shell cat ../VERSION 2>/dev/null || echo "dev")
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
IMAGE_NAME := mock-accel-dra-driver
IMAGE_TAG := $(VERSION)

# Build the Go binary locally
build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
		-ldflags="-X 'github.com/fabiendupont/mock-device/dra-driver/pkg/version.Version=$(VERSION)' \
		          -X 'github.com/fabiendupont/mock-device/dra-driver/pkg/version.GitCommit=$(GIT_COMMIT)'" \
		-o bin/dra-driver \
		./cmd/dra-driver

# Build the container image
build-image:
	podman build \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) \
		-f Dockerfile .

# Load image into k3s containerd on both nodes
load-image: build-image
	podman save $(IMAGE_NAME):$(IMAGE_TAG) | \
		sshpass -p "test123" ssh -o StrictHostKeyChecking=no fedora@192.168.122.211 \
		"sudo k3s ctr images import -"
	podman save $(IMAGE_NAME):$(IMAGE_TAG) | \
		sshpass -p "test123" ssh -o StrictHostKeyChecking=no fedora@192.168.122.143 \
		"sudo k3s ctr images import -"

# Deploy to Kubernetes
deploy:
	kubectl apply -f deployments/rbac.yaml
	kubectl apply -f deployments/controller.yaml
	kubectl apply -f deployments/node-agent.yaml
	kubectl apply -f deployments/deviceclass.yaml

# Undeploy from Kubernetes
undeploy:
	kubectl delete -f deployments/deviceclass.yaml --ignore-not-found
	kubectl delete -f deployments/node-agent.yaml --ignore-not-found
	kubectl delete -f deployments/controller.yaml --ignore-not-found
	kubectl delete -f deployments/rbac.yaml --ignore-not-found

# Clean build artifacts
clean:
	rm -rf bin/

# Run tests
test:
	go test -v ./...

# Format code
fmt:
	go fmt ./...

# Run linter
lint:
	golangci-lint run

# Download dependencies
deps:
	go mod download
	go mod tidy

# Show version
version:
	@echo "Version: $(VERSION)"
	@echo "Commit:  $(GIT_COMMIT)"
