#!/usr/bin/env bash

set -euo pipefail

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file>}"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi
source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
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

systemd-firstboot --root="$MOUNT_DIR" --delete-root-password --force

cleanup() {
    echo "Attempting cleanup of temporary files..." >&2
    if [ -n "${EXPECT_SCRIPT:-}" ] && [ -f "$EXPECT_SCRIPT" ]; then
        rm -f "$EXPECT_SCRIPT"
    fi
    if [ -n "${IIAB_EXPECT_SCRIPT:-}" ] && [ -f "$IIAB_EXPECT_SCRIPT" ]; then
        rm -f "$IIAB_EXPECT_SCRIPT"
    fi
    pgrep -fa "$MOUNT_DIR"
}
trap cleanup EXIT

EXPECT_SCRIPT=$(mktemp)
cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set timeout 7200

set MOUNT_DIR "$MOUNT_DIR"

# --network-zone=br0 does not share the WiFi interface
# https://quantum5.ca/2025/03/22/whirlwind-tour-of-systemd-nspawn-containers/#networking
spawn systemd-nspawn -q -D \$MOUNT_DIR -M box --background="" --boot

expect "login: " { send "root\r" }

expect -re {#\s?$} { send "curl iiab.io/risky.txt | bash\r" }

expect {
    timeout { puts "\nTimed out waiting for key prompt"; exit 1 }
    "Please press a key" { send "1" }
}

expect {
    timeout { puts "\nTimed out waiting for final confirmation prompt"; exit 1 }
    "photograph" { send "\r" }
}

expect -re {#\s?$} { send "shutdown now\r" }
expect eof
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"
"$EXPECT_SCRIPT"
