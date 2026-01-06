# Test Command

Run tests for the mock-device project.

## Usage

```
/test [suite]
```

## Test Suites

- `topology` - Verify sysfs topology matches expected NUMA layout
- `driver` - Test kernel driver functionality
- `all` - Run all tests (default)

## Instructions

When the user runs this command:

1. **Check prerequisites**:
   - For host tests: Check if QEMU is running with mock devices
   - For in-guest tests: Check if kernel module is loaded

2. **For `topology` tests**:
   - Read `/sys/class/mock-accel/*/numa_node` for each device
   - Verify devices are distributed across expected NUMA nodes
   - Check `/sys/bus/pci/devices/*/numa_node` matches
   - Report topology summary:
     ```
     NUMA Node 0: mock0, mock1
     NUMA Node 1: mock2, mock3
     ```

3. **For `driver` tests**:
   - Verify all expected sysfs attributes exist
   - Check attribute values are valid (uuid format, memory_size > 0)
   - Test read/write of status register if applicable

4. **Report results**:
   - Pass/fail for each test
   - Summary of topology discovered
   - Any discrepancies from expected configuration

## Example Output

```
Topology Test Results:
  ✓ Found 4 mock-accel devices
  ✓ NUMA Node 0: mock0 (0000:b4:00.0), mock1 (0000:b4:01.0)
  ✓ NUMA Node 1: mock2 (0000:c8:00.0), mock3 (0000:c8:01.0)
  ✓ All devices have valid UUIDs
  ✓ All devices report 16GB memory

Driver Test Results:
  ✓ Kernel module loaded: mock_accel
  ✓ Device class exists: /sys/class/mock-accel
  ✓ All sysfs attributes accessible

All tests passed!
```
