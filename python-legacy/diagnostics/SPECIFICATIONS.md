# Environment Specifications

Captured **2026-06-14**. This is the machine the benchmarks in `PERFORMANCE.md`
were run on.

## Hardware

| | |
|---|---|
| Machine | Scaleway Apple silicon bare-metal (type M2-L, zone PAR1) |
| Chip | Apple M2 Pro |
| CPU cores | 10 |
| Memory | 16 GB LPDDR5 |
| Disk | 512 GB (~423 GB free) |

## Operating system

| | |
|---|---|
| OS | macOS Tahoe 26.3.2 (build 25D2140) |
| Kernel | Darwin 25.3.0 |
| Architecture | arm64 (Apple Silicon) |

## Python / ML stack

| | |
|---|---|
| Python | 3.9.6 (system `/usr/bin/python3`) |
| Virtualenv | `.venv` (created by `scripts/install.sh`) |
| PyTorch | 2.8.0 |
| Compute backend | Metal Performance Shaders (MPS) available; CUDA not available |
| transformers / audio | per `requirements-live.txt` (transformers, librosa, noisereduce, soundfile, scipy, ...) |
| WER (benchmark only) | jiwer 4.0.0 |

## Model

| | |
|---|---|
| Checkpoint | fine-tuned Whisper-small, `models/whisper-atc` |
| Weights | `model.safetensors` (~922 MB), downloaded from Hugging Face `SingularityUS/ATC-whisper-v1` |
| Device resolution | `auto` → MPS on this machine (`PYTORCH_ENABLE_MPS_FALLBACK=1` for the few Whisper ops MPS lacks) |

Notes:
- macOS ships Python 3.9.6; the live + diagnostic code is 3.9-compatible.
- ffmpeg / Homebrew are **not** installed — only needed for live online feeds, not for these diagnostics (which read local WAVs via librosa).
