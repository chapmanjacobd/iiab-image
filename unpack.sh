#!/bin/bash
set -euo pipefail

# Default URL for Raspberry Pi OS Lite ARM64
DEFAULT_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"

# Parse arguments
IMAGE_SOURCE="${1:-$DEFAULT_URL}"
ADDITIONAL_MB="${2:-22000}"
BOOT_PARTITION="${3:-}"
ROOT_PARTITION="${4:-}"

download_file() {
    local url="$1"
    local output="$2"

    if command -v aria2c &> /dev/null; then
        aria2c \
            --log-level=warn \
            --console-log-level=warn \
            --summary-interval=0 \
            --download-result=hide \
            --follow-metalink=mem \
            --max-connection-per-server=4 \
            --min-split-size=5M \
            --continue=true \
            --file-allocation=falloc \
            --enable-http-pipelining=true \
            -o "$output" \
            "$url"
    elif command -v curl &> /dev/null; then
        echo "aria2c not found. Falling back to curl..."
        curl -L --progress-bar -o "$output" "$url"
    else
        echo "Error: Neither aria2c nor curl is installed. Cannot download file." >&2
        return 1
    fi
}

wait_for_device_file() {
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
    CLEANED_FILENAME=$(echo "$BASE_FILENAME" | sed 's/\?.*$//' | sed 's/\.raw/.img/')
    if [[ -z "$CLEANED_FILENAME" || "$CLEANED_FILENAME" == "/" ]]; then
        # Fallback if URL is just a domain or ends in a slash
        DOWNLOAD_FILE="latest.img.xz"
    elif [[ "$CLEANED_FILENAME" == *.img.xz || "$CLEANED_FILENAME" == *.img ]]; then
        DOWNLOAD_FILE="$CLEANED_FILENAME"
    else
        DOWNLOAD_FILE="${CLEANED_FILENAME}.img.xz"
    fi

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
        xz -d -v "$XZ_FILE"
    else
        echo "Image file $IMG_FILE already exists, skipping extraction"
    fi
else
    echo "File doesn't have .xz extension, assuming it's already extracted"
    IMG_FILE="$XZ_FILE"
fi

sfdisk -r "$IMG_FILE"

if [[ -z "$BOOT_PARTITION" || -z "$ROOT_PARTITION" ]]; then
    echo "Partition numbers not explicity set. Attempting to auto-detect using parted on $IMG_FILE..." >&2
    json_output=$(parted --script "$IMG_FILE" unit B print --json 2>/dev/null)

    json_input=$(echo "$json_output" | jq '.disk.partitions' 2>/dev/null)
    if [[ -z "$json_input" || "$json_input" == "null" ]]; then
        echo "Error: Could not extract partition data from parted output." >&2
        exit 1
    fi

    partition_count=$(echo "$json_input" | jq 'length')
    if [[ "$partition_count" -gt 1 ]]; then
        if [[ -z "$BOOT_PARTITION" ]]; then
            BOOT_PARTITION=$(echo "$json_input" | jq -r '.[] | select((.flags // []) | contains(["boot"])) | .number')
            echo "Using boot partition $BOOT_PARTITION"
        fi

        if [[ -z "$ROOT_PARTITION" ]]; then
            ROOT_PARTITION=$(echo "$json_input" | jq -r '
                map(select((.flags // []) | contains(["boot"]) | not)) |
                sort_by(.start | sub("B$"; "") | tonumber) |
                last |
                .number
            ')
            echo "Using root partition $ROOT_PARTITION"
        fi

        if [[ -z "$BOOT_PARTITION" || -z "$ROOT_PARTITION" ]]; then
            echo "Error: Auto-detection failed. Could not uniquely identify partitions after parsing." >&2
            sudo parted --script "$LOOPDEV" print 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
            exit 1
        fi
    fi
fi

# Expand image if additional space requested
if [ "$ADDITIONAL_MB" -gt 0 ]; then
    ALIGN_BLOCK=4
    ADDITIONAL_MB=$(( ( (ADDITIONAL_MB + ALIGN_BLOCK - 1) / ALIGN_BLOCK ) * ALIGN_BLOCK ))

    echo "Adding ${ADDITIONAL_MB}MB to image..."
    dd if=/dev/zero bs=1M count="$ADDITIONAL_MB" >> "$IMG_FILE"
fi

# Create loopback device
echo "Creating loopback device..."
LOOPDEV=$(sudo losetup --find --show --partscan "$IMG_FILE")
echo "Created loopback device: $LOOPDEV"

# Resize partition if space was added
if [ "$ADDITIONAL_MB" -gt 0 ]; then
    sudo parted --script "$LOOPDEV" print 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""

    PART_TABLE=$(sudo parted --script "$LOOPDEV" print 2>/dev/null | grep "Partition Table:" | awk '{print $3}')
    if [ "$PART_TABLE" = "gpt" ]; then
        echo "Fixing GPT backup header..."
        sudo sgdisk -e "$LOOPDEV" 2>&1 | grep -v "Warning: Not all of the space" || true
    fi

    echo "Resizing partition to use available space"
    sudo parted --script "$LOOPDEV" resizepart "$ROOT_PARTITION" 100%
    sudo e2fsck -p -f "${LOOPDEV}p${ROOT_PARTITION}"
    sudo resize2fs "${LOOPDEV}p${ROOT_PARTITION}"

    echo "Partition resize complete"
    sudo parted --script "$LOOPDEV" print 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""
fi

# Wait for partition devices
sync
sudo partprobe -s "$LOOPDEV"

ROOTDEV=$(wait_for_device_file "${LOOPDEV}p${ROOT_PARTITION}")
echo "Root device: $ROOTDEV"

if [ "$BOOT_PARTITION" != "" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    BOOTDEV=$(wait_for_device_file "${LOOPDEV}p${BOOT_PARTITION}")
    echo "Boot device: $BOOTDEV"
else
    BOOTDEV=""
fi
echo ""

# Create mount point
MOUNT_DIR="${IMG_FILE%.*}"
sudo mkdir -p "$MOUNT_DIR"
echo "Mount point: $MOUNT_DIR"
sudo mount "$ROOTDEV" "$MOUNT_DIR"
echo "Root mounted at $MOUNT_DIR"
if [ -n "$BOOTDEV" ]; then
    if [ "$BOOT_PARTITION" = "15" ]; then
        # EFI system partition
        BOOT_MOUNT="$MOUNT_DIR/boot/efi"
        sudo mkdir -p "$BOOT_MOUNT"
        sudo mount "$BOOTDEV" "$BOOT_MOUNT"
    else
        # traditional boot partition
        BOOT_MOUNT="$MOUNT_DIR/boot"
        sudo mkdir -p "$BOOT_MOUNT"
        sudo mount "$BOOTDEV" "$BOOT_MOUNT"
    fi
    echo "Boot mounted at $BOOT_MOUNT"
fi
echo ""

# Save state information
STATE_FILE="${IMG_FILE}.state"
cat > "$STATE_FILE" <<EOF
LOOPDEV=$LOOPDEV
MOUNT_DIR=$MOUNT_DIR
IMG_FILE=$IMG_FILE
ROOT_PARTITION=$ROOT_PARTITION
BOOT_PARTITION=$BOOT_PARTITION
BOOT_MOUNT=${BOOT_MOUNT:-}
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
echo "To unmount, run: ./unmount.sh $STATE_FILE"
echo "=========================================="
