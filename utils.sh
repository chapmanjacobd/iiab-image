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
