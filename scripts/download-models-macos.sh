#!/bin/bash
set -euo pipefail

# ATLAS Model Downloader — Apple Silicon
# Downloads Qwen3.5-9B GGUF models, auto-selects quantization based on memory.
#
# 16GB Mac: Q4_K_M (~5.5GB) — recommended, leaves headroom
# 24GB+ Mac: Q6_K (~7.5GB) — higher quality, still comfortable
#
# GGUF format is hardware-agnostic — same files work on CUDA and Metal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Model URLs (Hugging Face) — Qwen3.5-9B (DeltaNet hybrid)
QWEN35_9B_Q4_URL="https://huggingface.co/Qwen/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
QWEN35_9B_Q6_URL="https://huggingface.co/Qwen/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q6_K.gguf"

# Default model directory
MODELS_DIR="${ATLAS_MODELS_DIR:-$REPO_DIR/models}"

download_model() {
    local url="$1"
    local filename="$2"
    local filepath="$MODELS_DIR/$filename"

    if [[ -f "$filepath" ]]; then
        log_info "$filename already exists, skipping download"
        return
    fi

    log_info "Downloading $filename..."
    log_info "This may take a while depending on connection speed"

    mkdir -p "$MODELS_DIR"

    # Use curl with resume support
    if ! curl -L -C - --progress-bar -o "$filepath.tmp" "$url"; then
        log_error "Download failed for $filename"
        rm -f "$filepath.tmp"
        return 1
    fi

    mv "$filepath.tmp" "$filepath"
    log_info "$filename downloaded successfully"
}

verify_model() {
    local filepath="$1"
    local min_size="$2"

    if [[ ! -f "$filepath" ]]; then
        return 1
    fi

    # macOS stat uses -f%z, Linux uses -c%s
    local size
    size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null)
    if [[ $size -lt $min_size ]]; then
        log_error "File $filepath is too small (${size} bytes), may be corrupted"
        return 1
    fi

    return 0
}

detect_memory() {
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: sysctl returns bytes
        local mem_bytes
        mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        echo $(( mem_bytes / 1073741824 ))
    else
        # Linux fallback
        free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0"
    fi
}

main() {
    echo "=========================================="
    echo "  ATLAS Model Downloader (Apple Silicon)"
    echo "=========================================="
    echo ""

    # Detect system memory
    local total_mem_gb
    total_mem_gb=$(detect_memory)
    log_info "Detected system memory: ${total_mem_gb}GB"

    # Auto-select quantization based on memory
    if [[ $total_mem_gb -ge 24 ]]; then
        log_info "24GB+ memory: selecting Q6_K (higher quality)"
        MODEL_URL="$QWEN35_9B_Q6_URL"
        MODEL_FILE="Qwen3.5-9B-Q6_K.gguf"
        MIN_SIZE=7000000000
    else
        log_info "16GB memory: selecting Q4_K_M (saves ~2GB vs Q6_K)"
        MODEL_URL="$QWEN35_9B_Q4_URL"
        MODEL_FILE="Qwen3.5-9B-Q4_K_M.gguf"
        MIN_SIZE=5000000000
    fi

    # Allow override via env var
    if [[ -n "${ATLAS_MODEL_FILE:-}" ]]; then
        log_info "Override: ATLAS_MODEL_FILE=$ATLAS_MODEL_FILE"
        if [[ "$ATLAS_MODEL_FILE" == *"Q6_K"* ]]; then
            MODEL_URL="$QWEN35_9B_Q6_URL"
            MODEL_FILE="$ATLAS_MODEL_FILE"
            MIN_SIZE=7000000000
        elif [[ "$ATLAS_MODEL_FILE" == *"Q4_K_M"* ]]; then
            MODEL_URL="$QWEN35_9B_Q4_URL"
            MODEL_FILE="$ATLAS_MODEL_FILE"
            MIN_SIZE=5000000000
        fi
    fi

    echo ""
    echo "Models directory: $MODELS_DIR"
    echo "Selected model:   $MODEL_FILE"
    echo ""

    # Check for huggingface-cli (optional, for faster downloads)
    if command -v huggingface-cli &>/dev/null; then
        log_info "HuggingFace CLI found (can use for faster downloads)"
    fi

    # Download model
    download_model "$MODEL_URL" "$MODEL_FILE"

    # Verify download
    echo ""
    log_info "Verifying download..."
    if verify_model "$MODELS_DIR/$MODEL_FILE" "$MIN_SIZE"; then
        log_info "Model verified: $MODEL_FILE"
    else
        log_error "Model verification failed"
        exit 1
    fi

    # Create symlink for default model
    ln -sf "$MODELS_DIR/$MODEL_FILE" "$MODELS_DIR/default.gguf"

    echo ""
    echo "=========================================="
    echo "  Model Download Complete!"
    echo "=========================================="
    echo ""
    echo "Models available:"
    ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null || echo "  No .gguf files found"
    echo ""
    echo "Next: ./scripts/start-macos.sh"
    echo ""
}

main "$@"
