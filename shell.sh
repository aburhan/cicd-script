#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
COMFYUI_URL="http://comfyui-nvidia-l4.comfyui.svc.cluster.local:8188"
WORKFLOWS_DIR="workflows"
TEST_DIR="temp"
OUTPUT_DIR="output"
POLL_TIMEOUT=300  # in seconds
POLL_INTERVAL=5   # in seconds

# --- Helper Functions ---

# Check for required dependencies
check_dependencies() {
    if ! command -v jq &> /dev/null;
    then
        echo "Error: jq is not installed. Please install it to continue."
        exit 1
    fi
    if ! command -v curl &> /dev/null;
    then
        echo "Error: curl is not installed. Please install it to continue."
        exit 1
    fi
}

# --- Core Functions ---

# 1. Verify that workflow files in WORKFLOWS_DIR have corresponding files in TEST_DIR
verify_files() {
    if [ "$RUN_VERIFY" = false ]; then
        echo "Skipping file verification."
        return
    fi

    echo "Verifying files..."
    for workflow_file in "$WORKFLOWS_DIR"/*.json;
    do
        base_name=$(basename "$workflow_file")
        if [ ! -f "$TEST_DIR/$base_name" ]; then
            echo "Error: Matching test file '$base_name' not found in '$TEST_DIR/'."
            echo "Please add a corresponding test file to the '$TEST_DIR/' directory."
            exit 1
        fi
    done
    echo "File verification successful."
}

# 2. Execute a workflow and store the prompt ID
execute_workflow() {
    local test_file=$1
    if [ ! -f "$test_file" ]; then
        echo "Error: Test file '$test_file' not found."
        return 1
    fi

    echo "Executing workflow from '$test_file'..."
    local response
    response=$(curl -s -X POST "$COMFYUI_URL/prompt" \
        -H "Content-Type: application/json" \
        -d @"$test_file")

    prompt_id=$(echo "$response" | jq -r '.prompt_id')

    if [ -z "$prompt_id" ] || [ "$prompt_id" == "null" ]; then
        echo "Error: Failed to get prompt ID from response."
        echo "Response: $response"
        return 1
    fi

    echo "Workflow submitted. Prompt ID: $prompt_id"
}

# 3. Get history for a prompt ID and extract the output filename
get_history() {
    local current_prompt_id=$1
    local start_time=$(date +%s)

    echo "Getting history for prompt ID: $current_prompt_id..."

    while true; do
        local response
        response=$(curl -s -o - -w "%{http_code}" "$COMFYUI_URL/history/$current_prompt_id")

        local http_code="${response: -3}"
        echo "HTTP Code: $http_code"

        local body="${response::-3}"
        
        if [[ "$http_code" == "200" ]]; then
            local filename=$(echo "$body" | jq -r '.[].outputs | .[] | select(.images) | .images[0].filename')
            local subfolder=$(echo "$body" | jq -r '.[].outputs | .[] | select(.images) | .images[0].subfolder')
            local type=$(echo "$body" | jq -r '.[].outputs | .[] | select(.images) | .images[0].type')
            echo "++++++++++$filename $subfolder $type"
            if [[ -n "$filename" ]]; then
                echo "$filename $subfolder $type"
                download_image "$filename" "$subfolder" "$type"
                return 0
            else
                echo "Error: Could not find filename in response." >&2
                return 1
            fi
        fi

        local now=$(date +%s)
        if (( now - start_time >= POLL_TIMEOUT )); then
            echo "Polling timeout: no successful response after $POLL_TIMEOUT seconds"
            echo "Last response body:"
            echo "$body"
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

# 4. Download the image and verify its size
# 4. Download the image and verify its size
download_image() {
    local filename="$1"
    local subfolder="$2"
    local folder_type="$3"

    local image_url="${COMFYUI_URL}/view?filename=${filename}&subfolder=${subfolder}&type=${folder_type}"
    echo "Downloading image from: $image_url"

    local output_path="$OUTPUT_DIR/$filename"

    # Get the file size from the Content-Length header using a single curl command.
    local size_in_bytes
    size_in_bytes=$(curl -sI "$image_url" | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
    local curl_exit_code=$?

    # Check for curl execution errors.
    if [ "$curl_exit_code" -ne 0 ]; then
        echo "Error: curl command failed." >&2
        return 1
    fi

    # Check if the size is a valid number and greater than 0.
    if ! [[ "$size_in_bytes" =~ ^[0-9]+$ ]] || [ "$size_in_bytes" -eq 0 ]; then
        echo "Error: File size is 0 bytes or could not be determined." >&2
        return 1
    fi

    echo "Image found with size: $size_in_bytes bytes. Downloading..."

    # Create the output directory and download the image.
    mkdir -p "$OUTPUT_DIR"
    curl -s -o "$output_path" "$image_url"

    # Verify the downloaded file size.
    if [ -f "$output_path" ] && [ $(stat -c%s "$output_path") -gt 0 ]; then
        echo "Image downloaded successfully to '$output_path'."
    else
        echo "Error: Image download failed or the file is empty."
        rm -f "$output_path"
        return 1
    fi

    return 0
}

# --- Main Test Execution for a single file ---
test_main() {
    local test_file=$1
    echo "--- Running test for: $test_file ---"
    
    check_dependencies
    
    if [ ! -f "$test_file" ]; then
        echo "Error: Test file '$test_file' does not exist."
        exit 1
    fi

    local prompt_id
    if ! execute_workflow "$test_file"; then
        echo "Test failed during workflow execution."
        exit 1
    fi

    get_history "$prompt_id"


    echo "--- Test completed successfully ---"
}

# --- Entrypoint ---
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_workflow.json>"
    exit 1
fi
test_main "$1"
