#!/usr/bin/env bash

set -euo pipefail

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file>}"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi
source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

if ! command -v expect &>/dev/null; then
    echo "Installing expect for automation..."
    sudo apt-get update
    sudo apt-get install -y expect
fi
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

sudo systemd-firstboot --root="$MOUNT_DIR" --delete-root-password --force

cleanup() {
    echo "Attempting cleanup of temporary files..." >&2
    if [ -n "${EXPECT_SCRIPT:-}" ] && [ -f "$EXPECT_SCRIPT" ]; then
        rm -f "$EXPECT_SCRIPT"
    fi
    if [ -n "${IIAB_EXPECT_SCRIPT:-}" ] && [ -f "$IIAB_EXPECT_SCRIPT" ]; then
        rm -f "$IIAB_EXPECT_SCRIPT"
    fi
    sudo systemd-nspawn -k --terminate -D "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

EXPECT_SCRIPT=$(mktemp)
cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set timeout 600

set MOUNT_DIR "$MOUNT_DIR"

spawn sudo systemd-nspawn -q -D \$MOUNT_DIR --background="" --network-zone=br0 --boot

expect "login: " { send "root\r" }

expect -re {#\s?$} { send "curl iiab.io/risky.txt | bash\r" }

expect {
    timeout { puts "\nTimed out waiting for confirmation prompt"; exit 1 }
    "Please press a key" { send "1" }
    eof
}

expect -re {#\s?$} { send "shutdown now\r" }
expect eof
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"
"$EXPECT_SCRIPT"
