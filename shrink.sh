#!/bin/bash
set -euo pipefail

# Parse arguments
STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file>}"

# Check if state file exists
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

echo "Loop device: $LOOPDEV"
echo "Mount point: $MOUNT_DIR"
echo "Image file: $IMG_FILE"

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

if ! mountpoint -q "$MOUNT_DIR"; then
    echo "$MOUNT_DIR is not a mountpoint"
    return 1
fi

unmount_with_retries() {
    local mountpoint="$1"
    local retries=0
    local max_retries=10
    local force=""

    if ! mountpoint -q "$mountpoint"; then
        return 0
    fi

    while ! umount $force "$mountpoint" 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -ge $max_retries ]; then
            echo "Error: Could not unmount $mountpoint after $retries attempts" >&2
            return 1
        fi
        if [ $retries -eq 5 ]; then
            echo "Trying force unmount..."
            force="--force"
        fi
        # Kill processes using the mountpoint
        fuser -ck "$mountpoint" 2>/dev/null || true
        sleep 1
    done
    echo "Unmounted $mountpoint"
}

# Zero-fill boot partition
if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    # Determine boot mount
    BOOT_FILL_PATH=""
    if [ -n "${BOOT_MOUNT:-}" ] && [ -d "$BOOT_MOUNT" ] && mountpoint -q "$BOOT_MOUNT" 2>/dev/null; then
        BOOT_FILL_PATH="$BOOT_MOUNT"
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
    elif mountpoint -q "$MOUNT_DIR/boot/efi" 2>/dev/null; then
        unmount_with_retries "$MOUNT_DIR/boot/efi"
    elif mountpoint -q "$MOUNT_DIR/boot" 2>/dev/null; then
        unmount_with_retries "$MOUNT_DIR/boot"
    fi
fi
if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    unmount_with_retries "$MOUNT_DIR"
fi

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
ROOTFS_PARTNEWEND=$((ROOTFS_PARTSTART + ROOTFS_PARTSIZE + 104857600))  # 100MB buffer space

if [ "$ROOTFS_PARTOLDEND" -gt "$ROOTFS_PARTNEWEND" ]; then
    echo "Shrinking root partition from $ROOTFS_PARTOLDEND to $ROOTFS_PARTNEWEND bytes..."

    parted --script "$LOOPDEV" rm "$ROOT_PARTITION"
    parted --script "$LOOPDEV" unit b mkpart primary ext4 "$ROOTFS_PARTSTART" "$ROOTFS_PARTNEWEND"
    if [ -n "$PART_NAME" ]; then
        parted --script "$LOOPDEV" name "$ROOT_PARTITION" "$PART_NAME"
    fi
    if [ -n "$PART_FLAGS" ]; then
        for flag in $(echo "$PART_FLAGS" | tr ',' ' '); do
            parted --script "$LOOPDEV" set "$ROOT_PARTITION" "$flag" on || true
        done
    fi

    parted --script --fix "$LOOPDEV" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""
    sync
    partprobe "$LOOPDEV"

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
