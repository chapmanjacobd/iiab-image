#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [--boot] [command]}"
shift || true

if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi

source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

NSPAWN_OPTS=(
    -q                          # quiet
    -D "$MOUNT_DIR"             # OS directory
    -M box                      # Set hostname
    --background=""             # disable nspawn terminal coloring
    --resolv-conf=bind-stub     # https://man.archlinux.org/man/systemd-nspawn.1#Integration_Options
    # --resolv-conf=bind-host   # if not using systemd-resolved
    # --network-interface=      # temporarily removes interface from host
    # --network-veth            # easy if the host runs systemd-networkd
    # macvlan ipvlan https://wiki.archlinux.org/title/Systemd-networkd#MACVLAN_bridge
    # --network-zone=br0        # if the host uses systemd-networkd
    # --network-bridge=br0      # if you already have a bridge interface
)
COMMAND=("/bin/bash")

command_found=false
for arg in "$@"; do
    if ! $command_found && [[ "$arg" =~ ^--? ]]; then
        NSPAWN_OPTIONS+=("$arg")
    else
        if ! $command_found; then
            COMMAND=("$arg")
            command_found=true
        else  # append
            COMMAND+=("$arg")
        fi
    fi
done

if ! command -v systemd-nspawn &> /dev/null; then
    echo "Installing systemd-container..."
    apt-get update
    apt-get install -y systemd-container
fi

if [[ "${COMMAND[0]}" = "/bin/bash" ]] || [[ "${COMMAND[0]}" = "bash" ]]; then
    echo "Starting interactive shell..."
    echo "Type 'exit' or Ctrl+] three times to return to the host"
    echo ""
    exec systemd-nspawn "${NSPAWN_OPTS[@]}" "${FINAL_COMMAND[@]}"
else
    exec systemd-nspawn "${NSPAWN_OPTS[@]}" "${FINAL_COMMAND[@]}"
fi
