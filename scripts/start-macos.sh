#!/bin/bash
set -euo pipefail

# ATLAS Unified Launcher — Apple Silicon
#
# Starts all 5 ATLAS services:
#   1. llama-server (native macOS, Metal GPU)
#   2. geometric-lens, v3-service, sandbox, atlas-proxy (Docker)
#
# Usage:
#   ./scripts/start-macos.sh                          # start everything
#   ./scripts/start-macos.sh --build                  # rebuild Docker images first
#   ./scripts/start-macos.sh --external-llama         # skip llama-server (already running on :8080)
#   ./scripts/start-macos.sh --external-llama 9090    # already running on custom port
#   ATLAS_LLAMA_PORT=9090 ./scripts/start-macos.sh    # same via env var

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

LLAMA_PORT="${ATLAS_LLAMA_PORT:-8080}"
LLAMA_PID_FILE="$REPO_DIR/.llama-server.pid"
LLAMA_LOG_FILE="$REPO_DIR/logs/llama-server.log"
BUILD_FLAG=false
EXTERNAL_LLAMA=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD_FLAG=true; shift ;;
        --external-llama)
            EXTERNAL_LLAMA=true
            # Optional: next arg can be a port number
            if [[ ${2:-} =~ ^[0-9]+$ ]]; then
                LLAMA_PORT="$2"
                shift
            fi
            shift
            ;;
        *) shift ;;
    esac
done

# --- Pre-flight checks ---
preflight() {
    log_info "Pre-flight checks..."

    # Check macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only"
        exit 1
    fi

    if [[ "$EXTERNAL_LLAMA" == "true" ]]; then
        log_info "External llama-server mode — skipping binary/model checks"
        log_info "Expecting llama-server at http://localhost:$LLAMA_PORT"

        # Verify it's actually reachable
        if ! curl -sf --max-time 5 "http://localhost:$LLAMA_PORT/health" &>/dev/null; then
            log_error "Cannot reach llama-server at http://localhost:$LLAMA_PORT/health"
            log_error "Make sure it's running before using --external-llama"
            exit 1
        fi
        log_info "External llama-server is healthy"
    else
        # Check llama-server binary
        if ! command -v llama-server &>/dev/null; then
            log_error "llama-server not found in PATH"
            log_error "Build it first: ./scripts/build-llama-metal.sh"
            log_error "Or use --external-llama if it's already running"
            exit 1
        fi

        # Check model file
        local model_file="$ATLAS_MODELS_DIR/$ATLAS_MAIN_MODEL"
        if [[ ! -f "$model_file" ]]; then
            log_error "Model not found: $model_file"
            log_error "Download it: ./scripts/download-models-macos.sh"
            exit 1
        fi
    fi

    # Check Docker Desktop
    if ! docker info &>/dev/null; then
        log_error "Docker is not running. Start Docker Desktop first."
        exit 1
    fi

    log_info "Pre-flight OK"
}

# --- Start llama-server natively ---
start_llama() {
    # Check if already running
    if [[ -f "$LLAMA_PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LLAMA_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log_info "llama-server already running (PID $old_pid)"
            return
        fi
        rm -f "$LLAMA_PID_FILE"
    fi

    # Also check if port is in use
    if lsof -i ":$LLAMA_PORT" -sTCP:LISTEN &>/dev/null; then
        log_warn "Port $LLAMA_PORT already in use — assuming llama-server is running"
        return
    fi

    log_info "Starting llama-server (Metal backend)..."
    mkdir -p "$(dirname "$LLAMA_LOG_FILE")"

    MODEL_PATH="$ATLAS_MODELS_DIR/$ATLAS_MAIN_MODEL" \
    LLAMA_PORT="$LLAMA_PORT" \
        nohup "$REPO_DIR/inference/entrypoint-macos.sh" \
        > "$LLAMA_LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$LLAMA_PID_FILE"
    log_info "llama-server started (PID $pid, log: $LLAMA_LOG_FILE)"

    # Wait for health
    log_info "Waiting for llama-server to load model..."
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -sf "http://localhost:$LLAMA_PORT/health" &>/dev/null; then
            log_info "llama-server healthy (took ${waited}s)"
            return
        fi
        # Check if process died
        if ! kill -0 "$pid" 2>/dev/null; then
            log_error "llama-server process died. Check log: $LLAMA_LOG_FILE"
            tail -20 "$LLAMA_LOG_FILE" 2>/dev/null
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    log_error "llama-server did not become healthy within ${max_wait}s"
    log_error "Check log: $LLAMA_LOG_FILE"
    exit 1
}

# --- Start Docker services ---
start_docker_services() {
    log_info "Starting Docker services..."

    cd "$REPO_DIR"

    local compose_args=("-f" "docker-compose.macos.yml")

    if [[ "$BUILD_FLAG" == "true" ]]; then
        log_info "Building Docker images (--build)..."
        docker compose "${compose_args[@]}" build
    fi

    # Export port for docker-compose interpolation
    export ATLAS_LLAMA_PORT="$LLAMA_PORT"

    docker compose "${compose_args[@]}" up -d

    log_info "Docker services started"
}

# --- Health check all services ---
health_check_all() {
    log_info "Checking service health..."
    local all_healthy=true

    local services=(
        "llama-server:localhost:$LLAMA_PORT"
        "geometric-lens:localhost:${ATLAS_LENS_PORT:-8099}"
        "v3-service:localhost:${ATLAS_V3_PORT:-8070}"
        "sandbox:localhost:${ATLAS_SANDBOX_PORT:-30820}"
        "atlas-proxy:localhost:${ATLAS_PROXY_PORT:-8090}"
    )

    # Give Docker services time to start
    sleep 5

    for entry in "${services[@]}"; do
        local name="${entry%%:*}"
        local addr="${entry#*:}"
        if curl -sf "http://$addr/health" &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}   $name  (http://$addr)"
        else
            echo -e "  ${RED}[FAIL]${NC} $name  (http://$addr)"
            all_healthy=false
        fi
    done

    if [[ "$all_healthy" == "true" ]]; then
        echo ""
        log_info "All services healthy!"
    else
        echo ""
        log_warn "Some services not yet healthy — they may still be starting."
        log_warn "Re-check with: ./scripts/verify-macos.sh"
    fi
}

# --- Main ---
main() {
    echo "=========================================="
    echo "  ATLAS — Apple Silicon Launcher"
    echo "=========================================="
    echo ""
    print_hardware_summary
    echo ""

    preflight
    if [[ "$EXTERNAL_LLAMA" == "false" ]]; then
        start_llama
    else
        log_info "Using external llama-server on port $LLAMA_PORT"
    fi
    start_docker_services
    health_check_all

    echo ""
    echo "=========================================="
    echo "  ATLAS is running!"
    echo "=========================================="
    echo ""
    echo "Endpoints:"
    echo "  llama-server:   http://localhost:$LLAMA_PORT"
    echo "  geometric-lens: http://localhost:${ATLAS_LENS_PORT:-8099}"
    echo "  v3-service:     http://localhost:${ATLAS_V3_PORT:-8070}"
    echo "  sandbox:        http://localhost:${ATLAS_SANDBOX_PORT:-30820}"
    echo "  atlas-proxy:    http://localhost:${ATLAS_PROXY_PORT:-8090}"
    echo ""
    echo "Logs:"
    echo "  llama-server: tail -f $LLAMA_LOG_FILE"
    echo "  Docker:       docker compose -f docker-compose.macos.yml logs -f"
    echo ""
    echo "Stop:  ./scripts/stop-macos.sh"
    echo ""
}

main "$@"
