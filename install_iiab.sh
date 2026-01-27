#!/usr/bin/env bash
set -euo pipefail
source ./utils.sh

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file>}"
IIAB_YML_SOURCE="${2:-}"

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

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

IIAB_YML_DEST="$MOUNT_DIR/etc/iiab/local_vars.yml"
mkdir -p $(dirname "$IIAB_YML_DEST")
if [[ "$IIAB_YML_SOURCE" =~ ^https?:// ]]; then
    if download_file "$IIAB_YML_SOURCE" "$IIAB_YML_DEST"; then
        echo "Downloaded **$IIAB_YML_SOURCE** to **$IIAB_YML_DEST**"
    else
        echo "Error: Download failed: $IIAB_YML_SOURCE" >&2
        exit 1
    fi
elif [ -f "$IIAB_YML_SOURCE" ]; then
    cp -f "$IIAB_YML_SOURCE" "$IIAB_YML_DEST"
    echo "Copied **$IIAB_YML_SOURCE** to **$IIAB_YML_DEST**"
else
    echo "Error: '$IIAB_YML_SOURCE' is neither a file nor a URL." >&2
    exit 1
fi

if ! command -v expect &>/dev/null; then
    echo "Installing expect for automation..."
    apt-get update
    apt-get install -y expect
fi
if ! command -v systemd-nspawn &> /dev/null; then
    echo "Installing systemd-container..."
    apt-get update
    apt-get install -y systemd-container
fi

if ! systemctl is-active --quiet systemd-networkd; then
    echo "Starting systemd-networkd for container networking..."
    systemctl start systemd-networkd
fi

if ! systemctl is-active --quiet systemd-resolved; then
    echo "Starting systemd-resolved for DNS management..."
    systemctl start systemd-resolved
fi

# Enable IPv4 forwarding for NAT/Internet access
sysctl -w net.ipv4.ip_forward=1

# Ensure NAT (Masquerading) is enabled on the host for the container network
# systemd-nspawn usually uses 192.168.59.0/24 or similar for veth
if ! command -v iptables &> /dev/null; then
    apt-get update && apt-get install -y iptables
fi
iptables -t nat -A POSTROUTING -j MASQUERADE

systemd-firstboot --root="$MOUNT_DIR" --delete-root-password --force

# Manually set DNS to avoid host loopback/127.0.0.53 issues
mkdir -p "$MOUNT_DIR/etc"
echo "nameserver 8.8.8.8" > "$MOUNT_DIR/etc/resolv.conf"
echo "nameserver 1.1.1.1" >> "$MOUNT_DIR/etc/resolv.conf"

cleanup() {
    echo "Attempting cleanup of temporary files..." >&2
    if [ -n "${EXPECT_SCRIPT:-}" ] && [ -f "$EXPECT_SCRIPT" ]; then
        rm -f "$EXPECT_SCRIPT"
    fi
    if [ -n "${IIAB_EXPECT_SCRIPT:-}" ] && [ -f "$IIAB_EXPECT_SCRIPT" ]; then
        rm -f "$IIAB_EXPECT_SCRIPT"
    fi
    pgrep -fa "$MOUNT_DIR" || true
}
trap cleanup EXIT

PRESET_SCRIPT="$MOUNT_DIR/root/install_preset.sh"
cat > "$PRESET_SCRIPT" << EOF
#!/bin/bash
set -euo pipefail

cd /opt/iiab/iiab-admin-console

scripts/get_kiwix_catalog
scripts/get_oer2go_catalog

iiab-cmdsrv-ctl 'INST-PRESETS {"preset_id":"test"}'

EOF
chmod +x "$PRESET_SCRIPT"

EXPECT_SCRIPT=$(mktemp)
cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set timeout 7200

set MOUNT_DIR "$MOUNT_DIR"

# https://quantum5.ca/2025/03/22/whirlwind-tour-of-systemd-nspawn-containers/#networking
# --network-veth creates a separate network namespace with a virtual ethernet link
# --resolv-conf=off stops systemd-nspawn from overwriting our manual /etc/resolv.conf
spawn systemd-nspawn -q --network-veth --resolv-conf=off -D \$MOUNT_DIR -M box --boot

expect "login: " { send "root\r" }

expect -re {#\s?$} { send "curl iiab.io/risky.txt | bash\r" }

expect {
    timeout { puts "\nTimed out waiting for final confirmation prompt"; exit 1 }
    "photograph" { send "\r" }
}

expect -re {#\s?$} { send "/root/install_preset.sh\r" }

expect -re {#\s?$} { send "shutdown now\r" }
expect eof
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"
"$EXPECT_SCRIPT"
