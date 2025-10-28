#!/bin/bash
set -euo pipefail

# Parse arguments
STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [command]}"
shift || true
COMMAND="${*:-/bin/bash}"

# Check if state file exists
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi

# Load state
echo "Loading state from $STATE_FILE..."
source "$STATE_FILE"

# Verify required variables
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

echo "Mount point: $MOUNT_DIR"
echo "Command: $COMMAND"
echo ""

# Setup chroot environment (always check actual mount status)
echo "Setting up chroot environment..."

# Mount proc, sys, dev if not already mounted
if ! mountpoint -q "$MOUNT_DIR/proc" 2>/dev/null; then
    echo "Mounting /proc..."
    sudo mount --bind /proc "$MOUNT_DIR/proc"
else
    echo "/proc already mounted"
fi

if ! mountpoint -q "$MOUNT_DIR/sys" 2>/dev/null; then
    echo "Mounting /sys..."
    sudo mount --bind /sys "$MOUNT_DIR/sys"
else
    echo "/sys already mounted"
fi

if ! mountpoint -q "$MOUNT_DIR/dev" 2>/dev/null; then
    echo "Mounting /dev..."
    sudo mount --bind /dev "$MOUNT_DIR/dev"
else
    echo "/dev already mounted"
fi

if ! mountpoint -q "$MOUNT_DIR/dev/pts" 2>/dev/null; then
    echo "Mounting /dev/pts..."
    sudo mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
else
    echo "/dev/pts already mounted"
fi

# Backup and setup resolv.conf
if [ ! -f "$MOUNT_DIR/etc/_resolv.conf" ] && [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
    echo "Backing up resolv.conf..."
    sudo cp "$MOUNT_DIR/etc/resolv.conf" "$MOUNT_DIR/etc/_resolv.conf"
    sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
else
    # Update resolv.conf even if backup exists (may be stale)
    if [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
        sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
    fi
fi

# Disable ld.so.preload if it exists (can break QEMU)
if [ -f "$MOUNT_DIR/etc/ld.so.preload" ] && [ ! -f "$MOUNT_DIR/etc/_ld.so.preload" ]; then
    echo "Disabling ld.so.preload..."
    sudo cp "$MOUNT_DIR/etc/ld.so.preload" "$MOUNT_DIR/etc/_ld.so.preload"
    sudo sh -c "echo > '$MOUNT_DIR/etc/ld.so.preload'"
fi

# Copy QEMU static binaries if available
if [ -f /usr/bin/qemu-arm-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-arm-static" ]; then
    echo "Copying qemu-arm-static..."
    sudo cp /usr/bin/qemu-arm-static "$MOUNT_DIR/usr/bin/"
fi

if [ -f /usr/bin/qemu-aarch64-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static" ]; then
    echo "Copying qemu-aarch64-static..."
    sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
fi

echo "Chroot environment ready"
echo ""

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo "Command exited with code: $exit_code"
    fi
}
trap cleanup EXIT

# Enter chroot
echo "=========================================="
echo "Entering chroot environment..."
echo "=========================================="
echo ""

# Detect architecture
ARCH=$(sudo chroot "$MOUNT_DIR" uname -m 2>/dev/null || echo "unknown")
case "$ARCH" in
    armv7l|armv6l)
        echo "Detected ARM 32-bit architecture"
        if [ ! -f /usr/bin/qemu-arm-static ]; then
            echo "Warning: qemu-arm-static not found, ARM emulation may not work"
            echo "Install with: sudo apt-get install qemu-user-static"
        fi
        ;;
    aarch64)
        echo "Detected ARM 64-bit architecture"
        if [ ! -f /usr/bin/qemu-aarch64-static ]; then
            echo "Warning: qemu-aarch64-static not found, ARM emulation may not work"
            echo "Install with: sudo apt-get install qemu-user-static"
        fi
        ;;
    *)
        echo "Architecture: $ARCH"
        ;;
esac
echo ""

# Execute command in chroot
if [ "$COMMAND" = "/bin/bash" ] || [ "$COMMAND" = "bash" ]; then
    echo "Starting interactive shell..."
    echo "Type 'exit' to return to host system"
    echo ""
    sudo chroot "$MOUNT_DIR" /bin/bash
else
    echo "Executing: $COMMAND"
    echo ""
    sudo chroot "$MOUNT_DIR" /bin/bash -c "$COMMAND"
fi

echo ""
echo "=========================================="
echo "Exited chroot environment"
echo "=========================================="
