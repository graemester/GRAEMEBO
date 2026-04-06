#!/bin/bash
set -euo pipefail

# ATLAS Shutdown — Apple Silicon
# Stops llama-server (native) and Docker services.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

LLAMA_PID_FILE="$REPO_DIR/.llama-server.pid"

echo "=========================================="
echo "  ATLAS — Shutting Down"
echo "=========================================="
echo ""

# Stop Docker services
log_info "Stopping Docker services..."
cd "$REPO_DIR"
docker compose -f docker-compose.macos.yml down 2>/dev/null || true
log_info "Docker services stopped"

# Stop llama-server
if [[ -f "$LLAMA_PID_FILE" ]]; then
    pid=$(cat "$LLAMA_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        log_info "Stopping llama-server (PID $pid)..."
        kill "$pid"
        # Wait for graceful shutdown
        for i in {1..10}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Force-killing llama-server..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        log_info "llama-server stopped"
    else
        log_info "llama-server not running (stale PID file)"
    fi
    rm -f "$LLAMA_PID_FILE"
else
    # Try to find and kill by port
    local_pid=$(lsof -ti :${ATLAS_LLAMA_PORT:-8080} -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$local_pid" ]]; then
        log_info "Stopping llama-server on port ${ATLAS_LLAMA_PORT:-8080} (PID $local_pid)..."
        kill "$local_pid" 2>/dev/null || true
    else
        log_info "llama-server not running"
    fi
fi

echo ""
log_info "All ATLAS services stopped."
echo ""
