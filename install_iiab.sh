#!/usr/bin/env bash

set -euo pipefail

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file>}"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi
source "$STATE_FILE"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

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

run_in_container_once() {
    local cmd="$1"
    sudo systemd-nspawn -q -D "$MOUNT_DIR" /bin/bash -c "$cmd"
}

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

EXPECT_SCRIPT=$(mktemp)
cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set timeout 600

set MOUNT_DIR "$MOUNT_DIR"

# Spawn the container with --boot and network options for the interactive session
spawn sudo systemd-nspawn -q -D \$MOUNT_DIR --network-veth --resolv-conf=replace-host --boot --machine="$CONTAINER_NAME"

# Login sequence: Only match login, no password needed due to systemd-firstboot
# Use -re to match the start of the line (^) for resilience
expect -re "^login:" { send "root\r" }

# Execute the installer script (using the pre-downloaded script)
expect "#" { send "\$INSTALLER_PATH\r" }

# Wait for first prompt and select option 1
expect {
    timeout { puts "\n❌ Timeout waiting for initial installation menu."; exit 1 }
    -re ".*choice.*:" { send "1\r" }
    -re ".*number.*:" { send "1\r" }
    "1) Full Install" { send "1\r" }
}

# Press enter after selection
expect {
    timeout { puts "\n❌ Timeout waiting for confirmation."; exit 1 }
    -re ".*continue.*" { send "\r" }
    -re ".*press.*enter.*" { send "\r" }
    -re ".*OK.*" { send "\r" }
    eof
}

# Cleanly shut down the container from within the shell *before* Expect exits
expect "#" { send "shutdown now\r" }

# Wait for the script to complete and container to shut down (resulting in EOF)
expect eof
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"
"$EXPECT_SCRIPT"

run_in_container_once "mkdir -p /opt/iiab && cat > /opt/iiab/ansible.cfg << 'ANSIBLE_EOF'
[general]
ansible_connection = local
forks = 5
host_key_checking = False
ANSIBLE_EOF
"

IIAB_EXPECT_SCRIPT=$(mktemp)
cat > "$IIAB_EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set timeout 3600

set MOUNT_DIR "$MOUNT_DIR"

spawn sudo systemd-nspawn -q -D \$MOUNT_DIR --network-veth --resolv-conf=replace-host --boot --machine="$CONTAINER_NAME"

expect -re "^login:" { send "root\r" }
expect "#" { send "iiab\r" }

expect {
    timeout { puts "Timeout during iiab installation (first prompt)"; exit 1 }
    -re ".*continue.*" { send "\r" }
    -re ".*press.*enter.*" { send "\r" }
    eof
}
expect {
    timeout { puts "Timeout during iiab installation (second prompt)"; exit 1 }
    -re ".*continue.*" { send "\r" }
    -re ".*press.*enter.*" { send "\r" }
    eof
}

expect "#" { send "shutdown now\r" }
expect eof
EXPECT_EOF

chmod +x "$IIAB_EXPECT_SCRIPT"
"$IIAB_EXPECT_SCRIPT"
