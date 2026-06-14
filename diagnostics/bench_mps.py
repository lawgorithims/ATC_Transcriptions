"""
Latency + WER benchmark for the fine-tuned ATC Whisper transcriber.

Runs a bundle of ATC samples (see build_bundle.py) through the SAME pipeline the
project uses (audio preprocessing -> fine-tuned Whisper), on the requested
device. On Apple Silicon, --device auto resolves to the Metal (MPS) GPU.

Reports, matching the project's normalized-WER methodology (lowercase, no
punctuation, no articles) via jiwer:
  * corpus WER/CER and mean per-sample WER
  * per-sample latency broken into preprocess vs. model inference
  * latency distribution (mean/median/p90/p95/min/max) and real-time factor

Usage (from anywhere; imports project modules from the repo root):
    python diagnostics/bench_mps.py --device auto --json diagnostics/result_mps.json
    python diagnostics/bench_mps.py --device cpu  --json diagnostics/result_cpu.json
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def pct(values, q):
    """Linear-interpolation percentile without numpy dependency surprises."""
    if not values:
        return 0.0
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    pos = (len(s) - 1) * (q / 100.0)
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    frac = pos - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def normalize_atc_text(text: str) -> str:
    """Project-standard normalization (copied from atc_normalization.py, which is
    not shipped in the repo): lowercase, drop punctuation and a/an/the, collapse
    spaces -- so WER measures ATC content, comparable to past training evals."""
    if not text or not isinstance(text, str):
        return ""
    s = text.strip().lower()
    s = re.sub(r"[^\w\s]", "", s)
    s = re.sub(r"\b(a|an|the)\b", "", s, flags=re.IGNORECASE)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def main() -> int:
    ap = argparse.ArgumentParser(description="Latency + WER benchmark on the ATC transcriber.")
    ap.add_argument("--bundle", default=str(ROOT / "diagnostics" / "bundle"),
                    help="Bundle dir with bench_metadata.json and audio/.")
    ap.add_argument("--model-path", default=str(ROOT / "models" / "whisper-atc"))
    ap.add_argument("--device", default="auto", help="auto (default), mps, cuda, or cpu.")
    ap.add_argument("--max-samples", type=int, default=None)
    ap.add_argument("--no-preprocess", action="store_true",
                    help="Skip audio preprocessing (inference-only latency).")
    ap.add_argument("--warmup", type=int, default=2,
                    help="Untimed warmup inferences before the timed loop (default 2).")
    ap.add_argument("--json", dest="json_out", default=None)
    args = ap.parse_args()

    import librosa
    import torch
    from jiwer import wer as jiwer_wer, cer as jiwer_cer

    from atc_transcriber import ATCTranscriber, _resolve_device
    from audio_preprocessing import AudioPreprocessor

    resolved = _resolve_device(args.device)

    cuda_ok = torch.cuda.is_available()
    mps_ok = (getattr(torch.backends, "mps", None) is not None
              and torch.backends.mps.is_available())
    print("=" * 64)
    print(" ATC_Transcribe - Latency + WER Benchmark")
    print("=" * 64)
    print(f"  OS / platform : {platform.platform()}")
    print(f"  Machine arch  : {platform.machine()}")
    print(f"  Python        : {platform.python_version()}")
    print(f"  PyTorch       : {torch.__version__}")
    print(f"  CUDA backend  : {'available' if cuda_ok else 'not available'}")
    print(f"  MPS backend   : {'available' if mps_ok else 'not available'}")
    print(f"  Resolved dev. : {resolved}")
    print(f"  Preprocessing : {'OFF' if args.no_preprocess else 'ON (noise reduction etc.)'}")
    print("=" * 64)

    bundle = Path(args.bundle)
    meta = json.loads((bundle / "bench_metadata.json").read_text(encoding="utf-8"))
    if args.max_samples:
        meta = meta[:args.max_samples]
    if not meta:
        print("ERROR: empty bundle metadata", file=sys.stderr)
        return 1

    # Pre-load audio (I/O not counted in latency). Track audio duration for RTF.
    print(f"\nLoading {len(meta)} audio files ...")
    samples = []
    for m in meta:
        audio_path = bundle / m["audio"]
        if not audio_path.exists():
            print(f"  missing: {m['audio']}")
            continue
        audio, sr = librosa.load(str(audio_path), sr=16000, mono=True)
        samples.append({
            "id": m["id"],
            "audio": audio,
            "duration": len(audio) / 16000.0,
            "reference": m["reference"],
            "source": m.get("source", "?"),
        })
    print(f"Loaded {len(samples)} samples "
          f"({sum(s['duration'] for s in samples):.1f}s of audio total).")

    # Preprocessing matches the canonical eval: AudioPreprocessor(sample_rate=16000).
    # We run it in the loop (timed) and let the transcriber handle inference only.
    preproc = None if args.no_preprocess else AudioPreprocessor(sample_rate=16000)

    print(f"\nLoading model on '{resolved}' ...")
    t0 = time.perf_counter()
    transcriber = ATCTranscriber(
        model_path=args.model_path,
        device=args.device,
        enable_preprocessing=False,  # we preprocess explicitly to time it
    )
    load_secs = time.perf_counter() - t0
    print(f"Model loaded in {load_secs:.1f}s")

    # Warmup (compile MPS kernels / fill caches) using the first sample, untimed.
    if samples and args.warmup > 0:
        warm_audio = samples[0]["audio"]
        if preproc is not None:
            warm_audio = preproc.preprocess(warm_audio)
        print(f"Warming up ({args.warmup} inference(s)) ...")
        for _ in range(args.warmup):
            transcriber.transcribe(warm_audio)

    print(f"\nBenchmarking {len(samples)} samples on '{resolved}' ...")
    rows = []
    refs, hyps = [], []
    for i, s in enumerate(samples, 1):
        audio = s["audio"]
        tp0 = time.perf_counter()
        if preproc is not None:
            audio = preproc.preprocess(audio)
        tp1 = time.perf_counter()
        hyp = transcriber.transcribe(audio)
        tp2 = time.perf_counter()

        pre_ms = (tp1 - tp0) * 1000.0
        inf_ms = (tp2 - tp1) * 1000.0
        ref_n = normalize_atc_text(s["reference"])
        hyp_n = normalize_atc_text(hyp)
        sample_wer = jiwer_wer(ref_n, hyp_n) if ref_n else (0.0 if not hyp_n else 1.0)
        refs.append(ref_n)
        hyps.append(hyp_n)
        rows.append({
            "id": s["id"], "source": s["source"], "duration_s": round(s["duration"], 3),
            "preprocess_ms": round(pre_ms, 1), "inference_ms": round(inf_ms, 1),
            "total_ms": round(pre_ms + inf_ms, 1), "wer": round(sample_wer, 4),
            "reference": s["reference"], "hypothesis": hyp,
        })
        if i % 10 == 0 or i == len(samples):
            print(f"  {i:3d}/{len(samples)}  last total={pre_ms + inf_ms:6.0f}ms  WER={sample_wer:5.1%}")

    # Corpus-level metrics over normalized text (project standard).
    # jiwer errors on empty reference strings, so exclude any ref that
    # normalized to empty (e.g. an utterance that was only an article).
    c_refs = [r for r in refs if r]
    c_hyps = [h for r, h in zip(refs, hyps) if r]
    n_empty_ref = len(refs) - len(c_refs)
    corpus_wer = jiwer_wer(c_refs, c_hyps) if c_refs else 0.0
    corpus_cer = jiwer_cer(c_refs, c_hyps) if c_refs else 0.0
    mean_sample_wer = sum(r["wer"] for r in rows) / len(rows)

    pre = [r["preprocess_ms"] for r in rows]
    inf = [r["inference_ms"] for r in rows]
    tot = [r["total_ms"] for r in rows]
    audio_total = sum(s["duration"] for s in samples)
    proc_total_s = sum(tot) / 1000.0
    rtf = proc_total_s / audio_total if audio_total else 0.0

    def stats(label, xs):
        return {
            "label": label,
            "mean_ms": round(sum(xs) / len(xs), 1),
            "median_ms": round(pct(xs, 50), 1),
            "p90_ms": round(pct(xs, 90), 1),
            "p95_ms": round(pct(xs, 95), 1),
            "min_ms": round(min(xs), 1),
            "max_ms": round(max(xs), 1),
        }

    lat = {"preprocess": stats("preprocess", pre),
           "inference": stats("inference", inf),
           "total": stats("total", tot)}

    print("\n" + "=" * 64)
    print(f"  Device            : {resolved}")
    print(f"  Samples           : {len(rows)}")
    print(f"  Model load        : {load_secs:.1f}s")
    print(f"  Corpus WER / CER  : {corpus_wer:.1%} / {corpus_cer:.1%}")
    print(f"  Mean per-sample WER: {mean_sample_wer:.1%}")
    if n_empty_ref:
        print(f"  (excluded {n_empty_ref} sample(s) whose reference normalized to empty)")
    print("  --- latency per sample (ms) ---")
    print(f"  {'stage':<11}{'mean':>8}{'median':>8}{'p90':>8}{'p95':>8}{'max':>8}")
    for k in ("preprocess", "inference", "total"):
        st = lat[k]
        print(f"  {k:<11}{st['mean_ms']:>8.0f}{st['median_ms']:>8.0f}"
              f"{st['p90_ms']:>8.0f}{st['p95_ms']:>8.0f}{st['max_ms']:>8.0f}")
    print(f"  Throughput        : {len(rows) / proc_total_s:.2f} samples/s")
    print(f"  Audio processed   : {audio_total:.1f}s")
    print(f"  Real-time factor  : {rtf:.3f}x  ({'faster' if rtf < 1 else 'slower'} than real-time)")
    print("=" * 64)

    if args.json_out:
        report = {
            "environment": {
                "platform": platform.platform(), "machine": platform.machine(),
                "python": platform.python_version(), "torch": torch.__version__,
                "resolved_device": resolved, "preprocess": not args.no_preprocess,
            },
            "samples": len(rows),
            "model_load_seconds": round(load_secs, 3),
            "corpus_wer": round(corpus_wer, 4),
            "corpus_cer": round(corpus_cer, 4),
            "mean_sample_wer": round(mean_sample_wer, 4),
            "excluded_empty_refs": n_empty_ref,
            "latency_ms": lat,
            "throughput_samples_per_s": round(len(rows) / proc_total_s, 3),
            "audio_seconds": round(audio_total, 2),
            "real_time_factor": round(rtf, 4),
            "per_sample": rows,
        }
        Path(args.json_out).write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nWrote JSON report to {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
