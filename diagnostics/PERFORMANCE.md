# Performance — fine-tuned ATC Whisper on Apple Silicon

Captured **2026-06-14** on the machine in `SPECIFICATIONS.md` (Apple M2 Pro,
macOS 26.3.2, PyTorch 2.8.0). WER uses the project's normalized methodology
(lowercase, no punctuation, no a/an/the) via jiwer — comparable to the
training-time evaluations.

## 1. Proof-of-life diagnostic (5 bundled snippets)

`diagnostics/diagnostic.py`, device `auto` → MPS.

| | |
|---|---|
| Verdict | **PASS — transcriber alive** |
| Device | mps |
| Model load | 0.5 s |
| Mean WER | 16.6% (budget 50%) |
| First snippet | 6.6 s (one-time MPS kernel warmup) |
| Warm snippets | ~0.5 s each |

Small clip set; the WER here is noisy and not a benchmark — it only confirms the
model loads on the GPU and produces sane ATC text.

## 2. 100-sample latency + WER benchmark

100 samples randomly drawn (seed 0) from the **held-out ATCO2+ATCoSIM validation
split** (`data/atc_combined/val_metadata.json`, 2,024 samples; ~95% ATCoSIM).
Pipeline = audio preprocessing (noise reduction etc.) + fine-tuned Whisper.
Warmup (2 inferences) excluded from latency. 396 s of audio processed.

| Metric | **MPS (Apple GPU)** | CPU (M2 Pro) | GPU speedup |
|---|---|---|---|
| Corpus WER | 7.1% | 7.1% | identical |
| Corpus CER | 3.9% | 3.9% | identical |
| Mean per-sample WER | 6.1% | 6.1% | identical |
| **Avg total latency / sample** | **543 ms** | 948 ms | **1.75×** |
| &nbsp;&nbsp;— model inference | 512 ms | 924 ms | 1.80× |
| &nbsp;&nbsp;— preprocessing | 31 ms | 24 ms | (CPU-bound) |
| Median total latency | 539 ms | 942 ms | 1.75× |
| p90 / p95 total | 606 / 681 ms | 1042 / 1125 ms | — |
| Throughput | 1.84 samp/s | 1.05 samp/s | 1.75× |
| Real-time factor | 0.137× (7.3× RT) | 0.239× (4.2× RT) | — |

Startup costs (excluded from per-sample latency): model load ~0.4 s + a one-time
~6 s MPS kernel warmup on the first inference.

### Takeaways
- **MPS and CPU produce identical accuracy** (bit-for-bit per-sample WER) — the
  Metal backend + MPS-fallback path is numerically safe, no correctness regression.
- **MPS is ~1.75× faster** end-to-end (~1.8× on pure inference) and runs ~7×
  faster than real-time, leaving ample headroom for live feeds.
- **WER caveat:** this is the validation split and predominantly ATCoSIM (clean
  studio-quality readback), so 7.1% is optimistic relative to noisy live VHF.

Raw per-sample reports: `result_mps.json`, `result_cpu.json`.

### Reproduce
```bash
python diagnostics/build_bundle.py --n 100
python diagnostics/bench_mps.py --device auto --json diagnostics/result_mps.json
python diagnostics/bench_mps.py --device cpu  --json diagnostics/result_cpu.json
```
(Requires the local `data/` datasets, which are not committed.)
