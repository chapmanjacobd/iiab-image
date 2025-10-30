#!/bin/bash
set -euo pipefail

# Parse arguments
STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file> [optimize]}"
OPTIMIZE="${2:-yes}"

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

    echo "Unmounting $mountpoint..."
    while ! sudo umount $force "$mountpoint" 2>/dev/null; do
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
        sudo fuser -ck "$mountpoint" 2>/dev/null || true
        sleep 1
    done
    echo "Unmounted $mountpoint"
}

# Optimize image if requested
if [[ "$OPTIMIZE" == "yes" || "$OPTIMIZE" == "true" ]]; then

    # Remove QEMU binaries
    for qemu_bin in "$MOUNT_DIR/usr/bin/qemu-*-static"; do
        sudo rm -f "$qemu_bin" 2>/dev/null || true
    done

    # Zero-fill boot partition
    if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
        # Determine boot mount
        BOOT_FILL_PATH=""
        if [ -n "${BOOT_MOUNT:-}" ] && mountpoint -q "$BOOT_MOUNT" 2>/dev/null; then
            BOOT_FILL_PATH="$BOOT_MOUNT"
        elif [ -d "$MOUNT_DIR/boot/efi" ] && mountpoint -q "$MOUNT_DIR/boot/efi" 2>/dev/null; then
            BOOT_FILL_PATH="$MOUNT_DIR/boot/efi"
        elif [ -d "$MOUNT_DIR/boot" ] && mountpoint -q "$MOUNT_DIR/boot" 2>/dev/null; then
            BOOT_FILL_PATH="$MOUNT_DIR/boot"
        fi

        if [ -n "$BOOT_FILL_PATH" ]; then
            echo "Zero-filling unused blocks on boot filesystem... $BOOT_FILL_PATH"
            (sudo sh -c "cat /dev/zero > '$BOOT_FILL_PATH/zero.fill'" 2>/dev/null || true)
            sync
            sudo rm -f "$BOOT_FILL_PATH/zero.fill"
        fi
    fi

    # Zero-fill root partition
    echo "Zero-filling unused blocks on root filesystem..."
    (sudo sh -c "cat /dev/zero > '$MOUNT_DIR/zero.fill'" 2>/dev/null || true)
    sync
    sudo rm -f "$MOUNT_DIR/zero.fill"
fi

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

if [[ "$OPTIMIZE" == "yes" || "$OPTIMIZE" == "true" ]]; then
    echo "Shrinking root filesystem to minimal size..."
    ROOTDEV="${LOOPDEV}p${ROOT_PARTITION}"

    sudo e2fsck -p -f "$ROOTDEV"
    sudo resize2fs -M "$ROOTDEV"

    ROOTFS_BLOCKSIZE=$(sudo tune2fs -l "$ROOTDEV" | grep "^Block size" | awk '{print $NF}')
    ROOTFS_BLOCKCOUNT=$(sudo tune2fs -l "$ROOTDEV" | grep "^Block count" | awk '{print $NF}')

    # Calculate new partition size
    ROOTFS_PARTSTART=$(sudo parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:" | awk -F ":" '{print $2}' | tr -d 'B')
    ROOTFS_PARTSIZE=$((ROOTFS_BLOCKCOUNT * ROOTFS_BLOCKSIZE))
    ROOTFS_PARTEND=$((ROOTFS_PARTSTART + ROOTFS_PARTSIZE))
    ROOTFS_PARTOLDEND=$(sudo parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:" | awk -F ":" '{print $3}' | tr -d 'B')

    if [ "$ROOTFS_PARTOLDEND" -gt "$ROOTFS_PARTEND" ]; then
        echo "Shrinking root partition..."

        echo sudo parted ---pretend-input-tty "$LOOPDEV" unit B resizepart "$ROOT_PARTITION" "$ROOTFS_PARTEND"

        (echo "Fix" | sudo parted ---pretend-input-tty "$LOOPDEV" unit B resizepart "$ROOT_PARTITION" "$ROOTFS_PARTEND") 2>&1 | \
            grep -v "Warning: Not all of the space" || true
    else
        echo "Root partition already at minimal size"
    fi

    FREE_SPACE=$(sudo parted -m --script "$LOOPDEV" unit B print free | tail -1)
    if [[ "$FREE_SPACE" =~ "free" ]]; then
        INITIAL_SIZE=$(stat -L --printf="%s" "$IMG_FILE")
        NEW_SIZE=$(echo "$FREE_SPACE" | awk -F ":" '{print $2}' | tr -d 'B')
        PART_TYPE=$(sudo blkid -o value -s PTTYPE "$LOOPDEV")
        if [[ "$PART_TYPE" == "gpt" ]]; then
            NEW_SIZE=$((NEW_SIZE + 16896))
        fi

        echo "Shrinking image from $INITIAL_SIZE to $NEW_SIZE bytes..."
        sudo losetup --detach "$LOOPDEV"  # detach before truncation
        LOOPDEV=""
        truncate -s "$NEW_SIZE" "$IMG_FILE"

        if [[ "$PART_TYPE" == "gpt" ]]; then
            echo "Fixing GPT backup table..."
            sudo sgdisk -e "$IMG_FILE" 2>&1 | grep -v "Warning: Not all of the space" || true
        fi
    fi
fi

if [ -n "$LOOPDEV" ]; then
    sudo losetup --detach "$LOOPDEV" || true
fi

sudo rmdir "$MOUNT_DIR" 2>/dev/null || true
rm -f "$STATE_FILE"

echo ""
echo "=========================================="
echo "Image repacked successfully!"
echo "=========================================="
echo "Image file: $IMG_FILE"
echo ""
echo "To compress, run: xz -v -9 -T0 $IMG_FILE"
echo "=========================================="
