#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Launch QEMU with mock-accel devices and configurable NUMA topology
#

set -euo pipefail

# Default values
NUMA_NODES=2
DEVICES_PER_NODE=2
MEMORY="16G"
CPUS=16
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
DISK_IMAGE="${DISK_IMAGE:-}"
KERNEL="${KERNEL:-}"
DRY_RUN=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --numa-nodes=*)
            NUMA_NODES="${1#*=}"
            ;;
        --devices-per-node=*)
            DEVICES_PER_NODE="${1#*=}"
            ;;
        --memory=*)
            MEMORY="${1#*=}"
            ;;
        --cpus=*)
            CPUS="${1#*=}"
            ;;
        --disk=*)
            DISK_IMAGE="${1#*=}"
            ;;
        --kernel=*)
            KERNEL="${1#*=}"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --numa-nodes=N        Number of NUMA nodes (default: 2)"
            echo "  --devices-per-node=N  Mock devices per NUMA node (default: 2)"
            echo "  --memory=SIZE         Total memory (default: 16G)"
            echo "  --cpus=N              Total CPUs (default: 16)"
            echo "  --disk=PATH           Disk image path"
            echo "  --kernel=PATH         Kernel image path (direct boot)"
            echo "  --dry-run             Print command without executing"
            echo ""
            echo "Environment variables:"
            echo "  QEMU_BIN              Path to qemu-system-x86_64"
            echo "  DISK_IMAGE            Default disk image path"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Calculate per-node resources
CPUS_PER_NODE=$((CPUS / NUMA_NODES))
# Convert memory to MB for calculation
MEMORY_MB=$(echo "$MEMORY" | sed 's/G/*1024/;s/M//' | bc)
MEMORY_PER_NODE=$((MEMORY_MB / NUMA_NODES))

# Build QEMU command
CMD=("$QEMU_BIN")

# Machine type
CMD+=(-machine q35,accel=kvm)
CMD+=(-cpu host)
CMD+=(-smp "cpus=$CPUS")
CMD+=(-m "$MEMORY")

# Enable KVM if available
if [[ -e /dev/kvm ]]; then
    CMD+=(-enable-kvm)
fi

# NUMA topology
for ((node=0; node<NUMA_NODES; node++)); do
    cpu_start=$((node * CPUS_PER_NODE))
    cpu_end=$((cpu_start + CPUS_PER_NODE - 1))
    CMD+=(-numa "node,nodeid=$node,cpus=$cpu_start-$cpu_end,mem=${MEMORY_PER_NODE}M")
done

# NUMA distances (simple model: local=10, remote=20)
for ((src=0; src<NUMA_NODES; src++)); do
    for ((dst=0; dst<NUMA_NODES; dst++)); do
        if [[ $src -eq $dst ]]; then
            CMD+=(-numa "dist,src=$src,dst=$dst,val=10")
        else
            CMD+=(-numa "dist,src=$src,dst=$dst,val=20")
        fi
    done
done

# PCIe topology with mock devices
device_idx=0
for ((node=0; node<NUMA_NODES; node++)); do
    bus_nr=$((180 + node * 20))

    # PCIe expander bus for this NUMA node
    CMD+=(-device "pxb-pcie,id=pcie.$((node+1)),bus_nr=$bus_nr,numa_node=$node")

    # Root ports and mock devices
    for ((dev=0; dev<DEVICES_PER_NODE; dev++)); do
        rp_id="rp$device_idx"
        mock_id="mock$device_idx"
        uuid="MOCK-$(printf '%04d' $device_idx)-0001-0000-$(printf '%012d' $device_idx)"

        CMD+=(-device "pcie-root-port,id=$rp_id,bus=pcie.$((node+1)),slot=$dev")
        CMD+=(-device "mock-accel,bus=$rp_id,id=$mock_id,uuid=$uuid")

        device_idx=$((device_idx + 1))
    done
done

# Display
CMD+=(-display none)
CMD+=(-serial mon:stdio)

# Networking (user mode with SSH forward)
CMD+=(-netdev user,id=net0,hostfwd=tcp::2222-:22)
CMD+=(-device virtio-net-pci,netdev=net0)

# Disk
if [[ -n "$DISK_IMAGE" ]]; then
    CMD+=(-drive "file=$DISK_IMAGE,format=qcow2,if=virtio")
fi

# Direct kernel boot
if [[ -n "$KERNEL" ]]; then
    CMD+=(-kernel "$KERNEL")
    CMD+=(-append "console=ttyS0 root=/dev/vda1")
fi

# Print or execute
if [[ $DRY_RUN -eq 1 ]]; then
    echo "QEMU command:"
    echo ""
    printf '%s \\\n' "${CMD[0]}"
    for ((i=1; i<${#CMD[@]}; i++)); do
        if [[ "${CMD[$i]}" == -* ]]; then
            printf '  %s' "${CMD[$i]}"
        else
            printf ' %s \\\n' "${CMD[$i]}"
        fi
    done
    echo ""
else
    echo "Starting QEMU with $NUMA_NODES NUMA nodes, $DEVICES_PER_NODE devices per node..."
    echo "Total devices: $((NUMA_NODES * DEVICES_PER_NODE))"
    echo ""
    exec "${CMD[@]}"
fi
