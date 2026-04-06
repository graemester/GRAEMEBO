#!/bin/bash
set -euo pipefail

# ATLAS: llama-server Connectivity & Capability Check
#
# Verifies that a running llama-server is reachable and has the
# features ATLAS requires: health endpoint, completions, embeddings,
# and slot management.
#
# Usage:
#   ./scripts/check-llama.sh              # check localhost:8080
#   ./scripts/check-llama.sh 9090         # check localhost:9090
#   ./scripts/check-llama.sh host:port    # check remote host

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILED=$((FAILED + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }

# Parse target
TARGET="${1:-localhost:8080}"
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    TARGET="localhost:$TARGET"
fi
BASE_URL="http://$TARGET"

# -------------------------------------------------------------------
# Test 1: Basic TCP connectivity
# -------------------------------------------------------------------
check_tcp() {
    echo "1. TCP connectivity"
    local host="${TARGET%%:*}"
    local port="${TARGET##*:}"

    if (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; then
        pass "Port $port open on $host"
    else
        fail "Cannot connect to $host:$port"
        echo ""
        echo "  llama-server does not appear to be running at $TARGET."
        echo "  Start it with: ./inference/entrypoint-macos.sh"
        echo "  Or: ./scripts/start-macos.sh"
        # No point continuing if TCP fails
        return 1
    fi
}

# -------------------------------------------------------------------
# Test 2: /health endpoint
# -------------------------------------------------------------------
check_health() {
    echo "2. Health endpoint"
    local resp
    local http_code

    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL/health" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        pass "/health → 200 OK"
    elif [[ "$http_code" == "000" ]]; then
        fail "/health → connection refused or timeout"
        return 1
    else
        fail "/health → HTTP $http_code"
        return 1
    fi
}

# -------------------------------------------------------------------
# Test 3: /props — server configuration
# -------------------------------------------------------------------
check_props() {
    echo "3. Server properties (/props)"
    local props
    props=$(curl -sf --max-time 5 "$BASE_URL/props" 2>/dev/null || echo "")

    if [[ -z "$props" ]]; then
        warn "/props not available (older llama.cpp build?)"
        return
    fi

    # Parse with python3 (available on all macOS)
    local parsed
    parsed=$(echo "$props" | python3 -c "
import sys, json
try:
    p = json.load(sys.stdin)
    model = p.get('default_generation_settings', {}).get('model', p.get('model', '?'))
    n_ctx = p.get('n_ctx', p.get('default_generation_settings', {}).get('n_ctx', '?'))
    n_parallel = p.get('n_parallel', '?')
    print(f'model={model}')
    print(f'n_ctx={n_ctx}')
    print(f'n_parallel={n_parallel}')
except:
    print('parse_error')
" 2>/dev/null || echo "parse_error")

    if [[ "$parsed" == "parse_error" ]]; then
        warn "/props returned unparseable JSON"
        return
    fi

    local model n_ctx n_parallel
    model=$(echo "$parsed" | grep '^model=' | cut -d= -f2-)
    n_ctx=$(echo "$parsed" | grep '^n_ctx=' | cut -d= -f2-)
    n_parallel=$(echo "$parsed" | grep '^n_parallel=' | cut -d= -f2-)

    pass "/props → model=$model, ctx=$n_ctx, parallel=$n_parallel"

    # Warn if context is too short for ATLAS
    if [[ "$n_ctx" =~ ^[0-9]+$ ]] && [[ "$n_ctx" -lt 4096 ]]; then
        warn "Context length $n_ctx is very short — ATLAS works best with ≥16384"
    fi
}

# -------------------------------------------------------------------
# Test 4: /v1/models — loaded models
# -------------------------------------------------------------------
check_models() {
    echo "4. Available models (/v1/models)"

    local resp
    resp=$(curl -sf --max-time 5 "$BASE_URL/v1/models" 2>/dev/null || echo "")

    if [[ -z "$resp" ]]; then
        warn "/v1/models not available (older llama.cpp build?)"
        return
    fi

    local model_info
    model_info=$(echo "$resp" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    models = r.get('data', [])
    if not models:
        print('empty')
    else:
        for m in models:
            mid = m.get('id', '?')
            owned = m.get('owned_by', '?')
            meta = m.get('meta', {})
            n_params = meta.get('n_params', 0)
            n_ctx_train = meta.get('n_ctx_train', '?')
            quant = ''
            # Try to extract quantization from model id
            for q in ['Q2_K', 'Q3_K_S', 'Q3_K_M', 'Q3_K_L', 'Q4_0', 'Q4_K_S', 'Q4_K_M',
                       'Q5_0', 'Q5_K_S', 'Q5_K_M', 'Q6_K', 'Q8_0', 'F16', 'F32']:
                if q in mid:
                    quant = q
                    break
            size_str = ''
            if n_params > 0:
                if n_params >= 1e9:
                    size_str = f'{n_params/1e9:.1f}B params'
                else:
                    size_str = f'{n_params/1e6:.0f}M params'
            parts = [mid]
            if quant:
                parts.append(f'quant={quant}')
            if size_str:
                parts.append(size_str)
            if n_ctx_train != '?':
                parts.append(f'train_ctx={n_ctx_train}')
            print('model:' + '|'.join(parts))
except Exception as e:
    print(f'parse_error:{e}')
" 2>/dev/null || echo "parse_error")

    if [[ "$model_info" == "parse_error"* ]]; then
        warn "/v1/models returned unparseable response"
        return
    fi

    if [[ "$model_info" == "empty" ]]; then
        fail "No models loaded"
        return
    fi

    local model_count=0
    local has_qwen35=false
    while IFS= read -r line; do
        case "$line" in
            model:*)
                model_count=$((model_count + 1))
                local details="${line#model:}"
                local model_id="${details%%|*}"
                local rest="${details#*|}"
                pass "Model: $model_id"
                # Print additional details
                IFS='|' read -ra parts <<< "$rest"
                for part in "${parts[@]}"; do
                    [[ -n "$part" && "$part" != "$model_id" ]] && info "  $part"
                done
                # Check for Qwen3.5 compatibility
                if [[ "$model_id" == *"qwen"* ]] || [[ "$model_id" == *"Qwen"* ]]; then
                    if [[ "$model_id" == *"3.5"* ]] || [[ "$model_id" == *"3_5"* ]]; then
                        has_qwen35=true
                    fi
                fi
                ;;
        esac
    done <<< "$model_info"

    if [[ $model_count -eq 0 ]]; then
        fail "No models found in response"
    else
        info "$model_count model(s) loaded"
        if [[ "$has_qwen35" == "true" ]]; then
            info "Qwen3.5 detected — compatible with ATLAS V3.1 pipeline"
        else
            warn "No Qwen3.5 model detected — ATLAS V3.1 is tuned for Qwen3.5-9B"
            warn "Other models may work but benchmark scores will differ"
        fi
    fi
}

# -------------------------------------------------------------------
# Test 5: /slots — inference slot availability
# -------------------------------------------------------------------
check_slots() {
    echo "5. Inference slots (/slots)"
    local slots
    slots=$(curl -sf --max-time 5 "$BASE_URL/slots" 2>/dev/null || echo "")

    if [[ -z "$slots" ]]; then
        warn "/slots not available (may need --slot-save-path or newer build)"
        return
    fi

    local slot_info
    slot_info=$(echo "$slots" | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    total = len(s)
    idle = sum(1 for slot in s if slot.get('state', 0) == 0)
    busy = total - idle
    print(f'total={total} idle={idle} busy={busy}')
except:
    print('parse_error')
" 2>/dev/null || echo "parse_error")

    if [[ "$slot_info" == "parse_error" ]]; then
        warn "/slots returned unparseable response"
        return
    fi

    local total idle busy
    total=$(echo "$slot_info" | sed -n 's/.*total=\([0-9]*\).*/\1/p')
    idle=$(echo "$slot_info" | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
    busy=$(echo "$slot_info" | sed -n 's/.*busy=\([0-9]*\).*/\1/p')

    if [[ "$idle" -gt 0 ]]; then
        pass "/slots → $total total, $idle idle, $busy busy"
    elif [[ "$total" -gt 0 ]]; then
        warn "/slots → all $total slot(s) busy — ATLAS requests may queue"
    else
        fail "/slots → no slots available"
    fi
}

# -------------------------------------------------------------------
# Test 6: /v1/chat/completions — generation works
# -------------------------------------------------------------------
check_completions() {
    echo "6. Chat completions (/v1/chat/completions)"

    local resp
    resp=$(curl -sf --max-time 30 "$BASE_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{
            "messages": [{"role": "user", "content": "Say OK"}],
            "max_tokens": 4,
            "temperature": 0
        }' 2>/dev/null || echo "")

    if [[ -z "$resp" ]]; then
        fail "/v1/chat/completions → no response (timeout or connection error)"
        return
    fi

    local has_choices
    has_choices=$(echo "$resp" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    choices = r.get('choices', [])
    if choices:
        content = choices[0].get('message', {}).get('content', '')
        print(f'ok:{content[:50]}')
    elif 'error' in r:
        print(f'error:{r[\"error\"].get(\"message\", \"unknown\")}')
    else:
        print('empty')
except:
    print('parse_error')
" 2>/dev/null || echo "parse_error")

    case "$has_choices" in
        ok:*)
            local reply="${has_choices#ok:}"
            pass "Generation works — response: \"$reply\""
            ;;
        error:*)
            local err="${has_choices#error:}"
            fail "Server returned error: $err"
            ;;
        empty)
            fail "Response had no choices"
            ;;
        *)
            fail "Unparseable response from completions endpoint"
            ;;
    esac
}

# -------------------------------------------------------------------
# Test 7: /v1/embeddings — embedding extraction works
# -------------------------------------------------------------------
check_embeddings() {
    echo "7. Embeddings (/v1/embeddings)"

    local resp
    resp=$(curl -sf --max-time 15 "$BASE_URL/v1/embeddings" \
        -H "Content-Type: application/json" \
        -d '{
            "input": "test embedding",
            "model": "default"
        }' 2>/dev/null || echo "")

    if [[ -z "$resp" ]]; then
        # Try the legacy /embedding endpoint
        resp=$(curl -sf --max-time 15 "$BASE_URL/embedding" \
            -H "Content-Type: application/json" \
            -d '{"content": "test embedding"}' 2>/dev/null || echo "")

        if [[ -z "$resp" ]]; then
            fail "Embeddings not available (is --embeddings flag enabled?)"
            info "ATLAS requires: llama-server --embeddings"
            return
        fi
    fi

    local emb_info
    emb_info=$(echo "$resp" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    # OpenAI-compatible format
    if 'data' in r and len(r['data']) > 0:
        dim = len(r['data'][0].get('embedding', []))
        print(f'ok:{dim}')
    # Legacy llama.cpp format
    elif 'embedding' in r:
        emb = r['embedding']
        if isinstance(emb, list) and len(emb) > 0:
            # Could be nested [[...]] or flat [...]
            if isinstance(emb[0], list):
                dim = len(emb[0])
            else:
                dim = len(emb)
            print(f'ok:{dim}')
        else:
            print('empty')
    elif 'error' in r:
        print(f'error:{r[\"error\"].get(\"message\", str(r[\"error\"]))}')
    else:
        print('unknown_format')
except Exception as e:
    print(f'parse_error:{e}')
" 2>/dev/null || echo "parse_error")

    case "$emb_info" in
        ok:*)
            local dim="${emb_info#ok:}"
            pass "Embeddings work — dimension: $dim"
            if [[ "$dim" == "4096" ]]; then
                info "4096-dim matches Qwen3.5 hidden_size (correct for ATLAS)"
            elif [[ "$dim" != "0" ]] && [[ -n "$dim" ]]; then
                warn "Expected 4096-dim for Qwen3.5, got $dim"
                warn "Geometric Lens C(x) may need retraining for this embedding size"
            fi
            ;;
        error:*)
            fail "Embedding error: ${emb_info#error:}"
            info "Ensure llama-server was started with --embeddings"
            ;;
        empty)
            fail "Embedding response was empty"
            ;;
        *)
            fail "Could not parse embedding response"
            ;;
    esac
}

