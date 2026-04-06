#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [--boot] [command]}"
if [[ $# -gt 1 ]]; then
    shift
fi
if [[ "$STATE_FILE" != *.state ]]; then
  echo "Error: STATE_FILE must end in .state" >&2
  exit 1
fi
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi

source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

if ! mountpoint -q "$MOUNT_DIR"; then
    echo "$MOUNT_DIR is not a mountpoint"
    exit 1
fi

NSPAWN_OPTS=(
    -q                          # quiet
    -D "$MOUNT_DIR"             # OS directory
    -M box                      # Set hostname
    # --background=""             # disable nspawn terminal coloring
    # --resolv-conf=bind-stub     # https://man.archlinux.org/man/systemd-nspawn.1#Integration_Options
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
        NSPAWN_OPTS+=("$arg")
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

# Add --pipe if stdin is not a terminal
if [ ! -t 0 ]; then
    NSPAWN_OPTS+=("--pipe")
fi

if [[ "${COMMAND[0]}" = "/bin/bash" ]] || [[ "${COMMAND[0]}" = "bash" ]]; then
    echo "Starting shell..."
    if [ -t 0 ]; then
        echo "Type 'exit' or Ctrl+] three times to return to the host"
        echo ""
    fi
fi

exec systemd-nspawn "${NSPAWN_OPTS[@]}" "${COMMAND[@]}"
