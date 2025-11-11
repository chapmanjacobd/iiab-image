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
