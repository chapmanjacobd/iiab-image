#!/bin/bash
set -euo pipefail
source ./utils.sh

# Parse arguments
STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [buffer_size_mb]}"
BUFFER_SIZE_MB="${2:-100}"
if [[ "$STATE_FILE" != *.state ]]; then
  echo "Error: STATE_FILE must end in .state" >&2
  exit 1
fi
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi
source "$STATE_FILE"
# Verify required variables
: "${LOOPDEV:?Error: LOOPDEV not set in state file}"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"
: "${IMG_FILE:?Error: IMG_FILE not set in state file}"
: "${ROOT_PARTITION:?Error: ROOT_PARTITION not set in state file}"

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Loop device: $LOOPDEV"
echo "Mount point: $MOUNT_DIR"
echo "Image file: $IMG_FILE"

if ! mountpoint -q "$MOUNT_DIR"; then
    echo "$MOUNT_DIR is not a mountpoint"
    exit 1
fi

# cleanup
systemd-nspawn -q -D "$MOUNT_DIR" --pipe /bin/bash -eux <<'EOF'
apt clean
rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*
rm -rf /var/cache/man/*
rm -rf /var/cache/fontconfig/*
rm -f /var/log/*log /var/log/*gz

rm -f /etc/ssh/ssh_host_*
rm -f /var/lib/NetworkManager/*.lease
rm -f /var/log/nginx/*.log

rm -rf /root/.cache/*
rm -f /root/.bash_history

touch /.resize-rootfs
journalctl --vacuum-time=1s
EOF

systemd-firstboot --root="$MOUNT_DIR" --timezone=UTC --setup-machine-id --force
rm -f "$MOUNT_DIR/etc/machine-id"

# Zero-fill boot partition
if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    # Determine boot mount
    BOOT_FILL_PATH=""
    if [ -n "${BOOT_MOUNT:-}" ] && [ -d "$BOOT_MOUNT" ] && mountpoint -q "$BOOT_MOUNT" 2>/dev/null; then
        BOOT_FILL_PATH="$BOOT_MOUNT"
    elif [ -d "$MOUNT_DIR/boot/firmware" ] && mountpoint -q "$MOUNT_DIR/boot/firmware" 2>/dev/null; then
        BOOT_FILL_PATH="$MOUNT_DIR/boot/firmware"
    elif [ -d "$MOUNT_DIR/boot/efi" ] && mountpoint -q "$MOUNT_DIR/boot/efi" 2>/dev/null; then
        BOOT_FILL_PATH="$MOUNT_DIR/boot/efi"
    elif [ -d "$MOUNT_DIR/boot" ] && mountpoint -q "$MOUNT_DIR/boot" 2>/dev/null; then
        BOOT_FILL_PATH="$MOUNT_DIR/boot"
    fi

    if [ -n "$BOOT_FILL_PATH" ]; then
        echo "Zero-filling unused blocks on boot filesystem... $BOOT_FILL_PATH"
        (sh -c "cat /dev/zero > '$BOOT_FILL_PATH/zero.fill'" 2>/dev/null || true)
        sync
        rm -f "$BOOT_FILL_PATH/zero.fill"
    fi
fi

# Zero-fill root partition
echo "Zero-filling unused blocks on root filesystem... $MOUNT_DIR"
(sh -c "cat /dev/zero > '$MOUNT_DIR/zero.fill'" 2>/dev/null || true)
sync
rm -f "$MOUNT_DIR/zero.fill"

echo "Unmounting filesystems..."
if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    if [ -n "${BOOT_MOUNT:-}" ] && mountpoint -q "$BOOT_MOUNT" 2>/dev/null; then
        unmount_with_retries "$BOOT_MOUNT"
    elif mountpoint -q "$MOUNT_DIR/boot/firmware" 2>/dev/null; then
        unmount_with_retries "$MOUNT_DIR/boot/firmware"
    elif mountpoint -q "$MOUNT_DIR/boot/efi" 2>/dev/null; then
        unmount_with_retries "$MOUNT_DIR/boot/efi"
    elif mountpoint -q "$MOUNT_DIR/boot" 2>/dev/null; then
        unmount_with_retries "$MOUNT_DIR/boot"
    fi
fi
if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    unmount_with_retries "$MOUNT_DIR"
fi

echo ""
parted --script --fix "$LOOPDEV" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
echo ""

echo "Shrinking root filesystem to minimal size..."
ROOTDEV="${LOOPDEV}p${ROOT_PARTITION}"

e2fsck -p -f "$ROOTDEV"
resize2fs -M "$ROOTDEV"

ROOTFS_BLOCKSIZE=$(tune2fs -l "$ROOTDEV" | grep "^Block size" | awk '{print $NF}')
ROOTFS_BLOCKCOUNT=$(tune2fs -l "$ROOTDEV" | grep "^Block count" | awk '{print $NF}')

PART_INFO=$(parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:")
ROOTFS_PARTSTART=$(echo "$PART_INFO" | awk -F ":" '{print $2}' | tr -d 'B')
ROOTFS_PARTOLDEND=$(echo "$PART_INFO" | awk -F ":" '{print $3}' | tr -d 'B')
PART_NAME=$(parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:" | awk -F ":" '{print $6}')
PART_FLAGS=$(parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:" | awk -F ":" '{print $7}' | tr -d ';')

ROOTFS_PARTSIZE=$((ROOTFS_BLOCKCOUNT * ROOTFS_BLOCKSIZE))
# Calculate padding to include 1% reserved blocks + 100MB free space
# We want: FinalSize - (FinalSize * 0.01) = CurrentUsedSize + 100MB
# So: FinalSize * 0.99 = ROOTFS_PARTSIZE + 100MB
# FinalSize = (ROOTFS_PARTSIZE + 100MB) / 0.99
# Let's approximate /0.99 with *1.011 for safety
BUFFER_SIZE=$((BUFFER_SIZE_MB * 1024 * 1024))
TARGET_USER_SPACE=$((ROOTFS_PARTSIZE + BUFFER_SIZE))
TOTAL_REQUIRED_SIZE=$(( (TARGET_USER_SPACE * 1011) / 1000 ))
ROOTFS_PARTNEWEND=$((ROOTFS_PARTSTART + TOTAL_REQUIRED_SIZE - 1))

if [ "$ROOTFS_PARTOLDEND" -gt "$ROOTFS_PARTNEWEND" ]; then
    (yes Yes | parted ---pretend-input-tty "$LOOPDEV" unit b resizepart "$ROOT_PARTITION" "$ROOTFS_PARTNEWEND" || true)  >/dev/null 2>&1
    parted --script --fix "$LOOPDEV" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""

    sync
    partprobe "$LOOPDEV"
    if command -v udevadm &>/dev/null; then
        udevadm settle
    else
        sleep 2
    fi

    echo "Expanding filesystem to fill new partition size..."
    e2fsck -p -f "$ROOTDEV" || true
    resize2fs "$ROOTDEV" >/dev/null 2>&1

    tune2fs -m 1 "$ROOTDEV" >/dev/null 2>&1
else
    echo "Root partition already at minimal size"
fi

PART_TYPE=$(blkid -o value -s PTTYPE "$LOOPDEV")
FREE_SPACE=$(parted -m --script "$LOOPDEV" unit B print free | tail -1)

if [[ "$FREE_SPACE" =~ "free" ]]; then
    NEW_SIZE=$(echo "$FREE_SPACE" | awk -F ":" '{print $2}' | tr -d 'B')
    if [[ "$PART_TYPE" == "gpt" ]]; then
        NEW_SIZE=$((NEW_SIZE + 1048576))
    else
        NEW_SIZE=$((NEW_SIZE + 4096))
    fi

    echo "Truncating image to $NEW_SIZE bytes..."
    losetup --detach "$LOOPDEV"  # detach before truncation
    LOOPDEV=""
    truncate -s "$NEW_SIZE" "$IMG_FILE"

    if [[ "$PART_TYPE" == "gpt" ]]; then
        if ! command -v sgdisk &> /dev/null; then
            echo "GPT disk support requires sgdisk..."
            apt-get update
            apt-get install -y sgdisk
        fi

        sgdisk -e "$IMG_FILE" > /dev/null 2>&1
    fi
    echo ""

    parted --script --fix "$IMG_FILE" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
fi

rm -f "$STATE_FILE"
rmdir "$MOUNT_DIR"

echo ""
echo "=========================================="
echo "Image repacked successfully!"
echo "=========================================="
echo "Image file: $IMG_FILE"
echo ""
echo "To compress, run: xz -v -9 -T0 $IMG_FILE"
echo "=========================================="
