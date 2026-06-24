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

## 3. large-v3-turbo fine-tune — turbo vs small (2026-06-15)

Fine-tuned `openai/whisper-large-v3-turbo` (809M) with the **same** recipe and
data split as the small (244M) model (`train_distil_whisper.py`: lr 5e-6,
effective batch 4, warmup 500, fp16, early-stop patience 2). Trained on a single
NVIDIA **H100** (~59 min; early-stopped at step 1300 / epoch 0.64; best
eval_loss 0.0975). Weights published at **`SingularityUS/ATC-whisper-turbo-v1`**.

### Accuracy — same held-out validation, `evaluate_atco2.py`

| | **turbo (809M)** | small (244M) |
|---|---|---|
| Full 2,024-sample val — WER / CER | **7.83% / 3.58%** | 12.82% / 9.24% |
| 100-sample bundle — WER / CER | **4.5% / 2.7%** | 7.1% / 3.9% |

≈39% relative WER / ≈61% relative CER reduction on the full split — driven mostly
by turbo eliminating the small model's hallucinated insertions (small produced
1,691 spurious insertions on the 2,024-sample set).

### Latency — Mac M2 Pro (MPS), 100-sample bundle

| Metric | **turbo** | small |
|---|---|---|
| Avg total latency / clip | **1,911 ms** | 545 ms |
| median / p90 / p95 | 1,908 / 1,956 / 1,979 ms | 542 / 606 / 668 ms |
| Throughput | 0.52 samp/s | 1.83 samp/s |
| Real-time factor | **0.48× (~2.1× RT)** | 0.14× (~7.3× RT) |
| Model load | 1.6 s | 0.9 s |

Turbo is **~3.5× slower than small on MPS** (vs 2.08× on H100/CUDA — the larger
32-layer / 128-mel encoder scales worse on Metal). It still runs ~2× faster than
real-time, so it keeps up with live feeds, but with less headroom than small.

### Cross-platform speed (small model, for reference)

| Host / backend | Avg latency / clip | Real-time factor |
|---|---|---|
| Mac M2 Pro — MPS | 545 ms | 0.14× (7.3× RT) |
| Mac M2 Pro — CPU | 945 ms | 0.24× (4.2× RT) |
| Windows laptop — CPU* | 3,225 ms | 0.81× (1.2× RT) |

\* RTX 2060 present but unused — the installed PyTorch is a CPU-only build.

### Verdict
The turbo upgrade is **worth it on the Apple-Silicon / MPS host** — a large
accuracy gain for an affordable, still-real-time speed cost — but **not** on the
Windows CPU box (already marginal with small).

Raw records: `diagnostics/turbo_run/` (training log, per-sample eval JSONs,
metrics.csv, loss curve). Windows proof-of-life / bench: `diagnostic_windows.json`,
`result_windows_cpu.json`.
