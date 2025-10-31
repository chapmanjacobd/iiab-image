#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [--boot] [command]}"
shift || true

BOOT_FLAG=""
ARGS_FOR_COMMAND=()
for arg in "$@"; do
    case "$arg" in
        --boot)
            BOOT_FLAG="--boot"
            ;;
        *)
            ARGS_FOR_COMMAND+=("$arg")
            ;;
    esac
done
COMMAND="${ARGS_FOR_COMMAND[*]:-/bin/bash}"

if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi

source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

if ! command -v systemd-nspawn &> /dev/null; then
    echo "Installing systemd-container..."
    apt-get update
    apt-get install -y systemd-container
fi

shopt -s nullglob
for qemu_bin in /usr/bin/qemu-*-static; do
    target_bin="$MOUNT_DIR/usr/bin/${qemu_bin##*/}"
    if [ ! -f "$target_bin" ]; then
        cp "$qemu_bin" "$target_bin"
    fi
done
shopt -u nullglob

NSPAWN_OPTS=(
    -q                          # quiet
    -D "$MOUNT_DIR"             # OS directory
    -M box                      # Set hostname
    --background=""             # disable nspawn terminal coloring
    # --network-bridge=br0
    ${BOOT_FLAG}                # use init system
)

if [ "$COMMAND" = "/bin/bash" ] || [ "$COMMAND" = "bash" ]; then
    echo "Starting interactive shell..."
    echo "Type 'exit' or Ctrl+] three times to return to host system"
    echo ""
    exec systemd-nspawn "${NSPAWN_OPTS[@]}" /bin/bash
else
    exec systemd-nspawn "${NSPAWN_OPTS[@]}" /bin/bash -c "$COMMAND"
fi
