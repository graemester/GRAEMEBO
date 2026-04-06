#!/bin/bash
# V3.1: Qwen3.5-9B — Apple Silicon (Metal backend)
#
# Optimized for Mac Mini M4 16GB unified memory.
# Metal backend replaces CUDA — same llama.cpp flags, different GPU backend.
#
# Memory budget (16GB unified):
#   macOS reserve:     ~4-5 GB
#   Model Q4_K_M:      ~5.5 GB  (Q6_K: ~7.5 GB — tight but possible)
#   KV cache (1 slot): ~0.4 GB
#   Compute buffers:   ~2.5 GB
#   Total:             ~8.4 GB  (leaves ~7.6 GB for OS + Docker services)
#
# For 24GB+ machines: use Q6_K, --parallel 2, -c 65536
# For 36GB+ machines: use Q6_K, --parallel 4, -c 163840
#
# DeltaNet hybrid architecture: minimal KV cache (mostly recurrent state).
# Self-embeddings: 4096-dim (Qwen3.5 hidden_size).

set -euo pipefail

# --- Memory-based auto-configuration ---
TOTAL_MEM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}')

if [[ ${TOTAL_MEM_GB:-0} -ge 36 ]]; then
    # 36GB+: full config, matches original CUDA setup
    DEFAULT_CTX=163840
    DEFAULT_PARALLEL=4
    DEFAULT_BATCH=4096
    DEFAULT_MODEL="Qwen3.5-9B-Q6_K.gguf"
elif [[ ${TOTAL_MEM_GB:-0} -ge 24 ]]; then
    # 24GB: comfortable headroom
    DEFAULT_CTX=65536
    DEFAULT_PARALLEL=2
    DEFAULT_BATCH=4096
    DEFAULT_MODEL="Qwen3.5-9B-Q6_K.gguf"
else
    # 16GB: conservative — single slot, short context
    DEFAULT_CTX=32768
    DEFAULT_PARALLEL=1
    DEFAULT_BATCH=2048
    DEFAULT_MODEL="Qwen3.5-9B-Q4_K_M.gguf"
fi

# --- Configurable parameters (env overrides auto-config) ---
MODEL_FILE="${MODEL_PATH:-./models/${DEFAULT_MODEL}}"
CTX_LENGTH="${CONTEXT_LENGTH:-${DEFAULT_CTX}}"
PARALLEL="${PARALLEL_SLOTS:-${DEFAULT_PARALLEL}}"
BATCH="${BATCH_SIZE:-${DEFAULT_BATCH}}"

KV_CACHE_K="${KV_CACHE_TYPE_K:-q8_0}"
KV_CACHE_V="${KV_CACHE_TYPE_V:-q4_0}"

HOST="${LLAMA_HOST:-0.0.0.0}"
PORT="${LLAMA_PORT:-8080}"

# --- Validate model exists ---
if [[ ! -f "$MODEL_FILE" ]]; then
    echo "ERROR: Model file not found: $MODEL_FILE"
    echo "Run: ./scripts/download-models-macos.sh"
    exit 1
fi

echo "=== ATLAS V3.1: Qwen3.5-9B — Apple Silicon (Metal) ==="
echo "  System memory: ${TOTAL_MEM_GB}GB unified"
echo "  Model: $MODEL_FILE"
echo "  Context: $CTX_LENGTH | KV: K=$KV_CACHE_K V=$KV_CACHE_V | Parallel: $PARALLEL"
echo "  Batch: $BATCH | Unbatch: $BATCH"
echo "  Embeddings: ENABLED (4096-dim Qwen3.5 self-embeddings)"
echo "  Speculative decoding: DISABLED (not supported for Qwen3.5)"
echo "  Backend: Metal (Apple GPU)"
echo ""

exec llama-server \
  -m "$MODEL_FILE" \
  -c "$CTX_LENGTH" \
  -ctk "$KV_CACHE_K" -ctv "$KV_CACHE_V" \
  --parallel "$PARALLEL" \
  --cont-batching \
  -ngl 99 \
  --host "$HOST" \
  --port "$PORT" \
  --flash-attn on \
  --mlock \
  -b "$BATCH" \
  -ub "$BATCH" \
  --embeddings \
  --jinja
