#!/usr/bin/env python3
"""
Proof-of-life diagnostic for the ATC_Transcribe pipeline.

Runs the fine-tuned Whisper transcriber over a handful of short, labeled ATC
snippets and reports:

  * the environment (OS, machine, PyTorch, available compute backends)
  * the device "auto" resolves to (CUDA on NVIDIA, MPS on Apple Silicon, else CPU)
  * per-snippet transcription, latency, and a normalized word error rate (WER)
  * a single PASS/FAIL verdict

It is a handshake, not an accuracy benchmark: it confirms the model loads on the
selected device and produces sane ATC text. The same script works on
NVIDIA/Windows and Apple Silicon -- the only thing that changes is the resolved
device.

Usage (from project root):
    python scripts/diagnostic.py                 # auto-detect device
    python scripts/diagnostic.py --device cpu    # force a backend
    python scripts/diagnostic.py --device mps    # force Apple Metal
    python scripts/diagnostic.py --json out.json # also write a machine-readable report

Exit code is 0 on PASS, 1 on FAIL (handy for CI / smoke gating).
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
import warnings
from pathlib import Path

# Keep the output readable: silence the chatty transformers/torch warnings that
# are irrelevant to a proof-of-life check. Done before importing torch/transformers.
warnings.filterwarnings("ignore")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "tests" / "diagnostic_data"
MANIFEST = DATA_DIR / "manifest.json"

# This script lives in scripts/, but imports modules from the project root.
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

# Words/articles to drop before scoring so we measure ATC content, not glue words.
_ARTICLES = {"a", "an", "the"}


def normalize(text: str) -> list[str]:
    """Lowercase, strip punctuation, drop articles -> token list (for WER)."""
    out = []
    for raw in (text or "").lower().split():
        tok = "".join(ch for ch in raw if ch.isalnum())
        if tok and tok not in _ARTICLES:
            out.append(tok)
    return out


def word_error_rate(reference: str, hypothesis: str) -> float:
    """Normalized WER via token-level Levenshtein distance."""
    ref = normalize(reference)
    hyp = normalize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0

    # Classic edit-distance DP over tokens.
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, start=1):
        cur = [i]
        for j, h in enumerate(hyp, start=1):
            cost = 0 if r == h else 1
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1] / len(ref)


def describe_environment(resolved_device: str) -> dict:
    """Collect and print environment / backend info."""
    import torch

    cuda_ok = torch.cuda.is_available()
    mps_ok = (
        getattr(torch.backends, "mps", None) is not None
        and torch.backends.mps.is_available()
    )

    info = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "torch": torch.__version__,
        "cuda_available": cuda_ok,
        "mps_available": mps_ok,
        "resolved_device": resolved_device,
    }

    print("=" * 64)
    print(" ATC_Transcribe - Proof-of-Life Diagnostic")
    print("=" * 64)
    print(f"  OS / platform : {info['platform']}")
    print(f"  Machine arch  : {info['machine']}")
    print(f"  Python        : {info['python']}")
    print(f"  PyTorch       : {info['torch']}")
    print(f"  CUDA backend  : {'available' if cuda_ok else 'not available'}")
    if cuda_ok:
        props = torch.cuda.get_device_properties(0)
        gb = props.total_memory / (1024 ** 3)
        info["cuda_device"] = props.name
        print(f"                  -> {props.name} ({gb:.1f} GB)")
    print(f"  MPS backend   : {'available' if mps_ok else 'not available'}")
    print(f"  Resolved dev. : {resolved_device}")
    print("=" * 64)
    return info


def load_snippets(max_snippets: int | None) -> list[dict]:
    if not MANIFEST.exists():
        sys.exit(
            f"ERROR: diagnostic manifest not found at {MANIFEST}\n"
            "The diagnostic snippets should ship with the repo under "
            "tests/diagnostic_data/."
        )
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    snippets = manifest.get("snippets", [])
    if max_snippets is not None:
        snippets = snippets[:max_snippets]
    if not snippets:
        sys.exit("ERROR: no snippets listed in manifest.json")
    return snippets


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Proof-of-life diagnostic for the ATC Whisper transcriber."
    )
    parser.add_argument(
        "--device",
        default="auto",
        help="auto (default), cuda, mps, or cpu.",
    )
    parser.add_argument(
        "--model-path",
        default=str(ROOT / "models" / "whisper-atc"),
        help="Path to the fine-tuned model (default: models/whisper-atc).",
    )
    parser.add_argument(
        "--no-preprocess",
        action="store_true",
        help="Disable audio preprocessing (faster; less like the live pipeline).",
    )
    parser.add_argument(
        "--max-snippets",
        type=int,
        default=None,
        help="Only run the first N snippets.",
    )
    parser.add_argument(
        "--max-wer",
        type=float,
        default=0.5,
        help="Mean normalized WER above which the diagnostic FAILS (default 0.5).",
    )
    parser.add_argument(
        "--json",
        dest="json_out",
        default=None,
        help="Optional path to write a machine-readable JSON report.",
    )
    args = parser.parse_args()

    # Import here so --help stays instant even before heavy deps load.
    try:
        import librosa
        from atc_transcriber import ATCTranscriber, _resolve_device
    except Exception as exc:  # pragma: no cover - import-time environment issue
        print(f"ERROR: could not import dependencies: {exc}", file=sys.stderr)
        print("Did you activate .venv and run scripts/install.* ?", file=sys.stderr)
        return 1

    resolved = _resolve_device(args.device)
    env = describe_environment(resolved)

    if not Path(args.model_path).exists():
        print(
            f"\nERROR: model not found at {args.model_path}\n"
            "Run:  python scripts/download_model.py",
            file=sys.stderr,
        )
        return 1

    snippets = load_snippets(args.max_snippets)

    print(f"\nLoading model on '{resolved}' ...")
    t0 = time.perf_counter()
    try:
        transcriber = ATCTranscriber(
            model_path=args.model_path,
            device=args.device,  # let the transcriber resolve + apply MPS fallback
            enable_preprocessing=not args.no_preprocess,
        )
    except Exception as exc:
        print(f"ERROR: model failed to load on '{resolved}': {exc}", file=sys.stderr)
        return 1
    load_secs = time.perf_counter() - t0
    print(f"Model loaded in {load_secs:.1f}s\n")

    print(f"Running {len(snippets)} snippet(s):\n")
    results = []
    failures = 0
    for idx, snip in enumerate(snippets, start=1):
        audio_path = DATA_DIR / snip["file"]
        reference = snip["reference"]
        if not audio_path.exists():
            print(f"  [{idx}] MISSING  {snip['file']}")
            failures += 1
            continue

        audio, _ = librosa.load(str(audio_path), sr=16000)
        t = time.perf_counter()
        hypothesis = transcriber.transcribe(audio)
        secs = time.perf_counter() - t
        wer = word_error_rate(reference, hypothesis)
        empty = not hypothesis.strip()
        # "Alive" = the model produced text on this device. A single noisy clip
        # must not flip the verdict; only the mean WER (below) gates PASS/FAIL.
        ok = not empty
        if not ok:
            failures += 1

        status = "ok " if ok else "BAD"
        print(f"  [{idx}] {status} {secs:5.1f}s  WER={wer:5.1%}  {snip['file']}")
        print(f"        ref: {reference}")
        print(f"        hyp: {hypothesis or '<empty>'}")
        results.append(
            {
                "file": snip["file"],
                "reference": reference,
                "hypothesis": hypothesis,
                "wer": round(wer, 4),
                "seconds": round(secs, 3),
                "ok": ok,
            }
        )

    scored = [r for r in results if r]
    mean_wer = sum(r["wer"] for r in scored) / len(scored) if scored else 1.0
    total_infer = sum(r["seconds"] for r in scored)
    # PASS requires: every snippet produced usable output AND mean WER under budget.
    passed = failures == 0 and mean_wer <= args.max_wer

    print("\n" + "=" * 64)
    print(f"  Device used   : {resolved}")
    print(f"  Model load    : {load_secs:.1f}s")
    print(f"  Inference     : {total_infer:.1f}s for {len(scored)} snippet(s)")
    print(f"  Mean WER      : {mean_wer:.1%}  (budget {args.max_wer:.0%})")
    print(f"  VERDICT       : {'PASS - transcriber alive' if passed else 'FAIL'}")
    print("=" * 64)

    if args.json_out:
        report = {
            "environment": env,
            "model_path": args.model_path,
            "preprocess": not args.no_preprocess,
            "load_seconds": round(load_secs, 3),
            "mean_wer": round(mean_wer, 4),
            "max_wer": args.max_wer,
            "passed": passed,
            "snippets": results,
        }
        Path(args.json_out).write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nWrote JSON report to {args.json_out}")

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
