#!/bin/bash
set -euo pipefail

# ============================================================================
# ATLAS — Apple Silicon (One Script, Zero Flags)
# ============================================================================
#
# Detects everything, handles every scenario, gets ATLAS running.
#
# State matrix this script handles:
#   - llama-server binary:  present / absent  → build if needed
#   - llama-server running: yes / no          → start or reuse
#   - correct model loaded: yes / no          → download + swap/restart
#   - Docker Desktop:       running / not     → prompt to start
#   - Docker images:        built / not       → build if needed
#   - ATLAS containers:     running / not     → start if needed
#
# Just run it:
#   ./scripts/atlas-macos.sh
#
# To shut everything down:
#   ./scripts/atlas-macos.sh stop
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/config-macos.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}── $1 ──${NC}"; }

LLAMA_PORT="${ATLAS_LLAMA_PORT:-8080}"
LLAMA_PID_FILE="$REPO_DIR/.llama-server.pid"
LLAMA_LOG_FILE="$REPO_DIR/logs/llama-server.log"

# Model URLs
QWEN35_9B_Q4_URL="https://huggingface.co/Qwen/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
QWEN35_9B_Q6_URL="https://huggingface.co/Qwen/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q6_K.gguf"

# ============================================================================
# STOP
# ============================================================================
do_stop() {
    echo "=========================================="
    echo "  ATLAS — Shutting Down"
    echo "=========================================="
    echo ""

    # Docker services
    log_info "Stopping Docker services..."
    cd "$REPO_DIR"
    docker compose -f docker-compose.macos.yml down 2>/dev/null || true

    # llama-server (only if we started it)
    if [[ -f "$LLAMA_PID_FILE" ]]; then
        local pid
        pid=$(cat "$LLAMA_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Stopping llama-server (PID $pid)..."
            kill "$pid"
            for _ in {1..10}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$LLAMA_PID_FILE"
    fi

    log_info "All ATLAS services stopped."
    exit 0
}

# ============================================================================
# DETECT STATE
# ============================================================================

# Returns: "running" or "not_running"
detect_llama_server() {
    if curl -sf --max-time 3 "http://localhost:$LLAMA_PORT/health" &>/dev/null; then
        echo "running"
    else
        echo "not_running"
    fi
}

# Returns: "binary_found" or "no_binary"
detect_llama_binary() {
    if command -v llama-server &>/dev/null; then
        echo "binary_found"
    else
        echo "no_binary"
    fi
}

# Returns the model ID string from the running server, or ""
detect_loaded_model() {
    curl -sf --max-time 5 "http://localhost:$LLAMA_PORT/v1/models" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    for m in r.get('data', []):
        print(m.get('id', ''))
except:
    pass
" 2>/dev/null || echo ""
}

# Returns: "true" if Qwen3.5-9B is loaded
is_correct_model() {
    local loaded="$1"
    if echo "$loaded" | grep -qi "qwen3.5-9b\|qwen3_5-9b\|qwen3.5_9b"; then
        echo "true"
    else
        echo "false"
    fi
}

# Find model GGUF file, returns path or ""
find_model_file() {
    local model_name="$ATLAS_MAIN_MODEL"
    local search_dirs=(
        "$ATLAS_MODELS_DIR"
        "$REPO_DIR/models"
        "$HOME/.cache/llama.cpp"
        "$HOME/models"
    )
    for dir in "${search_dirs[@]}"; do
        if [[ -f "$dir/$model_name" ]]; then
            echo "$dir/$model_name"
            return
        fi
    done
    echo ""
}

# Returns: "true" if embeddings endpoint works
detect_embeddings_enabled() {
    local resp
    resp=$(curl -sf --max-time 10 "http://localhost:$LLAMA_PORT/v1/embeddings" \
        -H "Content-Type: application/json" \
        -d '{"input": "test", "model": "default"}' 2>/dev/null || echo "")
    if echo "$resp" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    if r.get('data') and len(r['data']) > 0:
        sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

# ============================================================================
# ACTIONS
# ============================================================================

install_homebrew_deps() {
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    if ! command -v cmake &>/dev/null; then
        log_info "Installing cmake..."
        brew install cmake
    fi
    if ! xcode-select -p &>/dev/null; then
        log_info "Installing Xcode Command Line Tools..."
        xcode-select --install
        echo ""
        log_warn "Xcode CLT install started. Re-run this script after it completes."
        exit 0
    fi
}

build_llama_server() {
    log_info "Building llama.cpp with Metal backend..."
    "$SCRIPT_DIR/build-llama-metal.sh"
}

download_model() {
    local model_name="$ATLAS_MAIN_MODEL"
    local model_path="$ATLAS_MODELS_DIR/$model_name"

    mkdir -p "$ATLAS_MODELS_DIR"

    if [[ -f "$model_path" ]]; then
        log_info "Model already downloaded: $model_name"
        return
    fi

    # Select URL based on model name
    local url
    if [[ "$model_name" == *"Q6_K"* ]]; then
        url="$QWEN35_9B_Q6_URL"
    else
        url="$QWEN35_9B_Q4_URL"
    fi

    log_info "Downloading $model_name (~$([ "$model_name" == *Q6_K* ] && echo '7.5' || echo '5.5')GB)..."
    if ! curl -L -C - --progress-bar -o "$model_path.tmp" "$url"; then
        log_error "Download failed"
        rm -f "$model_path.tmp"
        exit 1
    fi
    mv "$model_path.tmp" "$model_path"
    log_info "Download complete"
}

try_load_model() {
    local model_path="$1"
    local base_url="http://localhost:$LLAMA_PORT"

    # Try runtime model load (llama.cpp router mode)
    log_info "Attempting to hot-swap model via /models/load..."
    local resp
    resp=$(curl -sf --max-time 120 "$base_url/models/load" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$model_path\"}" 2>/dev/null || echo "")

    if [[ -n "$resp" ]]; then
        sleep 3
        local new_model
        new_model=$(detect_loaded_model)
        if [[ "$(is_correct_model "$new_model")" == "true" ]]; then
            log_info "Model hot-swapped successfully!"
            return 0
        fi
    fi
    return 1
}

restart_llama_with_model() {
    local model_path="$1"

    # Kill existing server on our port
    local existing_pid
    existing_pid=$(lsof -ti ":$LLAMA_PORT" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$existing_pid" ]]; then
        log_warn "Stopping existing process on port $LLAMA_PORT (PID $existing_pid)..."
        kill "$existing_pid" 2>/dev/null || true
        sleep 2
        kill -0 "$existing_pid" 2>/dev/null && kill -9 "$existing_pid" 2>/dev/null || true
        sleep 1
    fi

    launch_llama_server "$model_path"
}

launch_llama_server() {
    local model_path="$1"
    mkdir -p "$(dirname "$LLAMA_LOG_FILE")"

    log_info "Starting llama-server with $(basename "$model_path")..."
    MODEL_PATH="$model_path" \
    LLAMA_PORT="$LLAMA_PORT" \
        nohup "$REPO_DIR/inference/entrypoint-macos.sh" \
        > "$LLAMA_LOG_FILE" 2>&1 &

    local pid=$!
    echo "$pid" > "$LLAMA_PID_FILE"
    log_info "llama-server PID $pid (log: $LLAMA_LOG_FILE)"

    wait_for_llama "$pid"
}

wait_for_llama() {
    local pid="${1:-}"
    log_info "Waiting for llama-server to become healthy..."
    local max_wait=180
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -sf "http://localhost:$LLAMA_PORT/health" &>/dev/null; then
            log_info "llama-server healthy (${waited}s)"
            return
        fi
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            log_error "llama-server died. Check: tail -30 $LLAMA_LOG_FILE"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log_error "llama-server not healthy after ${max_wait}s"
    exit 1
}

start_docker_services() {
    cd "$REPO_DIR"
    export ATLAS_LLAMA_PORT="$LLAMA_PORT"

    # Check if images need building
    local needs_build=false
    if ! docker compose -f docker-compose.macos.yml images 2>/dev/null | grep -q "geometric-lens"; then
        needs_build=true
    fi

    if [[ "$needs_build" == "true" ]]; then
        log_info "Building Docker images (first run)..."
        docker compose -f docker-compose.macos.yml build
    fi

    # Check if already running and healthy
    local running_count
    running_count=$(docker compose -f docker-compose.macos.yml ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$running_count" -ge 4 ]]; then
        log_info "Docker services already running ($running_count containers)"
        return
    fi

    log_info "Starting Docker services..."
    docker compose -f docker-compose.macos.yml up -d
}

health_check_all() {
    log_info "Checking all services..."
    local all_healthy=true

    local services=(
        "llama-server:localhost:$LLAMA_PORT"
        "geometric-lens:localhost:${ATLAS_LENS_PORT:-8099}"
        "v3-service:localhost:${ATLAS_V3_PORT:-8070}"
        "sandbox:localhost:${ATLAS_SANDBOX_PORT:-30820}"
        "atlas-proxy:localhost:${ATLAS_PROXY_PORT:-8090}"
    )

    sleep 5

    for entry in "${services[@]}"; do
        local name="${entry%%:*}"
        local addr="${entry#*:}"
        if curl -sf --max-time 5 "http://$addr/health" &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}   $name  (http://$addr)"
        else
            echo -e "  ${RED}[FAIL]${NC} $name  (http://$addr)"
            all_healthy=false
        fi
    done

    if [[ "$all_healthy" != "true" ]]; then
        echo ""
        log_warn "Some services still starting — re-check: ./scripts/verify-macos.sh"
    fi
}

# ============================================================================
# PORT CONFLICT DETECTION
# ============================================================================
check_ports() {
    # Ports ATLAS needs. llama-server port is checked separately (may already
    # be running with a model we can reuse), so we only flag Docker service ports.
    local docker_ports=(
        "geometric-lens:${ATLAS_LENS_PORT:-8099}"
        "v3-service:${ATLAS_V3_PORT:-8070}"
        "sandbox:${ATLAS_SANDBOX_PORT:-30820}"
        "atlas-proxy:${ATLAS_PROXY_PORT:-8090}"
    )

    local conflicts=()

    for entry in "${docker_ports[@]}"; do
        local name="${entry%%:*}"
        local port="${entry#*:}"

        # Check if something non-Docker is already on this port
        local pid
        pid=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null || true)

        if [[ -n "$pid" ]]; then
            # Is it one of our own Docker containers? That's fine.
            local proc_name
            proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            if [[ "$proc_name" == *"com.docker"* || "$proc_name" == *"vpnkit"* || "$proc_name" == *"docker"* ]]; then
                continue
            fi
            conflicts+=("$port:$name:$pid:$proc_name")
        fi
    done

    if [[ ${#conflicts[@]} -eq 0 ]]; then
        log_info "All ports available"
        return
    fi

    # We have conflicts — try to find alternative ports
    log_warn "Port conflicts detected:"
    local any_unresolved=false

    for conflict in "${conflicts[@]}"; do
        IFS=':' read -r port name pid proc_name <<< "$conflict"
        log_warn "  Port $port ($name) in use by $proc_name (PID $pid)"

        # Find a free alternative port
        local alt_port
        alt_port=$(find_free_port "$port")

        if [[ -n "$alt_port" ]]; then
            log_info "  Reassigning $name: $port → $alt_port"
            case "$name" in
                geometric-lens) export ATLAS_LENS_PORT="$alt_port" ;;
                v3-service)     export ATLAS_V3_PORT="$alt_port" ;;
                sandbox)        export ATLAS_SANDBOX_PORT="$alt_port" ;;
                atlas-proxy)    export ATLAS_PROXY_PORT="$alt_port" ;;
            esac
        else
            log_error "  Could not find free port near $port for $name"
            any_unresolved=true
        fi
    done

    # Also check llama port — if occupied by something that isn't llama-server
    local llama_pid
    llama_pid=$(lsof -ti ":$LLAMA_PORT" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$llama_pid" ]]; then
        # Check if it responds to /health like a llama-server
        if ! curl -sf --max-time 2 "http://localhost:$LLAMA_PORT/health" &>/dev/null; then
            local llama_proc
            llama_proc=$(ps -p "$llama_pid" -o comm= 2>/dev/null || echo "unknown")
            log_warn "  Port $LLAMA_PORT (llama-server) in use by $llama_proc (PID $llama_pid) — not a llama-server"
            local alt
            alt=$(find_free_port "$LLAMA_PORT")
            if [[ -n "$alt" ]]; then
                log_info "  Reassigning llama-server: $LLAMA_PORT → $alt"
                LLAMA_PORT="$alt"
                export ATLAS_LLAMA_PORT="$alt"
            else
                any_unresolved=true
            fi
        fi
        # If it IS a llama-server, we'll handle it in step 5
    fi

    if [[ "$any_unresolved" == "true" ]]; then
        log_error "Could not resolve all port conflicts. Free the ports above or set custom ports via env vars:"
        log_error "  ATLAS_LLAMA_PORT, ATLAS_LENS_PORT, ATLAS_V3_PORT, ATLAS_SANDBOX_PORT, ATLAS_PROXY_PORT"
        exit 1
    fi
}

find_free_port() {
    local start_port="$1"
    # Try ports starting from start_port+1, up to start_port+100
    for (( p = start_port + 1; p <= start_port + 100; p++ )); do
        if ! lsof -ti ":$p" -sTCP:LISTEN &>/dev/null; then
            echo "$p"
            return
        fi
    done
    echo ""
}

# ============================================================================
# MAIN LOGIC — detect state, decide actions, execute
# ============================================================================
main() {
    # Handle "stop" subcommand
    if [[ "${1:-}" == "stop" ]]; then
        do_stop
    fi

    echo "=========================================="
    echo "  ATLAS — Apple Silicon"
    echo "=========================================="
    echo ""
    print_hardware_summary
    echo ""

    # --- Platform check ---
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is for macOS only. Use docker-compose.yml + scripts/install.sh for Linux."
        exit 1
    fi
    if [[ "$(uname -m)" != "arm64" ]]; then
        log_error "Apple Silicon (arm64) required."
        exit 1
    fi
    if [[ $DETECTED_SYS_MEM_GB -lt 16 ]]; then
        log_error "ATLAS requires at least 16GB unified memory (detected: ${DETECTED_SYS_MEM_GB}GB)."
        exit 1
    fi

    # ── 1. Docker Desktop ──
    log_step "1/7 Docker Desktop"
    if docker info &>/dev/null; then
        log_info "Docker Desktop is running"
    else
        log_error "Docker Desktop is not running."
        log_error "Start it from Applications, then re-run this script."
        exit 1
    fi

    # ── 2. Port availability ──
    log_step "2/7 Port availability"
    check_ports

    # ── 3. llama-server binary ──
    log_step "3/7 llama-server binary"
    local llama_binary_state
    llama_binary_state=$(detect_llama_binary)
    if [[ "$llama_binary_state" == "binary_found" ]]; then
        log_info "llama-server found: $(command -v llama-server)"
    else
        log_warn "llama-server not found in PATH"
        install_homebrew_deps
        build_llama_server
    fi

    # ── 4. Model file ──
    log_step "4/7 Qwen3.5-9B model"
    local model_path
    model_path=$(find_model_file)
    if [[ -n "$model_path" ]]; then
        log_info "Model found: $model_path"
    else
        log_warn "Model not found locally"
        download_model
        model_path="$ATLAS_MODELS_DIR/$ATLAS_MAIN_MODEL"
    fi

    # ── 5. llama-server running with correct model ──
    log_step "5/7 llama-server process"
    local server_state
    server_state=$(detect_llama_server)

    if [[ "$server_state" == "running" ]]; then
        log_info "llama-server is running on port $LLAMA_PORT"

        # Check what model is loaded
        local loaded_model
        loaded_model=$(detect_loaded_model)
        local correct
        correct=$(is_correct_model "$loaded_model")

        if [[ "$correct" == "true" ]]; then
            log_info "Correct model loaded: $loaded_model"

            # Verify embeddings are enabled
            if [[ "$(detect_embeddings_enabled)" == "true" ]]; then
                log_info "Embeddings endpoint working"
            else
                log_warn "Embeddings not enabled — ATLAS needs --embeddings flag"
                log_warn "Will restart llama-server with correct flags"
                restart_llama_with_model "$model_path"
            fi
        else
            if [[ -n "$loaded_model" ]]; then
                log_warn "Wrong model loaded: $loaded_model"
            else
                log_warn "Could not detect loaded model"
            fi

            # Try hot-swap first, fall back to restart
            if ! try_load_model "$model_path"; then
                log_warn "Hot-swap not available — restarting llama-server"
                restart_llama_with_model "$model_path"
            fi
        fi
    else
        log_info "llama-server not running — starting it"
        launch_llama_server "$model_path"
    fi

    # ── 6. Docker services ──
    log_step "6/7 ATLAS Docker services"
    start_docker_services

    # ── 7. Health check ──
    log_step "7/7 Health check"
    health_check_all

    echo ""
    echo "=========================================="
    echo "  ATLAS is running!"
    echo "=========================================="
    echo ""
    echo "  atlas-proxy:    http://localhost:${ATLAS_PROXY_PORT:-8090}"
    echo "  llama-server:   http://localhost:$LLAMA_PORT"
    echo "  geometric-lens: http://localhost:${ATLAS_LENS_PORT:-8099}"
    echo "  v3-service:     http://localhost:${ATLAS_V3_PORT:-8070}"
    echo "  sandbox:        http://localhost:${ATLAS_SANDBOX_PORT:-30820}"
    echo ""
    echo "  Stop:  ./scripts/atlas-macos.sh stop"
    echo "  Logs:  tail -f logs/llama-server.log"
    echo "         docker compose -f docker-compose.macos.yml logs -f"
    echo ""
}

main "$@"
