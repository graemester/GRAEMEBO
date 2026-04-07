#!/bin/bash
set -euo pipefail

# ============================================================================
# ATLAS-M4 Benchmark Suite — Apple Silicon
# ============================================================================
#
# Runs benchmarks against the ATLAS pipeline on macOS and generates a report.
# All services must be running (use ./scripts/atlas-macos.sh first).
#
# Usage:
#   ./scripts/benchmark-macos.sh                    # full suite
#   ./scripts/benchmark-macos.sh --quick             # smoke test + small sample
#   ./scripts/benchmark-macos.sh --lcb               # LiveCodeBench only
#   ./scripts/benchmark-macos.sh --v3                # V3 pipeline (LCB, full)
#   ./scripts/benchmark-macos.sh --throughput         # throughput measurement only
#   ./scripts/benchmark-macos.sh --resume             # resume interrupted run
#
# Results saved to: benchmark/results/m4_<date>/
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/config-macos.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

# Ports
LLAMA_PORT="${ATLAS_LLAMA_PORT:-8080}"
LENS_PORT="${ATLAS_LENS_PORT:-8099}"
V3_PORT="${ATLAS_V3_PORT:-8070}"
SANDBOX_PORT="${ATLAS_SANDBOX_PORT:-30820}"
PROXY_PORT="${ATLAS_PROXY_PORT:-8090}"

# Run config
DATE_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$REPO_DIR/benchmark/results/m4_$DATE_STAMP"
LOG_FILE="$RUN_DIR/benchmark.log"
REPORT_FILE="$RUN_DIR/REPORT.md"
CRASH_LOG="$RUN_DIR/crash_log.json"

# Defaults
MODE="full"
RESUME_FLAG=""
MAX_RETRIES=3
TOTAL_CRASHES=0

# On 16GB Mac, run 1 task at a time (llama has 1 slot).
# On 24GB+, can do 2 concurrent.
if [[ $DETECTED_SYS_MEM_GB -ge 24 ]]; then
    PARALLEL_TASKS=2
else
    PARALLEL_TASKS=1
fi

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)      MODE="quick"; shift ;;
        --lcb)        MODE="lcb"; shift ;;
        --v3)         MODE="v3"; shift ;;
        --throughput) MODE="throughput"; shift ;;
        --resume)     RESUME_FLAG="--resume"; shift ;;
        *)            shift ;;
    esac
done

# ── Signal handling ──
INTERRUPTED=0
cleanup() {
    if [[ $INTERRUPTED -eq 1 ]]; then
        echo ""
        log_error "Interrupted — partial results saved to $RUN_DIR"
        generate_report "INTERRUPTED"
    fi
    exit 1
}
trap 'INTERRUPTED=1; cleanup' SIGINT SIGTERM

# ============================================================================
# PRE-FLIGHT
# ============================================================================
preflight() {
    log_step "Pre-flight checks"

    local all_ok=true
    local services=(
        "llama-server:$LLAMA_PORT"
        "geometric-lens:$LENS_PORT"
        "v3-service:$V3_PORT"
        "sandbox:$SANDBOX_PORT"
        "atlas-proxy:$PROXY_PORT"
    )

    for entry in "${services[@]}"; do
        local name="${entry%%:*}"
        local port="${entry#*:}"
        if curl -sf --max-time 5 "http://localhost:$port/health" &>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} $name (:$port)"
        else
            echo -e "  ${RED}[FAIL]${NC} $name (:$port)"
            all_ok=false
        fi
    done

    if [[ "$all_ok" != "true" ]]; then
        log_error "Not all services are healthy. Run: ./scripts/atlas-macos.sh"
        exit 1
    fi

    # Check python3 and benchmark module
    if ! python3 -c "import benchmark" 2>/dev/null; then
        log_warn "benchmark module not in path — adding $REPO_DIR to PYTHONPATH"
        export PYTHONPATH="${REPO_DIR}:${PYTHONPATH:-}"
    fi

    log_info "All services healthy"
}

# ============================================================================
# SYSTEM INFO
# ============================================================================
collect_system_info() {
    # macOS system stats (replaces nvidia-smi + free)
    local mem_pressure
    mem_pressure=$(memory_pressure 2>/dev/null | head -1 || echo "unknown")

    echo -e "  ${CYAN}Chip:${NC}     $DETECTED_CHIP"
    echo -e "  ${CYAN}Memory:${NC}   ${DETECTED_SYS_MEM_GB}GB unified ($mem_pressure)"
    echo -e "  ${CYAN}GPU:${NC}      ${DETECTED_GPU_CORES} cores"
    echo -e "  ${CYAN}Mem BW:${NC}   $DETECTED_MEM_BW"
    echo -e "  ${CYAN}Model:${NC}    $ATLAS_MAIN_MODEL"
    echo -e "  ${CYAN}Parallel:${NC} $PARALLEL_TASKS task(s)"
}

