#!/bin/bash
set -euo pipefail

# Default URL for Raspberry Pi OS Lite ARM64
DEFAULT_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"

# Parse arguments
IMAGE_SOURCE="${1:-$DEFAULT_URL}"
ADDITIONAL_MB="${2:-0}"
ROOT_PARTITION="${3:-2}"
BOOT_PARTITION="${4:-1}"
MOUNT_BASE="${5:-./mnt}"

# Function to download file with progress
download_file() {
    local url="$1"
    local output="$2"

    echo "Downloading from $url..."
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$output" "$url"
    else
        echo "Error: curl is required to download files" >&2
        exit 1
    fi
}

# Function to wait for device file
wait_for_file() {
    local pattern="$1"
    local max_retries=60
    local retries=0

    until [ -n "$(compgen -G "$pattern")" ]; do
        retries=$((retries + 1))
        if [ $retries -ge $max_retries ]; then
            echo "Error: Could not find $pattern within $max_retries seconds" >&2
            return 1
        fi
        sleep 1
    done
    compgen -G "$pattern"
}

if [[ "$IMAGE_SOURCE" =~ ^https?:// ]]; then

    BASE_FILENAME=$(basename "$IMAGE_SOURCE")
    # clean up any URL query parameters (e.g., remove ?param=value)
    CLEANED_FILENAME=$(echo "$BASE_FILENAME" | sed 's/\?.*$//')
    # use the cleaned filename for the download, ensuring it's not empty
    if [[ -z "$CLEANED_FILENAME" || "$CLEANED_FILENAME" == "/" ]]; then
        # Fallback if URL is just a domain or ends in a slash
        DOWNLOAD_FILE="latest.img.xz"
    elif [[ "$CLEANED_FILENAME" == *.img.xz ]]; then
        DOWNLOAD_FILE="$CLEANED_FILENAME"
    else
        # Append the desired suffix
        DOWNLOAD_FILE="${CLEANED_FILENAME}.img.xz"
    fi

    trap "rm -f '$DOWNLOAD_FILE'" EXIT
    download_file "$IMAGE_SOURCE" "$DOWNLOAD_FILE"
    XZ_FILE="$DOWNLOAD_FILE"
elif [ -f "$IMAGE_SOURCE" ]; then
    echo "Using local file: $IMAGE_SOURCE"
    XZ_FILE="$IMAGE_SOURCE"
else
    echo "Error: '$IMAGE_SOURCE' is not a valid URL or file" >&2
    exit 1
fi

# Extract image
IMG_FILE="${XZ_FILE%.xz}"
if [ "$XZ_FILE" != "$IMG_FILE" ]; then
    echo "Extracting $XZ_FILE..."
    if [ ! -f "$IMG_FILE" ]; then
        xz -d -k -v "$XZ_FILE"
    else
        echo "Image file $IMG_FILE already exists, skipping extraction"
    fi
else
    echo "Warning: File doesn't have .xz extension, assuming it's already extracted"
    IMG_FILE="$XZ_FILE"
fi

# Expand image if additional space requested
if [ "$ADDITIONAL_MB" -gt 0 ]; then
    echo "Adding ${ADDITIONAL_MB}MB to image..."
    dd if=/dev/zero bs=1M count="$ADDITIONAL_MB" >> "$IMG_FILE"
fi

# Create loopback device
echo "Creating loopback device..."
LOOPDEV=$(sudo losetup --find --show --partscan "$IMG_FILE")
echo "Created loopback device: $LOOPDEV"

# Resize partition if space was added
if [ "$ADDITIONAL_MB" -gt 0 ]; then
    echo "Resizing partition..."

    # Check if GPT and fix if needed
    if sudo parted --script "$LOOPDEV" print | grep -q "Partition Table: gpt"; then
        echo "GPT partition table detected, fixing backup GPT..."
        sudo sgdisk -e "$LOOPDEV"
    fi

    # Resize partition to use all available space
    sudo parted --script "$LOOPDEV" resizepart "$ROOT_PARTITION" 100%
    sudo e2fsck -p -f "${LOOPDEV}p${ROOT_PARTITION}"
    sudo resize2fs "${LOOPDEV}p${ROOT_PARTITION}"
    echo "Partition resize complete"
fi

# Wait for partition devices
sync
sudo partprobe -s "$LOOPDEV"

ROOTDEV=$(wait_for_file "${LOOPDEV}p${ROOT_PARTITION}")
echo "Root device: $ROOTDEV"

if [ "$BOOT_PARTITION" != "" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    BOOTDEV=$(wait_for_file "${LOOPDEV}p${BOOT_PARTITION}")
    echo "Boot device: $BOOTDEV"
else
    BOOTDEV=""
fi

# Create mount point
MOUNT_DIR="$MOUNT_BASE"
sudo mkdir -p "$MOUNT_DIR"
echo "Mount point: $MOUNT_DIR"

# Mount root filesystem
echo "Mounting root filesystem..."
sudo mount "$ROOTDEV" "$MOUNT_DIR"

# Mount boot partition if it exists
if [ -n "$BOOTDEV" ]; then
    echo "Mounting boot filesystem..."
    sudo mkdir -p "$MOUNT_DIR/boot"
    sudo mount "$BOOTDEV" "$MOUNT_DIR/boot"
fi

# Setup QEMU for ARM emulation (if available)
setup_qemu() {
    if [ -f /usr/bin/qemu-arm-static ]; then
        echo "Setting up QEMU for ARM emulation..."
        sudo cp /usr/bin/qemu-arm-static "$MOUNT_DIR/usr/bin/" 2>/dev/null || true
    fi
    if [ -f /usr/bin/qemu-aarch64-static ]; then
        sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/" 2>/dev/null || true
    fi
}

setup_qemu

# Save state information
STATE_FILE="${IMG_FILE}.state"
cat > "$STATE_FILE" <<EOF
LOOPDEV=$LOOPDEV
MOUNT_DIR=$MOUNT_DIR
IMG_FILE=$IMG_FILE
ROOT_PARTITION=$ROOT_PARTITION
BOOT_PARTITION=$BOOT_PARTITION
EOF

echo ""
echo "=========================================="
echo "Image unpacked successfully!"
echo "=========================================="
echo "Loop device: $LOOPDEV"
echo "Mount point: $MOUNT_DIR"
echo "State file: $STATE_FILE"
echo ""
echo "To enter container: ./chroot.sh $STATE_FILE"
echo "To repack, run: ./repack.sh $STATE_FILE"
echo "=========================================="
