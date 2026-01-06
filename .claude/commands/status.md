# Status Command

Show the current status of the mock-device environment.

## Usage

```
/status
```

## Instructions

When the user runs this command, gather and display:

1. **Build Status**:
   - Check if QEMU is built: `ls ./qemu-src/build/qemu-system-x86_64`
   - Check if kernel module is built: `ls ./kernel-driver/mock_accel.ko`

2. **Runtime Status** (if on a system with mock devices):
   - Check if kernel module is loaded: `lsmod | grep mock_accel`
   - List discovered devices: `ls /sys/class/mock-accel/`
   - Show NUMA distribution

3. **QEMU Status** (if running):
   - Check for running QEMU process: `pgrep -a qemu`
   - Show configured topology

4. **Display format**:
   ```
   Mock Device Status
   ==================

   Build:
     QEMU:          ✓ Built (./qemu-src/build/)
     Kernel Module: ✓ Built (./kernel-driver/mock_accel.ko)

   Runtime:
     Module Loaded: ✓ mock_accel
     Devices:       4 devices found

   Topology:
     NUMA Node 0:   mock0, mock1
     NUMA Node 1:   mock2, mock3

   QEMU:
     Status:        Running (PID 12345)
     Configuration: 2 NUMA nodes, 2 devices/node
   ```

5. **If components are missing**, suggest next steps