# -------------------------------------------------------------------
# Test 8: Docker-to-host connectivity (host.docker.internal)
# -------------------------------------------------------------------
check_docker_bridge() {
    echo "8. Docker → host bridge (host.docker.internal)"

    if ! docker info &>/dev/null; then
        warn "Docker not running — skipping bridge check"
        return
    fi

    local port="${TARGET##*:}"
    local bridge_ok
    bridge_ok=$(docker run --rm --network host alpine \
        wget -q -O- --timeout=5 "http://localhost:$port/health" 2>/dev/null || echo "")

    if [[ -z "$bridge_ok" ]]; then
        # Try host.docker.internal (Docker Desktop for Mac)
        bridge_ok=$(docker run --rm alpine \
            wget -q -O- --timeout=5 "http://host.docker.internal:$port/health" 2>/dev/null || echo "")
    fi

    if [[ -n "$bridge_ok" ]]; then
        pass "Docker containers can reach llama-server on port $port"
    else
        fail "Docker containers cannot reach llama-server"
        info "ATLAS Docker services connect via http://host.docker.internal:$port"
        info "Ensure Docker Desktop is running (not just Docker Engine)"
    fi
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
    echo "=========================================="
    echo "  ATLAS: llama-server Connectivity Check"
    echo "=========================================="
    echo ""
    echo "  Target: $BASE_URL"
    echo ""

    check_tcp || { echo ""; echo "Cannot proceed — server unreachable."; exit 1; }
    echo ""

    check_health || { echo ""; echo "Cannot proceed — health check failed."; exit 1; }
    echo ""

    check_props
    echo ""

    check_models
    echo ""

    check_slots
    echo ""

    check_completions
    echo ""

    check_embeddings
    echo ""

    check_docker_bridge
    echo ""

    # Summary
    echo "=========================================="
    if [[ $FAILED -eq 0 ]]; then
        echo -e "  ${GREEN}All checks passed${NC} ($PASSED passed, $WARNINGS warnings)"
        echo ""
        echo "  llama-server at $BASE_URL is fully compatible with ATLAS."
        if [[ $WARNINGS -gt 0 ]]; then
            echo "  Review warnings above for optimal configuration."
        fi
    else
        echo -e "  ${RED}$FAILED check(s) failed${NC} ($PASSED passed, $WARNINGS warnings)"
        echo ""
        echo "  Fix the issues above before running ATLAS."
        echo ""
        echo "  Common fixes:"
        echo "    - Enable embeddings:   add --embeddings flag"
        echo "    - Enable flash attn:   add --flash-attn on"
        echo "    - Increase context:    -c 32768 (minimum recommended)"
    fi
    echo "=========================================="

    [[ $FAILED -gt 0 ]] && exit 1
    exit 0
}

main "$@"
