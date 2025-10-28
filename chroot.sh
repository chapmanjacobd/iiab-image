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

# Install systemd-nspawn if not available
if ! command -v systemd-nspawn &> /dev/null; then
    echo "Installing systemd-container..."
    sudo apt-get update
    sudo apt-get install -y systemd-container
fi

# Setup environment for ARM emulation
echo "Setting up ARM emulation environment..."

# Copy QEMU static binaries if available
if [ -f /usr/bin/qemu-arm-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-arm-static" ]; then
    echo "Copying qemu-arm-static..."
    sudo cp /usr/bin/qemu-arm-static "$MOUNT_DIR/usr/bin/"
fi

if [ -f /usr/bin/qemu-aarch64-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static" ]; then
    echo "Copying qemu-aarch64-static..."
    sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
fi

# Backup and setup resolv.conf
if [ ! -f "$MOUNT_DIR/etc/_resolv.conf" ] && [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
    echo "Backing up resolv.conf..."
    sudo cp "$MOUNT_DIR/etc/resolv.conf" "$MOUNT_DIR/etc/_resolv.conf"
    sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
else
    # Update resolv.conf (may be stale)
    if [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
        sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
    fi
fi

echo "Environment ready"
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

# Detect architecture
ARCH=$(sudo systemd-nspawn -q -D "$MOUNT_DIR" uname -m 2>/dev/null || echo "unknown")
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

# Enter container with systemd-nspawn
echo "=========================================="
echo "Entering container with systemd-nspawn..."
echo "=========================================="
echo ""

# Build systemd-nspawn options
NSPAWN_OPTS=(
    -q                      # Quiet
    -D "$MOUNT_DIR"         # Directory
    --resolv-conf=replace-host  # Use host DNS
    # --boot                   # Isolate systemd
)

# Execute command in container
if [ "$COMMAND" = "/bin/bash" ] || [ "$COMMAND" = "bash" ]; then
    echo "Starting interactive shell..."
    echo "Type 'exit' or Ctrl+] three times to return to host system"
    echo ""
    echo "Note: systemd services are available!"
    echo "  - systemctl status"
    echo "  - systemctl enable/disable <service>"
    echo "  - journalctl (for logs)"
    echo ""
    sudo systemd-nspawn "${NSPAWN_OPTS[@]}" /bin/bash
else
    echo "Executing: $COMMAND"
    echo ""
    sudo systemd-nspawn "${NSPAWN_OPTS[@]}" /bin/bash -c "$COMMAND"
fi

echo ""
echo "=========================================="
echo "Exited container"
echo "=========================================="
