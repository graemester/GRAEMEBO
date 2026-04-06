#!/bin/bash
set -euo pipefail

# ATLAS Health Check — Apple Silicon
# Verifies all services are running and healthy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/config-macos.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LLAMA_PORT="${ATLAS_LLAMA_PORT:-8080}"
LENS_PORT="${ATLAS_LENS_PORT:-8099}"
V3_PORT="${ATLAS_V3_PORT:-8070}"
SANDBOX_PORT="${ATLAS_SANDBOX_PORT:-30820}"
PROXY_PORT="${ATLAS_PROXY_PORT:-8090}"

PASSED=0
FAILED=0
WARNINGS=0

check_service() {
    local name="$1"
    local url="$2"
    local timeout="${3:-5}"

    if curl -sf --max-time "$timeout" "$url" &>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} $name  ($url)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $name  ($url)"
        FAILED=$((FAILED + 1))
    fi
}

check_binary() {
    local name="$1"
    local cmd="$2"

    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} $name: $(command -v "$cmd")"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $name: not found in PATH"
        FAILED=$((FAILED + 1))
    fi
}

check_file() {
    local name="$1"
    local path="$2"

    if [[ -f "$path" ]]; then
        local size
        size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo "?")
        local human_size
        human_size=$(ls -lh "$path" | awk '{print $5}')
        echo -e "  ${GREEN}[PASS]${NC} $name: $path ($human_size)"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $name: $path not found"
        FAILED=$((FAILED + 1))
    fi
}

check_docker() {
    if docker info &>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} Docker Desktop: running"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Docker Desktop: not running"
        FAILED=$((FAILED + 1))
    fi
}

main() {
    echo "=========================================="
    echo "  ATLAS Health Check — Apple Silicon"
    echo "=========================================="
    echo ""

    # Hardware
    echo "Hardware:"
    detect_macos_hardware
    print_hardware_summary
    echo ""

    # Prerequisites
    echo "Prerequisites:"
    check_binary "llama-server" "llama-server"
    check_binary "cmake" "cmake"
    check_docker
    check_file "Model" "$ATLAS_MODELS_DIR/$ATLAS_MAIN_MODEL"
    echo ""

    # Services
    echo "Services:"
    check_service "llama-server"   "http://localhost:$LLAMA_PORT/health"
    check_service "geometric-lens" "http://localhost:$LENS_PORT/health"
    check_service "v3-service"     "http://localhost:$V3_PORT/health"
    check_service "sandbox"        "http://localhost:$SANDBOX_PORT/health"
    check_service "atlas-proxy"    "http://localhost:$PROXY_PORT/health"
    echo ""

    # Docker containers
    echo "Docker containers:"
    docker compose -f "$REPO_DIR/docker-compose.macos.yml" ps 2>/dev/null || echo "  (compose not running)"
    echo ""

    # llama-server details (if running)
    if curl -sf "http://localhost:$LLAMA_PORT/health" &>/dev/null; then
        echo "llama-server info:"
        local slots_info
        slots_info=$(curl -sf "http://localhost:$LLAMA_PORT/slots" 2>/dev/null || echo "")
        if [[ -n "$slots_info" ]]; then
            local n_slots
            n_slots=$(echo "$slots_info" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
            echo "  Active slots: $n_slots"
        fi
        local props
        props=$(curl -sf "http://localhost:$LLAMA_PORT/props" 2>/dev/null || echo "")
        if [[ -n "$props" ]]; then
            echo "  Server props: $(echo "$props" | python3 -c "
import sys, json
p = json.load(sys.stdin)
print(f'  ctx={p.get(\"n_ctx\", \"?\")}, parallel={p.get(\"n_parallel\", \"?\")}, model={p.get(\"model\", \"?\")}')
" 2>/dev/null || echo "  (could not parse)")"
        fi
        echo ""
    fi

    # Summary
    echo "=========================================="
    echo "  Results: $PASSED passed, $FAILED failed"
    echo "=========================================="

    if [[ $FAILED -gt 0 ]]; then
        echo ""
        echo "Troubleshooting:"
        echo "  - Start all services: ./scripts/start-macos.sh"
        echo "  - llama-server log:   tail -f logs/llama-server.log"
        echo "  - Docker logs:        docker compose -f docker-compose.macos.yml logs"
        exit 1
    fi
}

main "$@"
