# QEMU Command

Launch QEMU with mock-accel devices and configurable topology.

## Usage

```
/qemu [options]
```

## Options

- `--numa-nodes=N` - Number of NUMA nodes (default: 2)
- `--devices-per-node=N` - Mock devices per NUMA node (default: 2)
- `--memory=SIZE` - Total memory (default: 16G)
- `--cpus=N` - Total CPUs (default: 16)
- `--dry-run` - Show command without executing

## Instructions

When the user runs this command:

1. **Parse options** from the argument string (e.g., `/qemu --numa-nodes=4`)

2. **Generate QEMU command** with:
   - q35 machine type
   - NUMA topology based on `--numa-nodes`
   - PCIe expander buses for each NUMA node
   - Root ports and mock-accel devices based on `--devices-per-node`
   - KVM acceleration if available

3. **Example command generation** for `--numa-nodes=2 --devices-per-node=2`:
   ```bash
   qemu-system-x86_64 \
     -machine q35,accel=kvm \
     -cpu host \
     -smp cpus=16 \
     -m 16G \
     -numa node,nodeid=0,cpus=0-7,mem=8G \
     -numa node,nodeid=1,cpus=8-15,mem=8G \
     -device pxb-pcie,id=pcie.1,bus_nr=180,numa_node=0 \
     -device pcie-root-port,id=rp0,bus=pcie.1,slot=0 \
     -device pcie-root-port,id=rp1,bus=pcie.1,slot=1 \
     -device mock-accel,bus=rp0,id=mock0,uuid=MOCK-0000-0001 \
     -device mock-accel,bus=rp1,id=mock1,uuid=MOCK-0000-0002 \
     -device pxb-pcie,id=pcie.2,bus_nr=200,numa_node=1 \
     -device pcie-root-port,id=rp2,bus=pcie.2,slot=0 \
     -device pcie-root-port,id=rp3,bus=pcie.2,slot=1 \
     -device mock-accel,bus=rp2,id=mock2,uuid=MOCK-0000-0003 \
     -device mock-accel,bus=rp3,id=mock3,uuid=MOCK-0000-0004 \
     ...
   ```

4. **If `--dry-run`**: Show the command
   **Otherwise**: Execute via `./scripts/run-qemu.sh` with appropriate args

5. **Provide instructions** for loading kernel module and verifying topology
