#!/bin/bash
# ATLAS Config Loader — macOS / Apple Silicon
# Source this in macOS scripts: source "$SCRIPT_DIR/lib/config-macos.sh"
#
# Replaces Linux-specific detection (nvidia-smi, free, nproc, ip)
# with macOS equivalents (sysctl, system_profiler).

# Get paths relative to this library file
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCRIPTS_DIR="$(dirname "$_LIB_DIR")"
REPO_DIR="$(dirname "$_SCRIPTS_DIR")"

# Colors
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
NC="${NC:-\033[0m}"

# --- macOS hardware detection ---
detect_macos_hardware() {
    # CPU cores
    DETECTED_CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "4")

    # System memory (bytes → GB)
    local mem_bytes
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
    DETECTED_SYS_MEM_GB=$(( mem_bytes / 1073741824 ))

    # GPU cores (Apple Silicon integrated GPU)
    DETECTED_GPU_CORES=$(system_profiler SPDisplaysDataType 2>/dev/null \
        | grep -i "Total Number of Cores" | awk -F': ' '{print $2}' | head -1)
    DETECTED_GPU_CORES="${DETECTED_GPU_CORES:-10}"

    # Chip name
    DETECTED_CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")

    # Memory bandwidth estimate (for reporting)
    case "$DETECTED_CHIP" in
        *"M4 Pro"*)  DETECTED_MEM_BW="273 GB/s" ;;
        *"M4 Max"*)  DETECTED_MEM_BW="546 GB/s" ;;
        *"M4"*)      DETECTED_MEM_BW="120 GB/s" ;;
        *"M3 Pro"*)  DETECTED_MEM_BW="150 GB/s" ;;
        *"M3 Max"*)  DETECTED_MEM_BW="400 GB/s" ;;
        *"M3"*)      DETECTED_MEM_BW="100 GB/s" ;;
        *"M2 Pro"*)  DETECTED_MEM_BW="200 GB/s" ;;
        *"M2 Max"*)  DETECTED_MEM_BW="400 GB/s" ;;
        *"M2"*)      DETECTED_MEM_BW="100 GB/s" ;;
        *"M1 Pro"*)  DETECTED_MEM_BW="200 GB/s" ;;
        *"M1 Max"*)  DETECTED_MEM_BW="400 GB/s" ;;
        *"M1"*)      DETECTED_MEM_BW="68 GB/s"  ;;
        *)           DETECTED_MEM_BW="unknown"   ;;
    esac

    export DETECTED_CPU_CORES DETECTED_SYS_MEM_GB DETECTED_GPU_CORES
    export DETECTED_CHIP DETECTED_MEM_BW
}

# --- Node IP detection (macOS) ---
detect_node_ip() {
    # Try en0 (WiFi) or en1 (Ethernet) first, then any active interface
    local ip
    ip=$(ipconfig getifaddr en0 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(ipconfig getifaddr en1 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
    [[ -z "$ip" ]] && ip="127.0.0.1"
    echo "$ip"
}

# --- Load config ---
load_macos_config() {
    local config_file="${ATLAS_CONFIG_FILE:-$REPO_DIR/atlas.conf}"

    if [[ -f "$config_file" ]]; then
        source "$config_file"
    elif [[ -f "$REPO_DIR/atlas.conf.example" ]]; then
        echo -e "${YELLOW}[WARN]${NC} atlas.conf not found, using atlas.conf.example defaults"
        source "$REPO_DIR/atlas.conf.example"
    fi

    # Override node IP for macOS
    if [[ "${ATLAS_NODE_IP:-auto}" == "auto" ]]; then
        ATLAS_NODE_IP=$(detect_node_ip)
    fi

    # Sensible macOS defaults (override Linux-centric config values)
    ATLAS_MODELS_DIR="${ATLAS_MODELS_DIR:-$REPO_DIR/models}"
    ATLAS_DATA_DIR="${ATLAS_DATA_DIR:-$REPO_DIR/data}"
    ATLAS_LORA_DIR="${ATLAS_LORA_DIR:-$ATLAS_MODELS_DIR/lora}"

    # Auto-select model based on memory
    detect_macos_hardware
    if [[ $DETECTED_SYS_MEM_GB -ge 24 ]]; then
        ATLAS_MAIN_MODEL="${ATLAS_MAIN_MODEL:-Qwen3.5-9B-Q6_K.gguf}"
        ATLAS_MODEL_NAME="${ATLAS_MODEL_NAME:-Qwen3.5-9B-Q6_K}"
    else
        ATLAS_MAIN_MODEL="${ATLAS_MAIN_MODEL:-Qwen3.5-9B-Q4_K_M.gguf}"
        ATLAS_MODEL_NAME="${ATLAS_MODEL_NAME:-Qwen3.5-9B-Q4_K_M}"
    fi

    # Disable NVIDIA-specific features
    ATLAS_ENABLE_SPECULATIVE=false

    # Export everything
    export "${!ATLAS_@}" 2>/dev/null || true
    export REPO_DIR
}

# --- Print hardware summary ---
print_hardware_summary() {
    echo "  Chip:     $DETECTED_CHIP"
    echo "  CPU:      $DETECTED_CPU_CORES cores"
    echo "  Memory:   ${DETECTED_SYS_MEM_GB}GB unified"
    echo "  GPU:      ${DETECTED_GPU_CORES} cores"
    echo "  Mem BW:   $DETECTED_MEM_BW"
}

# Auto-load on source
load_macos_config
