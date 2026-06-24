# Diagnostics

Proof-of-life and performance diagnostics for the fine-tuned ATC Whisper
transcriber, plus the captured environment specs and benchmark results so we can
come back to them later.

## Contents

| File | Purpose |
|------|---------|
| `diagnostic.py` | Cross-platform proof-of-life: loads the model on the auto-detected device (CUDA / Apple MPS / CPU), transcribes the bundled snippets in `tests/diagnostic_data/`, prints a PASS/FAIL verdict. |
| `diagnostic.sh` / `diagnostic.ps1` | Platform launchers for `diagnostic.py` (activate `.venv`, then run). |
| `build_bundle.py` | Build a self-contained ~100-sample benchmark bundle from the held-out validation split (`data/atc_combined/val_metadata.json`). Output: `diagnostics/bundle/` (gitignored, regenerable). |
| `bench_mps.py` | Latency + WER benchmark over a bundle. Times preprocessing vs. inference separately, reports jiwer WER/CER and the latency distribution + real-time factor. `--device auto` uses Apple MPS on Apple Silicon. |
| `SPECIFICATIONS.md` | Hardware / OS / Python / PyTorch environment the benchmarks were captured on. |
| `PERFORMANCE.md` | Captured proof-of-life + 100-sample WER/latency results (MPS vs CPU). |
| `result_mps.json` / `result_cpu.json` | Raw per-sample benchmark reports (100 samples each). |

## Proof of life (works on any machine — snippets ship with the repo)

```bash
python diagnostics/diagnostic.py                                      # auto-detect device
bash diagnostics/diagnostic.sh                                        # macOS / Linux launcher
powershell -ExecutionPolicy Bypass -File diagnostics/diagnostic.ps1   # Windows launcher
python diagnostics/diagnostic.py --device mps --json report.json      # force backend + JSON
```

Exit code `0` = PASS, `1` = FAIL (handy for CI / smoke gating).

## Latency + WER benchmark (needs the local training datasets)

The benchmark runs on held-out validation audio under `data/`, which is **not**
committed (it's regenerable). On a machine that has the datasets:

```bash
# 1. Build a 100-sample bundle from the validation split (seeded, reproducible)
python diagnostics/build_bundle.py --n 100

# 2. Benchmark on the Apple GPU and/or CPU
python diagnostics/bench_mps.py --device auto --json diagnostics/result_mps.json
python diagnostics/bench_mps.py --device cpu  --json diagnostics/result_cpu.json
```

`bench_mps.py` needs `jiwer` (`pip install jiwer`) in addition to the live
requirements. See `PERFORMANCE.md` for the latest captured numbers and
`SPECIFICATIONS.md` for the environment.
