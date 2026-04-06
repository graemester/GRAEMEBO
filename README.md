<p align="center">
  <img src="docs/images/banner.png" alt="ATLAS Banner"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-V3.0.1--M4-blue" alt="Version"/>
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%20|%20M2%20|%20M3%20|%20M4-orange" alt="Apple Silicon"/>
  <img src="https://img.shields.io/badge/benchmarks-pending-lightgrey" alt="Benchmarks"/>
  <img src="https://img.shields.io/badge/license-Source%20Available-blue" alt="License"/>
</p>

<h1 align="center">A.T.L.A.S-M4</h1>
<p align="center"><b>Adaptive Test-time Learning and Autonomous Specialization — Apple Silicon Fork</b></p>

An Apple Silicon port of [ATLAS](https://github.com/itigges22/ATLAS). Runs the V3 pipeline on a Mac using Metal GPU acceleration instead of NVIDIA CUDA.

This fork differs from upstream in meaningful ways — different model (Qwen3.5-9B vs Qwen3-14B), different quantization (Q4_K_M on 16GB machines), different context lengths, different hardware characteristics. **We do not inherit upstream's benchmark numbers.** Our own benchmarks are in progress.

> **Fork of** [itigges22/ATLAS](https://github.com/itigges22/ATLAS). Pipeline architecture and V3 methodology by the original author.

---

## Quick Start

```bash
git clone https://github.com/graemester/GRAEMEBO.git
cd GRAEMEBO
./scripts/atlas-macos.sh
```

That's it. The script auto-detects everything and handles every scenario:

| State | What happens |
|-------|-------------|
| llama-server not installed | Installs Homebrew deps, builds llama.cpp with Metal |
| llama-server installed but not running | Downloads model if needed, launches with Metal |
| llama-server running with wrong model | Downloads Qwen3.5-9B, hot-swaps or restarts |
| llama-server running with correct model | Reuses as-is |
| Docker images not built | Builds on first run |
| Docker services already running | Skips, uses existing containers |

To shut down:

```bash
./scripts/atlas-macos.sh stop
```

### Prerequisites

- **Mac with Apple Silicon** (M1/M2/M3/M4, 16GB+ unified memory)
- **Docker Desktop for Mac** (running)
- **Xcode Command Line Tools** (`xcode-select --install`)

Everything else is installed automatically.

---

## What Changed From Upstream

This isn't a thin wrapper. The deployment model is fundamentally different.

| | Upstream ATLAS | ATLAS-M4 |
|---|---|---|
| **GPU** | NVIDIA CUDA | Apple Metal |
| **Model** | Qwen3-14B (Q4_K_M / Q6_K) | Qwen3.5-9B (Q4_K_M / Q6_K) |
| **llama-server** | Docker container (Linux) | Native macOS process |
| **Deployment** | K3s / Docker Compose / bare metal | Docker Compose only |
| **Install** | `scripts/install.sh` (root, K3s, GPU Operator) | `scripts/atlas-macos.sh` (one script, no root) |
| **Container → LLM** | `http://llama-server:8080` (Docker network) | `http://host.docker.internal:8080` (Docker Desktop bridge) |
| **Parallelism** | Up to 4 slots, 164K context | Memory-dependent (see below) |
| **Benchmarks** | 74.6% LCB pass@1-v(k=3) on Qwen3-14B | **Not yet benchmarked** |

### Why the benchmarks don't carry over

- **Different model.** Upstream's 74.6% was on Qwen3-14B. We run Qwen3.5-9B — a different architecture (DeltaNet hybrid vs standard transformer), different parameter count, different training data.
- **Different quantization on 16GB.** Upstream tested Q4_K_M on a GPU with 16GB of dedicated VRAM. On a 16GB Mac, unified memory is shared with the OS, so we have less effective memory for the model and shorter context windows.
- **Different context length.** Upstream runs 164K context with 4 parallel slots. A 16GB Mac runs 32K context with 1 slot. Context length affects pipeline stages that rely on long prompts (PlanSearch, PR-CoT repair).
- **Different inference characteristics.** Metal's throughput profile and memory bandwidth differ from CUDA. This changes generation speed, which affects timeout-sensitive pipeline stages.

The pipeline *logic* is identical. But the inputs to that pipeline (model quality, context budget, parallelism) are different enough that upstream scores don't apply.

### Memory Configurations

The entrypoint auto-tunes based on your Mac's unified memory:

| Mac | Model | Parallel | Context | Est. tok/s |
|-----|-------|----------|---------|-----------|
| 16GB (M4 Mini) | Qwen3.5-9B **Q4_K_M** | 1 | 32K | ~30-40 |
| 24GB (M4 Pro) | Qwen3.5-9B **Q6_K** | 2 | 64K | ~40-50 |
| 36GB+ (M4 Max) | Qwen3.5-9B **Q6_K** | 4 | 164K | ~50-60 |

---

## Benchmarks

### ATLAS-M4 (This Fork)

**Status: Pending.** We have not yet validated pipeline performance on Apple Silicon.

Planned benchmarks:
- LiveCodeBench v5 — Qwen3.5-9B Q4_K_M on M4 16GB (our primary target)
- LiveCodeBench v5 — Qwen3.5-9B Q6_K on M4 Pro 24GB
- CLI reliability suite (L1-L8) on Apple Silicon
- Throughput: tok/s across M4 / M4 Pro / M4 Max

Results will be published here once complete.

### Upstream Reference (Different Configuration)

For context, the upstream ATLAS project reported these results on different hardware and a different model. **These do not apply to this fork** — see [why the benchmarks don't carry over](#why-the-benchmarks-dont-carry-over) above.

| Benchmark | Score | Model | Hardware |
|-----------|-------|-------|----------|
| LiveCodeBench v5 | 74.6% pass@1-v(k=3) | Qwen3-14B Q4_K_M | RTX 5060 Ti 16GB |

<details>
<summary>Upstream V3 ablation breakdown (Qwen3-14B)</summary>

| Condition | Configuration | Pass Rate | Delta |
|-----------|---------------|-----------|-------|
| A | Baseline (no V3) | 54.9% | — |
| B | +Phase 1 (PlanSearch + BudgetForcing + DivSampling) | 67.3% | +12.4pp |
| C | +Phase 1+2 (Lens routing) | 67.3% | +0.0pp |
| D | +Phase 1+3 (self-verified refinement) | 74.6% | +7.3pp |

Source: [V3_ABLATION_STUDY.md](docs/reports/V3_ABLATION_STUDY.md)

</details>

### Cost

ATLAS costs only electricity. M-series chips draw 15-40W for GPU workloads vs 165W for the RTX 5060 Ti, so per-task energy cost is substantially lower.

---

## Using ATLAS

Once running, the main endpoint is **atlas-proxy** on port 8090. It's OpenAI-compatible.

### With curl

```bash
curl -N http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-9B",
    "messages": [{"role": "user", "content": "Write a Python function to find prime numbers"}],
    "max_tokens": 8192,
    "stream": true
  }'
```

### With the ATLAS CLI

```bash
pip install -e .
atlas
```

### With any OpenAI-compatible client

Point it at `http://localhost:8090` as the base URL. Works with Aider, Continue, Open Interpreter, etc.

### Service Endpoints

| Service | Port | Purpose |
|---------|------|---------|
| **atlas-proxy** | 8090 | Main API (OpenAI-compatible + agent endpoint) |
| llama-server | 8080 | LLM inference (Metal GPU) |
| geometric-lens | 8099 | C(x)/G(x) code scoring |
| v3-service | 8070 | V3 pipeline orchestration |
| sandbox | 30820 | Isolated code execution |

---

## Architecture

```
                          ┌──────────────────┐
                          │   atlas-proxy    │ ← OpenAI-compatible API
                          │    (port 8090)   │
                          └──────┬───────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
   ┌──────────────────┐ ┌───────────────┐ ┌──────────────────┐
   │   v3-service     │ │ geometric-lens│ │     sandbox      │
   │  (port 8070)     │ │  (port 8099)  │ │   (port 30820)   │
   │  V3 pipeline     │ │  C(x)/G(x)   │ │  code execution  │
   └────────┬─────────┘ └───────┬───────┘ └──────────────────┘
            │                   │
            └─────────┬─────────┘
                      ▼
           ┌──────────────────┐
           │  llama-server    │ ← NATIVE macOS (Metal GPU)
           │   (port 8080)   │
           │  Qwen3.5-9B     │
           └──────────────────┘

   ── Docker Desktop ──────────────────────────    ── Native ──
   geometric-lens, v3-service, sandbox,            llama-server
   atlas-proxy (all CPU, Python/Go)                (Metal GPU)
```

The proxy classifies request difficulty (T0-T3). Simple questions go straight to llama-server. Harder coding tasks route through the V3 pipeline for multi-candidate generation, Geometric Lens scoring, sandbox testing, and self-verified repair.

Full architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

---

## Scripts

| Script | Purpose |
|--------|---------|
| **`scripts/atlas-macos.sh`** | **Main entry point** — auto-detects and handles everything |
| `scripts/check-llama.sh` | Validate a running llama-server (8 connectivity + capability checks) |
| `scripts/verify-macos.sh` | Health check all 5 services + hardware summary |
| `scripts/build-llama-metal.sh` | Build llama.cpp from source with Metal |
| `scripts/download-models-macos.sh` | Download Qwen3.5-9B (auto-selects quantization) |
| `scripts/stop-macos.sh` | Shut down all services |

For most users, only `atlas-macos.sh` is needed.

---

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Chip | Apple M1 | M4 or later |
| Unified Memory | 16 GB | 24 GB+ |
| Disk | 15 GB free | For model weights + Docker images |
| macOS | 13.0+ (Ventura) | 15.0+ (Sequoia) |
| Docker Desktop | 4.0+ | Latest |

---

## Known Limitations

- **No benchmarks yet.** We have not validated pipeline performance on this hardware/model combination. Upstream scores do not apply.
- **16GB Macs run with reduced settings.** Single inference slot, 32K context, Q4_K_M quantization. Functional, but the pipeline has less room to work with than on upstream's 16GB dedicated VRAM setup.
- **Geometric Lens may need retraining.** The C(x) scoring model was trained on embeddings from upstream's model. Qwen3.5-9B produces 4096-dim embeddings (same dimensionality), but the embedding distribution may differ enough to affect scoring accuracy.
- **Docker Desktop sandbox is weaker than Linux.** Security isolation is less strict than bare Linux containers.
- **No K3s path.** Docker Compose only — simpler for single-machine macOS, but no orchestration.

---

## Documentation

| Document | Description |
|----------|-------------|
| **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Two-layer architecture, component design |
| **[CLI.md](docs/CLI.md)** | CLI usage, streaming output |
| **[API.md](docs/API.md)** | HTTP API endpoints and formats |
| **[CONFIGURATION.md](docs/CONFIGURATION.md)** | Environment variables and config |
| **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** | Common issues and solutions |
| **[V3_ABLATION_STUDY.md](docs/reports/V3_ABLATION_STUDY.md)** | Upstream ablation methodology and results |
| **[CHANGELOG.md](CHANGELOG.md)** | Release history |

---

## License

Licensed under the [A.T.L.A.S Source Available License v1.0](LICENSE).

## Acknowledgments

ATLAS was created by [Isaac Tigges](https://github.com/itigges22). This fork adapts it for Apple Silicon. Pipeline design, V3 methodology, and benchmark infrastructure by the original project.
