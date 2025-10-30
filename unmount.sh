#!/bin/bash
set -euo pipefail

STATE_FILE="${1:?Error: State file required. Usage: $0 <state_file>}"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file '$STATE_FILE' not found" >&2
    exit 1
fi

echo "Loading state from $STATE_FILE..."
source "$STATE_FILE"

# Verify required variables
: "${LOOPDEV:?Error: LOOPDEV not set in state file}"
: "${MOUNT_DIR:?Error: MOUNT_DIR not set in state file}"

echo "Loop device: $LOOPDEV"
echo "Mount point: $MOUNT_DIR"
echo ""

# Function to unmount with retries
unmount_with_retries() {
    local mountpoint="$1"
    local retries=0
    local max_retries=10
    local force=""

    if ! mountpoint -q "$mountpoint" 2>/dev/null; then
        echo "$mountpoint is not mounted"
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

# Unmount boot partition if it exists and is mounted
if [ -n "${BOOT_PARTITION:-}" ] && [ "$BOOT_PARTITION" != "${ROOT_PARTITION:-2}" ]; then
    if [ -n "${BOOT_MOUNT:-}" ] && [ -d "$BOOT_MOUNT" ]; then
        unmount_with_retries "$BOOT_MOUNT"
    elif [ -d "$MOUNT_DIR/boot/efi" ]; then
        unmount_with_retries "$MOUNT_DIR/boot/efi"
    elif [ -d "$MOUNT_DIR/boot" ]; then
        unmount_with_retries "$MOUNT_DIR/boot"
    fi
fi

# Unmount root filesystem
if [ -d "$MOUNT_DIR" ]; then
    unmount_with_retries "$MOUNT_DIR"
    sudo rmdir "$MOUNT_DIR" 2>/dev/null || true
fi

# Detach loop device
if [ -n "$LOOPDEV" ]; then
    if losetup "$LOOPDEV" &>/dev/null; then
        echo "Detaching loop device $LOOPDEV..."
        sudo losetup --detach "$LOOPDEV"
        echo "Loop device detached"
    else
        echo "Loop device $LOOPDEV is not active"
    fi
fi

rm -f "$STATE_FILE"
