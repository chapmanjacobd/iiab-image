#!/bin/bash
set -euo pipefail

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [password]}"
PASSWORD="${2:-changeme}"

# Check if state file exists
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi
source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

if ! command -v systemd-nspawn &> /dev/null; then
    echo "Installing systemd-container..."
    sudo apt-get update
    sudo apt-get install -y systemd-container
fi
if [ -f /usr/bin/qemu-aarch64-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static" ]; then
    sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
fi

echo "root:${PASSWORD}" | sudo systemd-nspawn -q -D "$MOUNT_DIR" --console=pipe chpasswd
