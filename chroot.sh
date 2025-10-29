#!/bin/bash
set -euo pipefail

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [--boot] [command]}"
shift || true

# Initialize variables
BOOT_FLAG=""
ARGS_FOR_COMMAND=()

# Process remaining arguments for flags and command
for arg in "$@"; do
    case "$arg" in
        --boot)
            BOOT_FLAG="--boot"
            ;;
        *)
            # Collect non-flag arguments to form the COMMAND
            ARGS_FOR_COMMAND+=("$arg")
            ;;
    esac
done
COMMAND="${ARGS_FOR_COMMAND[*]:-/bin/bash}"

if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi

# Load state
source "$STATE_FILE"

# Verify required variables
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

if ! command -v systemd-nspawn &> /dev/null; then
    echo "Installing systemd-container..."
    sudo apt-get update
    sudo apt-get install -y systemd-container
fi

if [ -f /usr/bin/qemu-arm-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-arm-static" ]; then
    echo "Copying qemu-arm-static..."
    sudo cp /usr/bin/qemu-arm-static "$MOUNT_DIR/usr/bin/"
fi
if [ -f /usr/bin/qemu-aarch64-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static" ]; then
    echo "Copying qemu-aarch64-static..."
    sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
fi

if [ ! -f "$MOUNT_DIR/etc/_resolv.conf" ] && [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
    sudo cp "$MOUNT_DIR/etc/resolv.conf" "$MOUNT_DIR/etc/_resolv.conf"
    sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
else  # Update resolv.conf (may be stale)
    if [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
        sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
    fi
fi

NSPAWN_OPTS=(
    -q                          # quiet
    -D "$MOUNT_DIR"             # OS directory
    --background=""             # disable nspawn terminal coloring
    --network-veth              # use private networking to prevent sshd port-in-use conflict
                                # alternatively pass in an existing network bridge interface
                                # example: --network-bridge=br0
    --resolv-conf=replace-host  # but use host DNS
    ${BOOT_FLAG}                # use init system
)

if [ "$COMMAND" = "/bin/bash" ] || [ "$COMMAND" = "bash" ]; then
    echo "Starting interactive shell..."
    echo "Type 'exit' or Ctrl+] three times to return to host system"
    echo ""
    exec sudo systemd-nspawn "${NSPAWN_OPTS[@]}" /bin/bash
else
    exec sudo systemd-nspawn "${NSPAWN_OPTS[@]}" /bin/bash -c "$COMMAND"
fi
