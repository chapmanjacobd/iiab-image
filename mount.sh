#!/bin/bash
set -euo pipefail
source ./utils.sh

# Default URL for Raspberry Pi OS Lite ARM64
DEFAULT_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"

IMAGE_SOURCE="${1:-$DEFAULT_URL}"
TARGET_MB="${2:-5000}"
BOOT_PARTITION="${3:-}"
ROOT_PARTITION="${4:-}"

if [[ "$IMAGE_SOURCE" =~ ^https?:// ]]; then
    BASE_FILENAME=$(basename "$IMAGE_SOURCE")

    # Clean up any URL query parameters (e.g., remove ?param=value)
    CLEANED_FILENAME=$(echo "$BASE_FILENAME" | sed 's/\?.*$//' | sed 's/\.raw/.img/')

    # Normalize extensions for naming consistency
    case "$CLEANED_FILENAME" in
        *.img|*.iso|*.xz|*.gz)
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
    *.xz)
        IMG_FILE="${ARCHIVE_FILE%.xz}"
        xz -d -v "$ARCHIVE_FILE"
        ;;
    *.tar.gz)
        IMG_FILE="${ARCHIVE_FILE%.tar.gz}.img"
        tar -xzf "$ARCHIVE_FILE" --wildcards '*.raw'
        mv *.raw "$IMG_FILE"
        ;;
    *.gz)
        IMG_FILE="${ARCHIVE_FILE%.gz}.img"
        gunzip -c "$ARCHIVE_FILE" > "$IMG_FILE"
        ;;
    *.img|*.raw|*.iso)
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
MOUNT_DIR="${IMG_FILE%.*}"
if mountpoint -q "$MOUNT_DIR"; then
    echo "$MOUNT_DIR is already a mountpoint. Unmount first manually..."
    return 1
fi

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$IMG_FILE" "${@:2}"
fi

if command -v sfdisk &> /dev/null; then
    echo "Re-counting partition numbers"
    sfdisk -r "$IMG_FILE"
fi

if [[ -z "$BOOT_PARTITION" || -z "$ROOT_PARTITION" ]]; then
    if ! command -v jq &>/dev/null; then
        echo "Installing jq for JSON parsing..."
        apt-get update
        apt-get install -y jq
    fi

    echo "Partition numbers not explicity set. Attempting to auto-detect $IMG_FILE..." >&2
    json_output=$(parted --script "$IMG_FILE" unit B print --json 2>/dev/null || true)

    json_partitions=$(echo "$json_output" | jq -c '.disk.partitions' 2>/dev/null)
    partition_count=$(echo "$json_partitions" | jq 'length')
    if [[ -z "$json_partitions" || "$json_partitions" == "null" ]]; then
        echo "No partitions found. Mounting whole block device" >&2
        ROOT_PARTITION=""
    elif [[ "$partition_count" -eq 1 ]]; then
        ROOT_PARTITION=$(echo "$json_partitions" | jq -r '.[] | .number')
    elif [[ "$partition_count" -gt 1 ]]; then
        if [[ -z "$BOOT_PARTITION" ]]; then
            BOOT_PARTITION=$(echo "$json_partitions" | jq -r '.[] | select((.flags // []) | contains(["boot"])) | .number')
        fi

        if [[ -z "$ROOT_PARTITION" ]]; then
            ROOT_PARTITION=$(echo "$json_partitions" | jq -r '
                map(select((.flags // []) | contains(["boot"]) | not)) |
                sort_by(.start | sub("B$"; "") | tonumber) |
                last |
                .number
            ')
        fi

        if [[ "$partition_count" -eq 2 && -z "$BOOT_PARTITION" ]]; then
            BOOT_PARTITION=$(echo "$json_partitions" | jq -r '
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

if [ "$ADDITIONAL_MB" -gt 0 ]; then
    echo "Current image size: ${CURRENT_MB}MB"
    echo "Target image size: ${TARGET_MB}MB"
    echo "Adding ${ADDITIONAL_MB}MB to image..."

    truncate -s "${TARGET_MB}M" "$IMG_FILE"
fi

LOOPDEV=$(losetup --find "$IMG_FILE" --nooverlap --show --partscan)
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
    if [[ "$ROOT_PARTITION" != "" ]]; then
        parted --script "$LOOPDEV" resizepart "$ROOT_PARTITION" 100%
    fi

    echo "Resizing filesystem to end of partition"
    if [[ -z "$ROOT_PARTITION" || -z "$BOOT_PARTITION" && "$partition_count" -eq 1 ]]; then
        # losetup unwraps single partitions
        resize2fs "${LOOPDEV}"
        e2fsck -p -f "${LOOPDEV}"
    else
        resize2fs "${LOOPDEV}p${ROOT_PARTITION}"
        e2fsck -p -f "${LOOPDEV}p${ROOT_PARTITION}"
    fi

    echo "Partition resize complete:"
    parted --script "$LOOPDEV" print free 2>/dev/null | awk '/^Number/ {p=1} p && NF {print}'
    echo ""
fi

# Wait for partition devices
sync
partprobe -s "$LOOPDEV" || true

if [[ -z "$ROOT_PARTITION" || -z "$BOOT_PARTITION" && "$partition_count" -eq 1 ]]; then
    # losetup unwraps single partitions
    ROOTDEV=$(wait_for_device_file "${LOOPDEV}")
else
    ROOTDEV=$(wait_for_device_file "${LOOPDEV}p${ROOT_PARTITION}")
fi
echo "Root device: $ROOTDEV"

if [ "$BOOT_PARTITION" != "" ] && [ "$BOOT_PARTITION" != "$ROOT_PARTITION" ]; then
    BOOTDEV=$(wait_for_device_file "${LOOPDEV}p${BOOT_PARTITION}")
    echo "Boot device: $BOOTDEV"
else
    BOOTDEV=""
fi
echo ""

# Create mount point
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
