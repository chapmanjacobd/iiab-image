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
for qemu_bin in /usr/bin/qemu-*-static; do
    if [ -f "$qemu_bin" ]; then
        target_bin="$MOUNT_DIR/usr/bin/${qemu_bin##*/}"
        if [ ! -f "$target_bin" ]; then
            sudo cp "$qemu_bin" "$target_bin"
        fi
    fi
done

NSPAWN_OPTS=(
    -q                          # quiet
    -D "$MOUNT_DIR"             # OS directory
    --background=""             # disable nspawn terminal coloring
    --network-veth              # use private networking to prevent sshd port-in-use conflict
                                # alternatively pass in an existing network bridge interface
                                # example: --network-bridge=br0
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
