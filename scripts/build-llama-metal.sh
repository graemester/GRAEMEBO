#!/bin/bash
set -euo pipefail

# ATLAS: Build llama.cpp with Metal backend for Apple Silicon
# Produces llama-server and llama-cli binaries with GPU acceleration.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

INSTALL_PREFIX="${LLAMA_INSTALL_PREFIX:-/usr/local/bin}"
BUILD_DIR="${LLAMA_BUILD_DIR:-/tmp/llama.cpp}"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"

# --- Prerequisites ---
check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only (detected: $(uname))"
        exit 1
    fi

    if [[ "$(uname -m)" != "arm64" ]]; then
        log_error "Apple Silicon (arm64) required (detected: $(uname -m))"
        exit 1
    fi

    # Check for Xcode command line tools (provides clang, metal compiler)
    if ! xcode-select -p &>/dev/null; then
        log_error "Xcode Command Line Tools not found."
        log_error "Install with: xcode-select --install"
        exit 1
    fi

    # Check for cmake
    if ! command -v cmake &>/dev/null; then
        log_error "cmake not found."
        if command -v brew &>/dev/null; then
            log_error "Install with: brew install cmake"
        else
            log_error "Install Homebrew first: https://brew.sh"
            log_error "Then: brew install cmake"
        fi
        exit 1
    fi

    log_info "Prerequisites OK"
}

# --- Build ---
build_llama() {
    local ncpu
    ncpu=$(sysctl -n hw.ncpu)

    if [[ -d "$BUILD_DIR" ]]; then
        log_info "Updating existing llama.cpp checkout..."
        cd "$BUILD_DIR"
        git fetch origin
        git reset --hard origin/master
    else
        log_info "Cloning llama.cpp..."
        git clone "$LLAMA_REPO" "$BUILD_DIR"
        cd "$BUILD_DIR"
    fi

    local commit
    commit=$(git rev-parse --short HEAD)
    log_info "Building llama.cpp (commit: $commit) with Metal backend..."

    # Clean previous build
    rm -rf build

    cmake -B build \
        -DGGML_METAL=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build build --config Release -j"$ncpu"

    log_info "Build complete"
}

# --- Install ---
install_binaries() {
    log_info "Installing binaries to $INSTALL_PREFIX..."

    local server_bin="$BUILD_DIR/build/bin/llama-server"
    local cli_bin="$BUILD_DIR/build/bin/llama-cli"

    if [[ ! -f "$server_bin" ]]; then
        log_error "llama-server binary not found at $server_bin"
        exit 1
    fi

    # Check if we need sudo
    if [[ -w "$INSTALL_PREFIX" ]]; then
        cp "$server_bin" "$INSTALL_PREFIX/llama-server"
        [[ -f "$cli_bin" ]] && cp "$cli_bin" "$INSTALL_PREFIX/llama-cli"
    else
        log_warn "Writing to $INSTALL_PREFIX requires sudo"
        sudo cp "$server_bin" "$INSTALL_PREFIX/llama-server"
        [[ -f "$cli_bin" ]] && sudo cp "$cli_bin" "$INSTALL_PREFIX/llama-cli"
    fi

    log_info "Installed: $INSTALL_PREFIX/llama-server"
    [[ -f "$cli_bin" ]] && log_info "Installed: $INSTALL_PREFIX/llama-cli"
}

# --- Verify ---
verify_install() {
    log_info "Verifying installation..."

    if ! command -v llama-server &>/dev/null; then
        log_error "llama-server not found in PATH"
        log_error "Ensure $INSTALL_PREFIX is in your PATH"
        exit 1
    fi

    # Quick version check
    local version
    version=$(llama-server --version 2>&1 | head -1 || echo "unknown")
    log_info "llama-server version: $version"

    # Check Metal support
    if llama-server --help 2>&1 | grep -qi "metal\|gpu"; then
        log_info "Metal GPU support: detected"
    else
        log_warn "Could not confirm Metal support from --help output"
        log_warn "Metal should still work if built correctly on Apple Silicon"
    fi
}

# --- Main ---
main() {
    echo "=========================================="
    echo "  ATLAS: Build llama.cpp (Metal)"
    echo "=========================================="
    echo ""
    echo "  Target: Apple Silicon ($(uname -m))"
    echo "  Install prefix: $INSTALL_PREFIX"
    echo "  Build directory: $BUILD_DIR"
    echo ""

    check_prerequisites
    build_llama
    install_binaries
    verify_install

    echo ""
    echo "=========================================="
    echo "  Build Complete!"
    echo "=========================================="
    echo ""
    echo "llama-server is ready. Start it with:"
    echo "  ./inference/entrypoint-macos.sh"
    echo ""
    echo "Or use the full stack:"
    echo "  ./scripts/start-macos.sh"
    echo ""
}

main "$@"
