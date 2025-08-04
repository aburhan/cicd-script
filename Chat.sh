#!/bin/bash
set -e

# -------------------- Configuration --------------------
COMFYUI_URL="http://comfyui-nvidia-l4.comfyui.svc.cluster.local:8188"
WORKFLOWS_DIR="workflows"
TEST_DIR="temp"
OUTPUT_DIR="output"
POLL_TIMEOUT=300  # seconds
POLL_INTERVAL=5   # seconds

# -------------------- Utility Functions --------------------

log() {
    echo "[INFO] $*"
}

error() {
    echo "[ERROR] $*" >&2
}

check_dependencies() {
    for cmd in jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd is not installed. Please install it to continue."
            exit 1
        fi
    done
}

# -------------------- Core Functions --------------------

verify_files() {
    if [ "$RUN_VERIFY" = false ]; then
        log "Skipping file verification."
        return
    fi

    log "Verifying that test files exist for each workflow..."

    for wf in "$WORKFLOWS_DIR"/*.json; do
        name=$(basename "$wf")
        if [ ! -f "$TEST_DIR/$name" ]; then
            error "Missing test file: $TEST_DIR/$name"
            exit 1
        fi
    done

    log "File verification passed."
}

execute_workflow() {
    local test_file="$1"

    if [ ! -f "$test_file" ]; then
        error "Test file not found: $test_file"
        return 1
    fi

    log "Submitting workflow: $test_file"
    local response
    response=$(curl -s -X POST "$COMFYUI_URL/prompt" \
        -H "Content-Type: application/json" \
        -d @"$test_file")

    local prompt_id
    prompt_id=$(echo "$response" | jq -r '.prompt_id')
    if [[ -z "$prompt_id" || "$prompt_id" == "null" ]]; then
        error "Failed to extract prompt_id from response: $response"
        return 1
    fi

    log "Received prompt_id: $prompt_id"
    get_history "$prompt_id"
    return $?
}

get_history() {
    local prompt_id="$1"
    local start_time
    start_time=$(date +%s)

    log "Polling history for prompt_id: $prompt_id"

    while true; do
        local response body http_code
        response=$(curl -s -w "%{http_code}" "$COMFYUI_URL/history/$prompt_id")
        http_code="${response: -3}"
        body="${response::-3}"

        if [[ "$http_code" == "200" ]]; then
            local filename subfolder type
            filename=$(echo "$body" | jq -r '.[].outputs | .[] | select(.images) | .images[0].filename')
            subfolder=$(echo "$body" | jq -r '.[].outputs | .[] | select(.images) | .images[0].subfolder')
            type=$(echo "$body" | jq -r '.[].outputs | .[] | select(.images) | .images[0].type')

            if [[ -n "$filename" ]]; then
                log "Image ready: $filename ($type in $subfolder)"
                download_image "$filename" "$subfolder" "$type"
                return $?
            else
                error "Filename not found in response."
                return 1
            fi
        fi

        if (( $(date +%s) - start_time >= POLL_TIMEOUT )); then
            error "Polling timed out after $POLL_TIMEOUT seconds."
            echo "$body"
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

download_image() {
    local filename="$1"
    local subfolder="$2"
    local type="$3"
    local url="${COMFYUI_URL}/view?filename=${filename}&subfolder=${subfolder}&type=${type}"
    local dest="${OUTPUT_DIR}/${filename}"

    log "Checking image at: $url"
    local size
    size=$(curl -sI "$url" | awk '/Content-Length/ {print $2}' | tr -d '\r')

    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -eq 0 ]; then
        error "Invalid or empty file size: $size"
        return 1
    fi

    log "Image size is $size bytes. Downloading to: $dest"
    mkdir -p "$OUTPUT_DIR"
    curl -s -o "$dest" "$url"

    if [ -f "$dest" ] && [ $(stat -c%s "$dest") -gt 0 ]; then
        log "Download complete: $dest"
        return 0
    else
        error "Download failed or file is empty."
        rm -f "$dest"
        return 1
    fi
}

# -------------------- Entrypoint --------------------

test_main() {
    local test_file="$1"
    log "=== Running test for: $test_file ==="

    check_dependencies

    if ! execute_workflow "$test_file"; then
        error "Test failed."
        exit 1
    fi

    log "=== Test completed successfully ==="
}

if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_workflow.json>"
    exit 1
fi

test_main "$1"
