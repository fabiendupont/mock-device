# Build Command

Build the mock-device components.

## Usage

```
/build [component]
```

## Components

- `qemu` - Build QEMU with mock-accel device
- `driver` - Build the kernel module
- `all` - Build everything (default)

## Instructions

When the user runs this command:

1. **For `qemu` or `all`**:
   - Check if QEMU source exists in `./qemu-src/`
   - If not, suggest running `./scripts/build-qemu.sh`
   - If exists, run `make -C qemu-src/build -j$(nproc)`

2. **For `driver` or `all`**:
   - Check kernel headers are installed: `ls /lib/modules/$(uname -r)/build`
   - Run `make -C kernel-driver/`
   - Report any build errors

3. **Report results**:
   - List built artifacts
   - Suggest next steps (e.g., run QEMU, load module)
