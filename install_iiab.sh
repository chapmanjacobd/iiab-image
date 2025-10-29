#!/bin/bash
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
if [ -f /usr/bin/qemu-arm-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-arm-static" ]; then
    sudo cp /usr/bin/qemu-arm-static "$MOUNT_DIR/usr/bin/"
fi
if [ -f /usr/bin/qemu-aarch64-static ] && [ ! -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static" ]; then
    sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
fi
if [ -f "$MOUNT_DIR/etc/resolv.conf" ]; then
    sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"
fi

NSPAWN_OPTS=(
    -q                          # quiet
    -D "$MOUNT_DIR"             # OS directory
    --background=""             # disable nspawn terminal coloring
    --network-veth              # use private networking to prevent sshd port-in-use conflict
                                # alternatively pass in an existing network bridge interface
                                # example: --network-bridge=br0
    --resolv-conf=replace-host  # but use host DNS
    --boot                      # use init system
)

sudo systemd-nspawn "${NSPAWN_OPTS[@]}" &
NSPAWN_PID=$!

echo "Waiting for container to boot..."
sleep 10

run_in_container() {
    sudo machinectl shell root@"${MOUNT_DIR##*/}" /bin/bash -c "$1"
}

# Wait for container to be fully running
max_retries=30
retries=0
while ! sudo machinectl status "${MOUNT_DIR##*/}" &>/dev/null; do
    retries=$((retries + 1))
    if [ $retries -ge $max_retries ]; then
        echo "Error: Container failed to start" >&2
        sudo kill $NSPAWN_PID 2>/dev/null || true
        exit 1
    fi
    sleep 2
done

echo "Container is running"
echo ""

# Download and run IIAB installer with automated responses
echo "Downloading IIAB installer..."
run_in_container "curl -fsSL iiab.io/install.txt -o /tmp/install.sh && chmod +x /tmp/install.sh"

echo "Running IIAB installer (selecting option 1)..."

EXPECT_SCRIPT=$(mktemp)
trap "rm -f '$EXPECT_SCRIPT'" EXIT

cat > "$EXPECT_SCRIPT" << 'EXPECT_EOF'
#!/usr/bin/expect -f
set timeout 600

spawn sudo machinectl shell root@[lindex $argv 0] /bin/bash -c "/tmp/install.sh"

# Wait for first prompt and select option 1
expect {
    timeout { puts "Timeout waiting for menu"; exit 1 }
    -re ".*choice.*:" { send "1\r" }
}

# Press enter after selection
expect {
    timeout { puts "Timeout waiting for confirmation"; exit 1 }
    -re ".*continue.*" { send "\r" }
    -re ".*press.*enter.*" { send "\r" }
    eof
}

# Wait for script to complete
expect eof
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"
"$EXPECT_SCRIPT" "${MOUNT_DIR##*/}"

echo ""
echo "Creating ansible configuration..."

run_in_container "mkdir -p /opt/iiab && cat > /opt/iiab/ansible.cfg << 'ANSIBLE_EOF'
[general]
ansible_connection = local
forks = 5
host_key_checking = False
ANSIBLE_EOF
"

echo "Ansible configuration created at /opt/iiab/ansible.cfg"
echo ""

IIAB_EXPECT_SCRIPT=$(mktemp)
trap "rm -f '$IIAB_EXPECT_SCRIPT'" EXIT

cat > "$IIAB_EXPECT_SCRIPT" << 'EXPECT_EOF'
#!/usr/bin/expect -f
set timeout 3600

spawn sudo machinectl shell root@[lindex $argv 0] /bin/bash -c "cd /opt/iiab/iiab && ./iiab"

# Press enter twice when prompted
expect {
    timeout { puts "Timeout during iiab installation"; exit 1 }
    -re ".*continue.*" { send "\r" }
    -re ".*press.*enter.*" { send "\r" }
    eof
}

expect {
    timeout { puts "Timeout during iiab installation"; exit 1 }
    -re ".*continue.*" { send "\r" }
    -re ".*press.*enter.*" { send "\r" }
    eof
}

# Wait for installation to complete
expect eof
EXPECT_EOF

chmod +x "$IIAB_EXPECT_SCRIPT"
"$IIAB_EXPECT_SCRIPT" "${MOUNT_DIR##*/}"

echo ""
echo "=========================================="
echo "IIAB Installation Complete!"
echo "=========================================="
echo ""
echo "Shutting down container..."
sudo machinectl poweroff "${MOUNT_DIR##*/}" || true

echo "Waiting for container to stop..."
if [ -n "${NSPAWN_PID:-}" ] && sudo kill -0 $NSPAWN_PID 2>/dev/null; then
    wait $NSPAWN_PID 2>/dev/null || true
fi
