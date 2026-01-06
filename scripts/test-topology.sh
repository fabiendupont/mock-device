#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Test mock-accel device topology
#

set -euo pipefail

MOCK_ACCEL_CLASS="/sys/class/mock-accel"
ERRORS=0

echo "Mock Accelerator Topology Test"
echo "==============================="
echo ""

# Check if class exists
if [[ ! -d "$MOCK_ACCEL_CLASS" ]]; then
    echo "ERROR: $MOCK_ACCEL_CLASS does not exist"
    echo "Is the mock_accel kernel module loaded?"
    exit 1
fi

# Enumerate devices
devices=("$MOCK_ACCEL_CLASS"/mock*)
if [[ ${#devices[@]} -eq 0 ]] || [[ ! -e "${devices[0]}" ]]; then
    echo "ERROR: No mock-accel devices found"
    exit 1
fi

echo "Found ${#devices[@]} mock-accel device(s)"
echo ""

# Group devices by NUMA node
declare -A numa_devices

for device_path in "${devices[@]}"; do
    device=$(basename "$device_path")

    # Read attributes
    uuid=$(cat "$device_path/uuid" 2>/dev/null || echo "N/A")
    memory_size=$(cat "$device_path/memory_size" 2>/dev/null || echo "0")
    numa_node=$(cat "$device_path/numa_node" 2>/dev/null || echo "-1")
    capabilities=$(cat "$device_path/capabilities" 2>/dev/null || echo "0x0")
    status=$(cat "$device_path/status" 2>/dev/null || echo "0x0")

    # Get PCI BDF if available
    pci_bdf="N/A"
    if [[ -L "$device_path/device" ]]; then
        pci_bdf=$(basename "$(readlink -f "$device_path/device")")
    fi

    # Convert memory to human-readable
    if [[ "$memory_size" -gt 0 ]]; then
        memory_gb=$((memory_size / 1024 / 1024 / 1024))
        memory_str="${memory_gb}GB"
    else
        memory_str="N/A"
    fi

    echo "Device: $device"
    echo "  PCI BDF:      $pci_bdf"
    echo "  UUID:         $uuid"
    echo "  Memory:       $memory_str"
    echo "  NUMA Node:    $numa_node"
    echo "  Capabilities: $capabilities"
    echo "  Status:       $status"
    echo ""

    # Validate
    if [[ "$numa_node" == "-1" ]]; then
        echo "  WARNING: NUMA node is -1 (not assigned)"
        ((ERRORS++)) || true
    fi

    if [[ "$uuid" == "N/A" ]] || [[ -z "$uuid" ]]; then
        echo "  WARNING: UUID is not set"
        ((ERRORS++)) || true
    fi

    # Add to NUMA grouping
    numa_devices[$numa_node]+="$device "
done

# Summary by NUMA node
echo "NUMA Topology Summary"
echo "---------------------"
for node in $(echo "${!numa_devices[@]}" | tr ' ' '\n' | sort -n); do
    devices_list="${numa_devices[$node]}"
    device_count=$(echo "$devices_list" | wc -w)
    echo "NUMA Node $node: $devices_list(${device_count} devices)"
done
echo ""

# Verify PCI numa_node matches
echo "PCI NUMA Verification"
echo "---------------------"
for device_path in "$MOCK_ACCEL_CLASS"/mock*; do
    device=$(basename "$device_path")

    if [[ -L "$device_path/device" ]]; then
        pci_path=$(readlink -f "$device_path/device")
        pci_numa=$(cat "$pci_path/numa_node" 2>/dev/null || echo "N/A")
        sysfs_numa=$(cat "$device_path/numa_node" 2>/dev/null || echo "N/A")

        if [[ "$pci_numa" == "$sysfs_numa" ]]; then
            echo "  $device: PCI NUMA ($pci_numa) == sysfs NUMA ($sysfs_numa) ✓"
        else
            echo "  $device: PCI NUMA ($pci_numa) != sysfs NUMA ($sysfs_numa) ✗"
            ((ERRORS++)) || true
        fi
    fi
done
echo ""

# Final result
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed!"
    exit 0
else
    echo "Tests completed with $ERRORS error(s)"
    exit 1
fi
