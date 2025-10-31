#!/bin/bash
set -euo pipefail

# Default URL for Raspberry Pi OS Lite ARM64
DEFAULT_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"

IMAGE_SOURCE="${1:-$DEFAULT_URL}"
TARGET_MB="${2:-22000}"
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
        exit 1
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

    # Clean up any URL query parameters (e.g., remove ?param=value)
    CLEANED_FILENAME=$(echo "$BASE_FILENAME" | sed 's/\?.*$//' | sed 's/\.raw/.img/')

    # Normalize extensions for naming consistency
    case "$CLEANED_FILENAME" in
        *.img.xz|*.img|*.raw.gz|*.raw.tar.gz)
            DOWNLOAD_FILE="$CLEANED_FILENAME"
            ;;
        *.raw)
            DOWNLOAD_FILE="${CLEANED_FILENAME%.raw}.img"
            ;;
        *)
            DOWNLOAD_FILE="${CLEANED_FILENAME}.img.xz"
            ;;
    esac

    download_file "$IMAGE_SOURCE" "$DOWNLOAD_FILE"
    ARCHIVE_FILE="$DOWNLOAD_FILE"
elif [ -f "$IMAGE_SOURCE" ]; then
    ARCHIVE_FILE="$IMAGE_SOURCE"
else
    echo "Error: '$IMAGE_SOURCE' is not a valid URL or file" >&2
    exit 1
fi

case "$ARCHIVE_FILE" in
    *.img.xz)
        IMG_FILE="${ARCHIVE_FILE%.xz}"
        xz -d -v "$ARCHIVE_FILE"
        ;;
    *.raw.gz)
        IMG_FILE="${ARCHIVE_FILE%.gz}.img"
        gunzip -c "$ARCHIVE_FILE" > "$IMG_FILE"
        ;;
    *.raw.tar.gz)
        IMG_FILE="${ARCHIVE_FILE%.tar.gz}.img"
        tar -xzf "$ARCHIVE_FILE" --wildcards '*.raw'
        mv *.raw "$IMG_FILE" 2>/dev/null || true
        ;;
    *.img|*.raw)
        IMG_FILE="$ARCHIVE_FILE"
        ;;
    *)
        echo "Unknown archive type: $ARCHIVE_FILE" >&2
        exit 1
        ;;
esac

if [ -f "${IMG_FILE}.state" ]; then
    echo "${IMG_FILE}.state already exists. Unmount first: ./unmount ${IMG_FILE}.state"
    exit 32
fi

if command -v sfdisk &> /dev/null; then
    echo "Re-counting partition numbers"
    sfdisk -r "$IMG_FILE"
fi

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

if [[ -z "$BOOT_PARTITION" || -z "$ROOT_PARTITION" ]]; then
    if ! command -v jq &>/dev/null; then
        echo "Installing jq for JSON parsing..."
        apt-get update
        apt-get install -y jq
    fi

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
        fi

        if [[ -z "$ROOT_PARTITION" ]]; then
            ROOT_PARTITION=$(echo "$json_input" | jq -r '
                map(select((.flags // []) | contains(["boot"]) | not)) |
                sort_by(.start | sub("B$"; "") | tonumber) |
                last |
                .number
            ')
        fi

        if [[ "$partition_count" -eq 2 && -z "$BOOT_PARTITION" ]]; then
            BOOT_PARTITION=$(echo "$json_input" | jq -r '
                map(select((.flags // []) )) |
                sort_by(.start | sub("B$"; "") | tonumber) |
                first |
                .number
            ')
        fi

        if [[ -z "$BOOT_PARTITION" || -z "$ROOT_PARTITION" ]]; then
            echo "Error: Auto-detection failed. Could not uniquely identify partitions after parsing." >&2
            parted --script "$IMG_FILE" print 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
            exit 1
        fi

        echo "Using boot partition $BOOT_PARTITION"
        echo "Using root partition $ROOT_PARTITION"
    fi
fi

CURRENT_BYTES=$(stat -c %s "$IMG_FILE")
CURRENT_MB=$(( CURRENT_BYTES / 1024 / 1024 ))
ADDITIONAL_MB=$(( TARGET_MB - CURRENT_MB ))

ALIGN_BLOCK=4
ADDITIONAL_MB=$(( ( (ADDITIONAL_MB + ALIGN_BLOCK - 1) / ALIGN_BLOCK ) * ALIGN_BLOCK ))

if [ "$ADDITIONAL_MB" -gt 0 ]; then
    echo "Current image size: ${CURRENT_MB}MB"
    echo "Target image size: ${TARGET_MB}MB"
    echo "Adding ${ADDITIONAL_MB}MB to image..."

    dd if=/dev/zero bs=4M count=$(( ADDITIONAL_MB / 4 )) >> "$IMG_FILE"
fi

LOOPDEV=$(losetup --find --show --partscan "$IMG_FILE")
echo "Created loopback device: $LOOPDEV"

# Resize partition and filesystem
if [ "$ADDITIONAL_MB" -gt 0 ]; then
    PART_TYPE=$(blkid -o value -s PTTYPE "$LOOPDEV")
    if [ "$PART_TYPE" = "gpt" ]; then
        if ! command -v sgdisk &> /dev/null; then
            echo "GPT disk support requires sgdisk..."
            apt-get update
            apt-get install -y sgdisk
        fi

        echo "Fixing GPT backup header..."
        sgdisk -e "$LOOPDEV"
    fi
    parted --script --fix "$LOOPDEV" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""

    echo "Resizing partition to use available space"
    parted --script "$LOOPDEV" resizepart "$ROOT_PARTITION" 100%
    e2fsck -p -f "${LOOPDEV}p${ROOT_PARTITION}"
    resize2fs "${LOOPDEV}p${ROOT_PARTITION}"

    echo "Partition resize complete:"
    parted --script "$LOOPDEV" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""
fi

# Wait for partition devices
sync
partprobe -s "$LOOPDEV"

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
mkdir -p "$MOUNT_DIR"
echo "Mount point: $MOUNT_DIR"
mount "$ROOTDEV" "$MOUNT_DIR"
echo "Root mounted at $MOUNT_DIR"
if [ -n "$BOOTDEV" ]; then
    BOOT_MOUNT="$MOUNT_DIR/boot"
    mkdir -p "$BOOT_MOUNT"
    mount "$BOOTDEV" "$BOOT_MOUNT"
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
