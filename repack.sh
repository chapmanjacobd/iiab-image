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

# Load state
echo "Loading state from $STATE_FILE..."
source "$STATE_FILE"

# Verify required variables
: "${LOOPDEV:?Error: LOOPDEV not set in state file}"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"
: "${IMG_FILE:?Error: IMG_FILE not set in state file}"
: "${ROOT_PARTITION:?Error: ROOT_PARTITION not set in state file}"

echo "Loop device: $LOOPDEV"
echo "Mount point: $MOUNT_DIR"
echo "Image file: $IMG_FILE"

# Cleanup chroot environment if it was setup
CHROOT_STATE="${STATE_FILE}.chroot"
if [ -f "$CHROOT_STATE" ]; then
    echo "Cleaning up chroot environment..."

    # Remove QEMU binaries
    sudo rm -f "$MOUNT_DIR/usr/bin/qemu-arm-static" 2>/dev/null || true
    sudo rm -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static" 2>/dev/null || true

    # Restore resolv.conf
    if [ -f "$MOUNT_DIR/etc/_resolv.conf" ]; then
        sudo mv "$MOUNT_DIR/etc/_resolv.conf" "$MOUNT_DIR/etc/resolv.conf"
    fi

    # Restore ld.so.preload
    if [ -f "$MOUNT_DIR/etc/_ld.so.preload" ]; then
        sudo mv "$MOUNT_DIR/etc/_ld.so.preload" "$MOUNT_DIR/etc/ld.so.preload"
    fi

    rm -f "$CHROOT_STATE"
fi

# Function to unmount with retries
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
    echo "Successfully unmounted $mountpoint"
}

# Optimize image if requested
if [[ "$OPTIMIZE" == "yes" || "$OPTIMIZE" == "true" ]]; then
    echo "Optimizing image..."

    # Zero-fill boot partition
    if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
        if [ -d "$MOUNT_DIR/boot" ]; then
            echo "Zero-filling unused blocks on boot filesystem..."
            (sudo sh -c "cat /dev/zero > '$MOUNT_DIR/boot/zero.fill'" 2>/dev/null || true)
            sync
            sudo rm -f "$MOUNT_DIR/boot/zero.fill"
        fi
    fi

    # Zero-fill root partition
    echo "Zero-filling unused blocks on root filesystem..."
    (sudo sh -c "cat /dev/zero > '$MOUNT_DIR/zero.fill'" 2>/dev/null || true)
    sync
    sudo rm -f "$MOUNT_DIR/zero.fill"
fi

# Unmount all filesystems
echo "Unmounting filesystems..."

# Unmount chroot mounts if they exist
for mp in "$MOUNT_DIR/dev/pts" "$MOUNT_DIR/dev" "$MOUNT_DIR/proc" "$MOUNT_DIR/sys"; do
    if mountpoint -q "$mp" 2>/dev/null; then
        unmount_with_retries "$mp"
    fi
done

# Unmount boot and root
if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    unmount_with_retries "$MOUNT_DIR/boot"
fi
unmount_with_retries "$MOUNT_DIR"

# Optimize partition size if requested
if [[ "$OPTIMIZE" == "yes" || "$OPTIMIZE" == "true" ]]; then
    echo "Shrinking root filesystem to minimal size..."
    ROOTDEV="${LOOPDEV}p${ROOT_PARTITION}"

    # Shrink filesystem
    sudo e2fsck -p -f "$ROOTDEV"
    sudo resize2fs -M "$ROOTDEV"

    # Get filesystem info
    ROOTFS_BLOCKSIZE=$(sudo tune2fs -l "$ROOTDEV" | grep "^Block size" | awk '{print $NF}')
    ROOTFS_BLOCKCOUNT=$(sudo tune2fs -l "$ROOTDEV" | grep "^Block count" | awk '{print $NF}')

    # Calculate new partition size
    ROOTFS_PARTSTART=$(sudo parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:" | awk -F ":" '{print $2}' | tr -d 'B')
    ROOTFS_PARTSIZE=$((ROOTFS_BLOCKCOUNT * ROOTFS_BLOCKSIZE))
    ROOTFS_PARTEND=$((ROOTFS_PARTSTART + ROOTFS_PARTSIZE - 1))
    ROOTFS_PARTOLDEND=$(sudo parted -m --script "$LOOPDEV" unit B print | grep "^${ROOT_PARTITION}:" | awk -F ":" '{print $3}' | tr -d 'B')

    # Shrink partition if needed
    if [ "$ROOTFS_PARTOLDEND" -gt "$ROOTFS_PARTEND" ]; then
        echo "Shrinking root partition..."
        echo y | sudo parted ---pretend-input-tty "$LOOPDEV" unit B resizepart "$ROOT_PARTITION" "$ROOTFS_PARTEND"
    else
        echo "Root partition already at minimal size"
    fi

    # Shrink image file
    FREE_SPACE=$(sudo parted -m --script "$LOOPDEV" unit B print free | tail -1)
    if [[ "$FREE_SPACE" =~ "free" ]]; then
        INITIAL_SIZE=$(stat -L --printf="%s" "$IMG_FILE")
        NEW_SIZE=$(echo "$FREE_SPACE" | awk -F ":" '{print $2}' | tr -d 'B')

        # Check partition table type
        PART_TYPE=$(sudo blkid -o value -s PTTYPE "$LOOPDEV")
        echo "Partition table type: $PART_TYPE"

        # Add space for GPT backup table if needed
        if [[ "$PART_TYPE" == "gpt" ]]; then
            NEW_SIZE=$((NEW_SIZE + 16896))
        fi

        echo "Shrinking image from $INITIAL_SIZE to $NEW_SIZE bytes..."
        sudo losetup --detach "$LOOPDEV"
        truncate -s "$NEW_SIZE" "$IMG_FILE"

        # Fix GPT backup table if needed
        if [[ "$PART_TYPE" == "gpt" ]]; then
            echo "Fixing GPT backup table..."
            sudo sgdisk -e "$IMG_FILE"
        fi

        # Re-create loopback for final cleanup
        LOOPDEV=$(sudo losetup --find --show --partscan "$IMG_FILE")
    fi
fi

# Detach loopback device
echo "Detaching loopback device..."
sudo losetup --detach "$LOOPDEV" || true

# Remove mount directory
sudo rmdir "$MOUNT_DIR" 2>/dev/null || true

# Remove state file
rm -f "$STATE_FILE"

echo ""
echo "=========================================="
echo "Image repacked successfully!"
echo "=========================================="
echo "Image file: $IMG_FILE"
echo ""
echo "To compress, run: xz -v -9 -T0 $IMG_FILE"
echo "=========================================="
