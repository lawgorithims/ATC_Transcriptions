# Tests

Smoke tests and environment checks.

| Script | Purpose |
|--------|---------|
| `../scripts/diagnostic.py` | Proof-of-life: load the model on the auto-detected device (CUDA / MPS / CPU) and transcribe bundled ATC snippets |
| `test_audio.py` | Audio input/output and preprocessing checks |
| `check_gpu.py` | CUDA / GPU availability check |

Run from project root:

```bash
python tests/check_gpu.py
python tests/test_audio.py
```

## Proof-of-life diagnostic

`scripts/diagnostic.py` is a quick handshake that confirms the fine-tuned
Whisper model loads on this machine's GPU/CPU and produces sane ATC text. It
works the same on NVIDIA/Windows and Apple Silicon — only the resolved device
changes.

```bash
# Cross-platform (auto-detects CUDA, Apple MPS, or CPU):
python scripts/diagnostic.py

# Or via the platform launcher:
bash scripts/diagnostic.sh                                        # macOS / Linux
powershell -ExecutionPolicy Bypass -File scripts/diagnostic.ps1   # Windows

# Force a backend / write a JSON report:
python scripts/diagnostic.py --device cpu
python scripts/diagnostic.py --device mps --json report.json
```

Exit code is `0` on PASS and `1` on FAIL, so it can gate CI or an install check.

`diagnostic_data/` holds the short labeled snippets (~2-4 s each, from the ATCO2
validation set) plus `manifest.json` with their reference transcripts. These are
the only audio files committed to the repo; everything under `data/` is local.
