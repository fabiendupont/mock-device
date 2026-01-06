#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build QEMU with mock-accel device support
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
QEMU_VERSION="${QEMU_VERSION:-v10.1.0}"
QEMU_SRC_DIR="${QEMU_SRC_DIR:-$PROJECT_DIR/qemu-src}"
BUILD_DIR="$QEMU_SRC_DIR/build"
JOBS="${JOBS:-$(nproc)}"

echo "=== Building QEMU with mock-accel device ==="
echo "QEMU version: $QEMU_VERSION"
echo "Source dir:   $QEMU_SRC_DIR"
echo "Build dir:    $BUILD_DIR"
echo "Jobs:         $JOBS"
echo ""

# Clone QEMU if not present
if [[ ! -d "$QEMU_SRC_DIR" ]]; then
    echo "Cloning QEMU..."
    git clone --depth 1 --branch "$QEMU_VERSION" \
        https://gitlab.com/qemu-project/qemu.git "$QEMU_SRC_DIR"
else
    echo "QEMU source already exists at $QEMU_SRC_DIR"
fi

# Copy mock-accel device files
echo "Installing mock-accel device..."
cp "$PROJECT_DIR/qemu-device/mock-accel.c" "$QEMU_SRC_DIR/hw/misc/"

# Add device to Kconfig if not already present
KCONFIG_FILE="$QEMU_SRC_DIR/hw/misc/Kconfig"
if ! grep -q "MOCK_ACCEL" "$KCONFIG_FILE"; then
    echo "Adding mock-accel to Kconfig..."
    cat >> "$KCONFIG_FILE" << 'EOF'

config MOCK_ACCEL
    bool
    default y
    depends on PCI
EOF
fi

# Add device to meson.build if not already present
MESON_FILE="$QEMU_SRC_DIR/hw/misc/meson.build"
if ! grep -q "mock-accel" "$MESON_FILE"; then
    echo "Adding mock-accel to meson.build..."
    # Add before the last line (which is typically empty or a comment)
    sed -i "/^system_ss.add/a system_ss.add(when: 'CONFIG_MOCK_ACCEL', if_true: files('mock-accel.c'))" "$MESON_FILE"
fi

# Configure QEMU if not already configured
if [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
    echo "Configuring QEMU..."
    mkdir -p "$BUILD_DIR"
    cd "$QEMU_SRC_DIR"
    ./configure \
        --prefix="$PROJECT_DIR/qemu-install" \
        --target-list=x86_64-softmmu \
        --enable-kvm \
        --disable-docs \
        --disable-user \
        --disable-gtk \
        --disable-sdl \
        --disable-spice \
        --disable-guest-agent
else
    echo "QEMU already configured"
fi

# Build QEMU
echo "Building QEMU (this may take a while)..."
cd "$BUILD_DIR"
ninja -j "$JOBS"

# Verify mock-accel device is available
echo ""
echo "Verifying mock-accel device..."
if "$BUILD_DIR/qemu-system-x86_64" -device help 2>&1 | grep -q "mock-accel"; then
    echo "✓ mock-accel device is available!"
    "$BUILD_DIR/qemu-system-x86_64" -device mock-accel,help
else
    echo "✗ mock-accel device not found!"
    echo "Check build logs for errors."
    exit 1
fi

echo ""
echo "=== Build complete ==="
echo ""
echo "QEMU binary: $BUILD_DIR/qemu-system-x86_64"
echo ""
echo "To use this QEMU, either:"
echo "  1. Set QEMU_BIN=$BUILD_DIR/qemu-system-x86_64"
echo "  2. Run: ninja -C $BUILD_DIR install"
echo ""
echo "Test with:"
echo "  $BUILD_DIR/qemu-system-x86_64 -device mock-accel,help"
