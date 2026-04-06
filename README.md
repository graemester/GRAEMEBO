<p align="center">
  <img src="docs/images/banner.png" alt="ATLAS Banner"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-V3.0.1--M4-blue" alt="Version"/>
  <img src="https://img.shields.io/badge/LiveCodeBench-74.6%25_pass%401--v(k%3D3)-green" alt="LCB"/>
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%20|%20M2%20|%20M3%20|%20M4-orange" alt="Apple Silicon"/>
  <img src="https://img.shields.io/badge/license-Source%20Available-blue" alt="License"/>
</p>

<h1 align="center">A.T.L.A.S-M4</h1>
<p align="center"><b>Adaptive Test-time Learning and Autonomous Specialization — Apple Silicon Fork</b></p>

An Apple Silicon adaptation of [ATLAS](https://github.com/itigges22/ATLAS), the pipeline that achieves **74.6% LiveCodeBench pass@1-v(k=3)** with a frozen local model on a single device. This fork replaces NVIDIA CUDA with Apple Metal, letting you run the full ATLAS V3 pipeline on a Mac.

The premise is the same: wrap a frozen smaller model in intelligent infrastructure — structured generation, energy-based verification, self-verified repair — and it competes with frontier API models. No fine-tuning, no API calls, no cloud. **One Mac, one script.**

> **Fork of** [itigges22/ATLAS](https://github.com/itigges22/ATLAS). All credit for the ATLAS pipeline architecture, V3 methodology, and benchmark results goes to the original author.

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

## How It Differs From Upstream ATLAS

Upstream ATLAS targets Linux with NVIDIA GPUs. This fork makes one architectural change: **llama-server runs natively on macOS** (Metal GPU) while the remaining 4 services run in Docker Desktop. The pipeline logic is identical.

| Component | Upstream | This Fork |
|-----------|----------|-----------|
| GPU backend | CUDA (NVIDIA) | **Metal (Apple Silicon)** |
| llama-server | Docker container | **Native macOS process** |
| Other services | Docker on Linux | Docker Desktop for Mac |
| Container → LLM routing | `http://llama-server:8080` | `http://host.docker.internal:8080` |
| Deployment | K3s / Docker Compose | **Docker Compose only** |
| Install | `scripts/install.sh` (requires root, K3s, GPU Operator) | **`scripts/atlas-macos.sh`** (one script, no root) |

### Memory Configurations

The entrypoint auto-tunes based on your Mac's unified memory:

| Mac | Model | Parallel | Context | Est. tok/s |
|-----|-------|----------|---------|-----------|
| 16GB (M4 Mini) | Qwen3.5-9B **Q4_K_M** | 1 | 32K | ~30-40 |
| 24GB (M4 Pro) | Qwen3.5-9B **Q6_K** | 2 | 64K | ~40-50 |
| 36GB+ (M4 Max) | Qwen3.5-9B **Q6_K** | 4 | 164K | ~50-60 |

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

## Scripts

| Script | Purpose |
|--------|---------|
| **`scripts/atlas-macos.sh`** | **Main entry point** — auto-detects and handles everything |
| `scripts/check-llama.sh` | Validate a running llama-server (8 connectivity + capability checks) |
| `scripts/verify-macos.sh` | Health check all 5 services + hardware summary |
| `scripts/build-llama-metal.sh` | Build llama.cpp from source with Metal |
| `scripts/download-models-macos.sh` | Download Qwen3.5-9B (auto-selects quantization) |
| `scripts/stop-macos.sh` | Shut down all services |

For most users, only `atlas-macos.sh` is needed. The other scripts exist for debugging and advanced use.

---

## Benchmark Results

> These results are from the **upstream ATLAS project** on NVIDIA hardware. The pipeline logic is identical on Apple Silicon — same scores, different wall-clock time.

| Benchmark | Score | Hardware | Method |
|-----------|-------|----------|--------|
| **LiveCodeBench v5** | **74.6% pass@1-v(k=3)** | RTX 5060 Ti 16GB | V3 pipeline: PlanSearch + self-verified PR-CoT repair |

<details>
<summary><b>V3 ablation breakdown (Qwen3-14B, upstream)</b></summary>

| Condition | Configuration | Pass Rate | Delta |
|-----------|---------------|-----------|-------|
| A | Baseline (no V3) | 54.9% | — |
| B | +Phase 1 (PlanSearch + BudgetForcing + DivSampling) | 67.3% | +12.4pp |
| C | +Phase 1+2 (Lens routing) | 67.3% | +0.0pp |
| D | +Phase 1+3 (self-verified refinement) | **74.6%** | +7.3pp |

Full report: [V3_ABLATION_STUDY.md](docs/reports/V3_ABLATION_STUDY.md)

</details>

### Cost

ATLAS costs only electricity. On Apple Silicon, the M-series chips draw 15-40W for GPU workloads vs 165W for the RTX 5060 Ti — making per-task cost even lower than upstream's ~$0.004/task estimate.

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

- **16GB Macs run with reduced settings.** Single inference slot, 32K context, Q4_K_M quantization. Works, but slower and shorter context than 24GB+ machines.
- **Docker Desktop sandbox is weaker than Linux.** The `read_only` + `no-new-privileges` + `tmpfs` security flags work but the isolation is less strict than bare Linux.
- **9B model not yet formally benchmarked.** The 74.6% result was on Qwen3-14B upstream. Qwen3.5-9B with the same pipeline should score similarly or higher based on published baselines, but formal benchmarks are pending.
- **No K3s path.** Upstream supports K3s/Kubernetes deployment. This fork is Docker Compose only — simpler for single-machine macOS, but no orchestration benefits.

---

## Documentation

| Document | Description |
|----------|-------------|
| **[SETUP.md](docs/SETUP.md)** | Upstream installation guide (Linux/NVIDIA) |
| **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Two-layer architecture, component design |
| **[CLI.md](docs/CLI.md)** | CLI usage, streaming output |
| **[API.md](docs/API.md)** | HTTP API endpoints and formats |
| **[CONFIGURATION.md](docs/CONFIGURATION.md)** | Environment variables and config |
| **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** | Common issues and solutions |
| **[V3_ABLATION_STUDY.md](docs/reports/V3_ABLATION_STUDY.md)** | Ablation methodology and results |
| **[CHANGELOG.md](CHANGELOG.md)** | Release history |

---

## License

Licensed under the [A.T.L.A.S Source Available License v1.0](LICENSE).

## Acknowledgments

ATLAS was created by [Isaac Tigges](https://github.com/itigges22) at Virginia Tech. This fork adapts it for Apple Silicon. All pipeline design, benchmark methodology, and research credit belongs to the original project.