show_progress() {
    local output_dir="$1"
    local total_tasks="${2:-0}"

    if [[ -d "$output_dir" ]]; then
        local completed
        completed=$(find "$output_dir" -name "result_*.json" 2>/dev/null | wc -l | tr -d ' ')
        local passed
        passed=$(grep -rl '"passed": true' "$output_dir"/result_*.json 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        local failed=$((completed - passed))
        local pct=0
        [[ $total_tasks -gt 0 ]] && pct=$((completed * 100 / total_tasks))
        local rate=0
        [[ $completed -gt 0 ]] && rate=$((passed * 100 / completed))
        echo -e "  ${CYAN}Progress: ${completed}/${total_tasks} (${pct}%) | Pass: ${passed} | Fail: ${failed} | Rate: ${rate}%${NC}"
    fi
}

# ============================================================================
# THROUGHPUT TEST
# ============================================================================
run_throughput_test() {
    log_step "Throughput measurement"

    local results_file="$RUN_DIR/throughput.json"
    mkdir -p "$RUN_DIR"

    log_info "Sending test prompts to measure tok/s..."

    python3 - "$LLAMA_PORT" "$results_file" << 'PYEOF'
import json, sys, time, urllib.request, urllib.error

port = sys.argv[1]
results_file = sys.argv[2]
base_url = f"http://localhost:{port}"

prompts = [
    {"label": "short", "content": "Write a Python function that adds two numbers.", "max_tokens": 128},
    {"label": "medium", "content": "Write a Python function that implements binary search on a sorted list. Include docstring and edge cases.", "max_tokens": 512},
    {"label": "long", "content": "Write a Python class that implements a min-heap with insert, extract_min, peek, and heapify methods. Include comprehensive error handling and docstrings.", "max_tokens": 1024},
]

results = []
for p in prompts:
    payload = json.dumps({
        "messages": [{"role": "user", "content": p["content"]}],
        "max_tokens": p["max_tokens"],
        "temperature": 0.0,
        "stream": False,
    }).encode()

    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
        elapsed = time.monotonic() - t0

        usage = data.get("usage", {})
        completion_tokens = usage.get("completion_tokens", 0)
        prompt_tokens = usage.get("prompt_tokens", 0)
        tok_s = completion_tokens / elapsed if elapsed > 0 else 0

        result = {
            "label": p["label"],
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "elapsed_seconds": round(elapsed, 2),
            "tokens_per_second": round(tok_s, 1),
        }
        results.append(result)
        print(f"  {p['label']:8s}: {completion_tokens:4d} tokens in {elapsed:.1f}s = {tok_s:.1f} tok/s")
    except Exception as e:
        print(f"  {p['label']:8s}: FAILED ({e})")
        results.append({"label": p["label"], "error": str(e)})

# Summary
successful = [r for r in results if "tokens_per_second" in r]
if successful:
    avg_tps = sum(r["tokens_per_second"] for r in successful) / len(successful)
    print(f"\n  Average: {avg_tps:.1f} tok/s")

with open(results_file, "w") as f:
    json.dump({"results": results}, f, indent=2)
PYEOF

    log_info "Results saved to $results_file"
}

# ============================================================================
# SMOKE TEST (quick validation)
# ============================================================================
run_smoke_test() {
    log_step "Smoke test"

    local smoke_dir="$RUN_DIR/smoke"
    mkdir -p "$smoke_dir"

    log_info "Testing generation, embeddings, and sandbox..."

    python3 - "$LLAMA_PORT" "$LENS_PORT" "$SANDBOX_PORT" "$smoke_dir" << 'PYEOF'
import json, sys, time, urllib.request

llama_port, lens_port, sandbox_port, out_dir = sys.argv[1:5]
results = {}

# Test 1: Chat completions
print("  1. Chat completions...", end=" ", flush=True)
try:
    payload = json.dumps({
        "messages": [{"role": "user", "content": "Write a Python function: def add(a, b): that returns a+b"}],
        "max_tokens": 128, "temperature": 0.0,
    }).encode()
    req = urllib.request.Request(f"http://localhost:{llama_port}/v1/chat/completions",
                                 data=payload, headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    elapsed = time.monotonic() - t0
    content = data["choices"][0]["message"]["content"]
    results["completions"] = {"passed": True, "elapsed": round(elapsed, 2), "response_length": len(content)}
    print(f"OK ({elapsed:.1f}s)")
except Exception as e:
    results["completions"] = {"passed": False, "error": str(e)}
    print(f"FAIL ({e})")

# Test 2: Embeddings
print("  2. Embeddings...", end=" ", flush=True)
try:
    payload = json.dumps({"input": "def add(a, b): return a + b", "model": "default"}).encode()
    req = urllib.request.Request(f"http://localhost:{llama_port}/v1/embeddings",
                                 data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    dim = len(data["data"][0]["embedding"])
    results["embeddings"] = {"passed": True, "dimension": dim}
    print(f"OK (dim={dim})")
except Exception as e:
    results["embeddings"] = {"passed": False, "error": str(e)}
    print(f"FAIL ({e})")

# Test 3: Geometric Lens
print("  3. Geometric Lens...", end=" ", flush=True)
try:
    req = urllib.request.Request(f"http://localhost:{lens_port}/health")
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read())
    results["lens"] = {"passed": True, "status": data.get("status", "unknown")}
    print(f"OK ({data.get('status', '?')})")
except Exception as e:
    results["lens"] = {"passed": False, "error": str(e)}
    print(f"FAIL ({e})")

# Test 4: Sandbox execution
print("  4. Sandbox...", end=" ", flush=True)
try:
    payload = json.dumps({"code": "print('hello')", "language": "python"}).encode()
    req = urllib.request.Request(f"http://localhost:{sandbox_port}/execute",
                                 data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    passed = data.get("stdout", "").strip() == "hello"
    results["sandbox"] = {"passed": passed, "stdout": data.get("stdout", "").strip()}
    print(f"{'OK' if passed else 'FAIL'} (stdout={data.get('stdout', '').strip()!r})")
except Exception as e:
    results["sandbox"] = {"passed": False, "error": str(e)}
    print(f"FAIL ({e})")

# Summary
all_passed = all(r.get("passed", False) for r in results.values())
print(f"\n  {'All tests passed!' if all_passed else 'Some tests failed.'}")

with open(f"{out_dir}/smoke_results.json", "w") as f:
    json.dump(results, f, indent=2)

sys.exit(0 if all_passed else 1)
PYEOF
}

# ============================================================================
# BENCHMARK PHASES
# ============================================================================

run_phase() {
    local phase_name="$1"
    local command="$2"
    local checkpoint="$3"
    local output_dir="$4"
    local total_tasks="${5:-100}"
    local retry_count=0

    # Skip if already completed
    if [[ -f "$checkpoint" ]]; then
        log_info "Skipping $phase_name (already complete)"
        return 0
    fi

    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        log_info "Running $phase_name (attempt $((retry_count + 1))/$MAX_RETRIES)"
        mkdir -p "$output_dir"

        local start_time
        start_time=$(date +%s)
        local exit_code=0

        eval "$command $RESUME_FLAG" 2>&1 | tee -a "$LOG_FILE" &
        local pid=$!

        # Progress monitor
        while kill -0 $pid 2>/dev/null; do
            sleep 60
            show_progress "$output_dir" "$total_tasks"
        done

        wait $pid || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            touch "$checkpoint"
            local end_time
            end_time=$(date +%s)
            local duration=$(( end_time - start_time ))
            local tasks_done
            tasks_done=$(find "$output_dir" -name "result_*.json" 2>/dev/null | wc -l | tr -d ' ')
            local tasks_passed
            tasks_passed=$(grep -rl '"passed": true' "$output_dir"/result_*.json 2>/dev/null | wc -l | tr -d ' ' || echo 0)
            log_info "$phase_name complete: $tasks_passed/$tasks_done passed (${duration}s)"
            return 0
        fi

        retry_count=$((retry_count + 1))
        TOTAL_CRASHES=$((TOTAL_CRASHES + 1))
        log_warn "$phase_name crashed (attempt $retry_count/$MAX_RETRIES)"

        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log_info "Waiting 15s before retry..."
            sleep 15
        fi
    done

    log_error "$phase_name FAILED after $MAX_RETRIES attempts"
    return 1
}

# ============================================================================
# REPORT GENERATION
# ============================================================================
generate_report() {
    local status="${1:-COMPLETE}"

    local suite_end
    suite_end=$(date +%s)
    local suite_duration=$(( suite_end - SUITE_START ))
    local hours=$(( suite_duration / 3600 ))
    local minutes=$(( (suite_duration % 3600) / 60 ))

    mkdir -p "$(dirname "$REPORT_FILE")"

    cat > "$REPORT_FILE" << EOF
# ATLAS-M4 Benchmark Report

**Generated:** $(date '+%Y-%m-%d %H:%M:%S')
**Status:** $status
**Runtime:** ${hours}h ${minutes}m
**Mode:** $MODE

---

## Hardware

| Property | Value |
|----------|-------|
| Chip | $DETECTED_CHIP |
| Unified Memory | ${DETECTED_SYS_MEM_GB}GB |
| GPU Cores | $DETECTED_GPU_CORES |
| Memory Bandwidth | $DETECTED_MEM_BW |

## Model

| Property | Value |
|----------|-------|
| Model | $ATLAS_MAIN_MODEL |
| Parallel Slots | $PARALLEL_TASKS |
| Inference Port | $LLAMA_PORT |

## Run Health

| Metric | Value |
|--------|-------|
| Total Crashes | $TOTAL_CRASHES |
| Total Wall-Clock | ${hours}h ${minutes}m |

---

EOF

    # Throughput results
    if [[ -f "$RUN_DIR/throughput.json" ]]; then
        cat >> "$REPORT_FILE" << 'EOF'
## Throughput

EOF
        python3 -c "
import json
with open('$RUN_DIR/throughput.json') as f:
    data = json.load(f)
print('| Test | Tokens | Time (s) | tok/s |')
print('|------|--------|----------|-------|')
for r in data.get('results', []):
    if 'error' in r:
        print(f'| {r[\"label\"]} | - | - | FAILED |')
    else:
        print(f'| {r[\"label\"]} | {r[\"completion_tokens\"]} | {r[\"elapsed_seconds\"]} | {r[\"tokens_per_second\"]} |')
" >> "$REPORT_FILE" 2>/dev/null || echo "(throughput data unavailable)" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    # Benchmark phase results
    for phase_dir in "$RUN_DIR"/*/; do
        local phase_name
        phase_name=$(basename "$phase_dir")
        [[ "$phase_name" == "smoke" || "$phase_name" == "throughput.json" ]] && continue

        local task_files
        task_files=$(find "$phase_dir" -name "result_*.json" 2>/dev/null | wc -l | tr -d ' ')
        [[ "$task_files" -eq 0 ]] && continue

        echo "## $phase_name" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"

        python3 -c "
import json, glob, os

phase_dir = '$phase_dir'
files = sorted(glob.glob(os.path.join(phase_dir, 'result_*.json')) +
               glob.glob(os.path.join(phase_dir, 'per_task', 'result_*.json')))

total = len(files)
passed = 0
phase_counts = {}
total_tokens = 0
total_time = 0

for f in files:
    try:
        with open(f) as fh:
            d = json.load(fh)
        if d.get('passed'):
            passed += 1
        ps = d.get('phase_solved', 'unknown')
        phase_counts[ps] = phase_counts.get(ps, 0) + 1
        total_tokens += d.get('tokens_generated', 0)
        total_time += d.get('execution_time_ms', 0) / 1000
    except:
        pass

rate = (passed / total * 100) if total > 0 else 0
print(f'| Metric | Value |')
print(f'|--------|-------|')
print(f'| Tasks | {total} |')
print(f'| Passed | {passed} |')
print(f'| **Pass Rate** | **{rate:.1f}%** |')
if total_tokens:
    print(f'| Total Tokens | {total_tokens:,} |')
if total_time:
    print(f'| Total Time | {total_time:.0f}s |')
print()

if phase_counts:
    print('### Phase Breakdown')
    print()
    print('| Phase | Tasks Solved |')
    print('|-------|-------------|')
    for p in sorted(phase_counts.keys()):
        print(f'| {p} | {phase_counts[p]} |')
    print()
" >> "$REPORT_FILE" 2>/dev/null || true
    done

    # Footer
    cat >> "$REPORT_FILE" << EOF

---

## Notes

- These results are specific to this hardware and model configuration.
- Upstream ATLAS reported 74.6% on Qwen3-14B / RTX 5060 Ti — **not comparable** to these results.
- Run directory: \`$RUN_DIR\`

---

*Generated by ATLAS-M4 Benchmark Suite*
EOF

    log_info "Report saved to $REPORT_FILE"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    echo "=========================================="
    echo "  ATLAS-M4 Benchmark Suite"
    echo "=========================================="
    echo ""
    echo "  Mode: $MODE"
    echo ""
    collect_system_info
    echo ""

    preflight

    mkdir -p "$RUN_DIR"
    echo "ATLAS-M4 Benchmark — $(date)" > "$LOG_FILE"
    echo "[]" > "$CRASH_LOG"

    SUITE_START=$(date +%s)

    # Set environment for benchmark Python code
    export LLAMA_URL="http://localhost:$LLAMA_PORT"
    export RAG_API_URL="http://localhost:$LENS_PORT"
    export ATLAS_SANDBOX_URL="http://localhost:$SANDBOX_PORT"
    export ATLAS_PARALLEL_TASKS="$PARALLEL_TASKS"
    export ATLAS_LLM_PARALLEL="0"  # serialize — single slot on 16GB
    export PYTHONPATH="${REPO_DIR}:${PYTHONPATH:-}"

    cd "$REPO_DIR"

    case "$MODE" in
        quick)
            run_smoke_test
            run_throughput_test
            ;;

        throughput)
            run_throughput_test
            ;;

        lcb)
            run_throughput_test

            # LiveCodeBench pass@1 (baseline, no V3 pipeline)
            run_phase "LCB pass@1 (baseline)" \
                "python3 -m benchmark.cli --livecodebench --k 1 --output '$RUN_DIR/lcb_baseline'" \
                "$RUN_DIR/.checkpoint_lcb_baseline" \
                "$RUN_DIR/lcb_baseline" \
                880
            ;;

        v3)
            run_throughput_test

            # V3 full pipeline on LiveCodeBench
            run_phase "V3 LCB (full pipeline)" \
                "python3 -m benchmark.v3_runner --run-id 'm4_${DATE_STAMP}' --selection-strategy lens" \
                "$RUN_DIR/.checkpoint_v3_lcb" \
                "$RUN_DIR/m4_${DATE_STAMP}/v3_lcb/per_task" \
                880
            ;;

        full)
            run_smoke_test
            run_throughput_test

            log_step "Phase 1: Baseline benchmarks"

            # HumanEval pass@1
            run_phase "HumanEval pass@1" \
                "python3 -m benchmark.cli --humaneval --k 1 --output '$RUN_DIR/humaneval_pass1'" \
                "$RUN_DIR/.checkpoint_humaneval_pass1" \
                "$RUN_DIR/humaneval_pass1" \
                164

            # MBPP pass@1
            run_phase "MBPP pass@1" \
                "python3 -m benchmark.cli --mbpp --k 1 --output '$RUN_DIR/mbpp_pass1'" \
                "$RUN_DIR/.checkpoint_mbpp_pass1" \
                "$RUN_DIR/mbpp_pass1" \
                500

            # LiveCodeBench pass@1 (baseline)
            run_phase "LCB pass@1 (baseline)" \
                "python3 -m benchmark.cli --livecodebench --k 1 --output '$RUN_DIR/lcb_baseline'" \
                "$RUN_DIR/.checkpoint_lcb_baseline" \
                "$RUN_DIR/lcb_baseline" \
                880

            log_step "Phase 2: V3 pipeline"

            # V3 full pipeline on LiveCodeBench
            run_phase "V3 LCB (full pipeline)" \
                "python3 -m benchmark.v3_runner --run-id 'm4_${DATE_STAMP}' --selection-strategy lens" \
                "$RUN_DIR/.checkpoint_v3_lcb" \
                "$RUN_DIR/m4_${DATE_STAMP}/v3_lcb/per_task" \
                880

            log_step "Phase 3: CLI reliability"

            # CLI reliability test (L1-L8)
            run_phase "CLI reliability (L1-L8)" \
                "python3 -m benchmark.cli --custom --k 1 --output '$RUN_DIR/cli_reliability'" \
                "$RUN_DIR/.checkpoint_cli_reliability" \
                "$RUN_DIR/cli_reliability" \
                100
            ;;
    esac

    # Generate report
    log_step "Report"
    generate_report "COMPLETE"

    echo ""
    echo "=========================================="
    echo "  Benchmark Complete!"
    echo "=========================================="
    echo ""
    echo "  Report:  $REPORT_FILE"
    echo "  Results: $RUN_DIR"
    if [[ $TOTAL_CRASHES -gt 0 ]]; then
        echo -e "  Crashes: ${YELLOW}$TOTAL_CRASHES${NC}"
    fi
    echo ""
    echo "  View report: cat $REPORT_FILE"
    echo ""
}

main "$@"
