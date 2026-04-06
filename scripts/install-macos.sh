#!/bin/bash
set -euo pipefail

# ATLAS Installation Script — Apple Silicon (macOS)
#
# Replaces the Linux/K3s/NVIDIA install path with:
#   1. Homebrew dependencies (cmake, python3)
#   2. llama.cpp built from source with Metal
#   3. Model download (auto-selects quantization)
#   4. Docker Desktop for remaining services
#   5. Health check
#
# No K3s, no GPU Operator, no Kubernetes.
# Single-machine deployment via Docker Compose + native llama-server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/config-macos.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Step 1: Check platform ---
check_platform() {
    log_info "Checking platform..."

    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only. Use scripts/install.sh for Linux."
        exit 1
    fi

    if [[ "$(uname -m)" != "arm64" ]]; then
        log_error "Apple Silicon (arm64) required. Intel Macs are not supported."
        exit 1
    fi

    log_info "Platform: macOS $(sw_vers -productVersion) on $(uname -m)"
}

# --- Step 2: Hardware requirements ---
check_hardware() {
    log_info "Checking hardware..."
    detect_macos_hardware
    print_hardware_summary

    if [[ $DETECTED_SYS_MEM_GB -lt 16 ]]; then
        log_error "ATLAS requires at least 16GB unified memory."
        log_error "Detected: ${DETECTED_SYS_MEM_GB}GB"
        exit 1
    fi

    if [[ $DETECTED_SYS_MEM_GB -lt 24 ]]; then
        log_warn "16GB detected — will use Q4_K_M quantization and conservative settings."
        log_warn "For best results, 24GB+ is recommended."
    fi

    echo ""
}

# --- Step 3: Install dependencies ---
install_dependencies() {
    log_info "Checking dependencies..."

    # Homebrew
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    # cmake (needed to build llama.cpp)
    if ! command -v cmake &>/dev/null; then
        log_info "Installing cmake..."
        brew install cmake
    else
        log_info "cmake: $(cmake --version | head -1)"
    fi

    # Xcode Command Line Tools
    if ! xcode-select -p &>/dev/null; then
        log_info "Installing Xcode Command Line Tools..."
        xcode-select --install
        echo ""
        log_warn "Xcode CLT install started. Re-run this script after installation completes."
        exit 0
    fi

    # Docker Desktop
    if ! command -v docker &>/dev/null; then
        log_error "Docker Desktop not found."
        log_error "Install from: https://www.docker.com/products/docker-desktop/"
        log_error "Then re-run this script."
        exit 1
    fi

    if ! docker info &>/dev/null; then
        log_error "Docker is installed but not running. Start Docker Desktop first."
        exit 1
    fi

    log_info "All dependencies OK"
    echo ""
}

# --- Step 4: Build llama.cpp ---
build_llama() {
    if command -v llama-server &>/dev/null; then
        local version
        version=$(llama-server --version 2>&1 | head -1 || echo "unknown")
        log_info "llama-server already installed: $version"

        if [[ "${FORCE_BUILD:-false}" != "true" ]]; then
            log_info "Skipping build (use FORCE_BUILD=true to rebuild)"
            return
        fi
    fi

    log_info "Building llama.cpp with Metal backend..."
    "$SCRIPT_DIR/build-llama-metal.sh"
    echo ""
}

# --- Step 5: Download model ---
download_model() {
    local model_file="$ATLAS_MODELS_DIR/$ATLAS_MAIN_MODEL"

    if [[ -f "$model_file" ]]; then
        log_info "Model already exists: $ATLAS_MAIN_MODEL"
        return
    fi

    log_info "Downloading model..."
    "$SCRIPT_DIR/download-models-macos.sh"
    echo ""
}

# --- Step 6: Build Docker images ---
build_docker_images() {
    log_info "Building Docker images..."
    cd "$REPO_DIR"
    docker compose -f docker-compose.macos.yml build
    log_info "Docker images built"
    echo ""
}

# --- Step 7: Create directories ---
create_directories() {
    log_info "Creating directories..."
    mkdir -p "$ATLAS_MODELS_DIR"
    mkdir -p "$ATLAS_DATA_DIR"
    mkdir -p "${ATLAS_LORA_DIR:-$ATLAS_MODELS_DIR/lora}"
    mkdir -p "$REPO_DIR/logs"
    log_info "Directories ready"
}

# --- Main ---
main() {
    echo "=========================================="
    echo "  ATLAS Installation — Apple Silicon"
    echo "=========================================="
    echo ""

    check_platform
    check_hardware

    # Show installation plan
    echo "Installation plan:"
    echo "  1. Check/install dependencies (Homebrew, cmake, Docker)"
    echo "  2. Build llama.cpp with Metal GPU backend"
    echo "  3. Download Qwen3.5-9B model ($ATLAS_MAIN_MODEL)"
    echo "  4. Build Docker images (geometric-lens, v3-service, sandbox, atlas-proxy)"
    echo "  5. Create data directories"
    echo ""

    if [[ "${ATLAS_AUTO_CONFIRM:-false}" != "true" ]]; then
        read -p "Continue with installation? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
    fi

    echo ""
    install_dependencies
    create_directories
    build_llama
    download_model
    build_docker_images

    echo ""
    echo "=========================================="
    echo "  Installation Complete!"
    echo "=========================================="
    echo ""
    echo "Hardware:"
    print_hardware_summary
    echo ""
    echo "Configuration:"
    echo "  Model:      $ATLAS_MAIN_MODEL"
    echo "  Models dir: $ATLAS_MODELS_DIR"
    echo "  Data dir:   $ATLAS_DATA_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Start ATLAS:    ./scripts/start-macos.sh"
    echo "  2. Verify health:  ./scripts/verify-macos.sh"
    echo "  3. Stop ATLAS:     ./scripts/stop-macos.sh"
    echo ""
    echo "The atlas-proxy endpoint (http://localhost:${ATLAS_PROXY_PORT:-8090})"
    echo "provides the full V3.1 pipeline with agent loop."
    echo ""
}

main "$@"
