"""
The standing scoreboard: score models against the human-verified US gold set.

This is the project's single honest number source. The existing validation split
(~95% clean ATCoSIM studio audio) understates real US error by ~3x, and the
consensus eval (``eval_set.py``) is model-biased by construction. The gold set is
different: real LiveATC clips whose references were HUMAN-verified (see
``verification_sample/review.html`` workflow), so its numbers are absolute.

Metrics per model:
  * normWER / normCER   — project's basic normalization (lowercase, no punct,
                          no articles) on both sides.
  * canonWER / canonCER — plus US-format canonicalization (spoken numbers ->
                          digits, runway designators unified). The OPERATIVE
                          quality number: format-only differences don't matter
                          to a pilot reading the transcript.
  * CSA                 — callsign accuracy on the subset of gold rows with an
                          extractable reference callsign: the hypothesis must
                          yield the SAME canonical callsign.
  * falseCS             — safety metric: hypothesis asserts a canonical callsign
                          that CONTRADICTS the reference one. (A missed callsign
                          hurts CSA; an invented one is worse and counted here.)

Usage (from python-legacy/):
    # offline: score precomputed hypothesis files (gold_hyps_*.jsonl with ref+hyp)
    python -m dataset.scoreboard --gold <gold_testset.jsonl> \
        --hyps small_v1=<gold_hyps_small_v1.jsonl> turbo_ft=<...> --out docs/RESULTS.md

    # live: transcribe the gold clips with a local/HF model checkpoint
    python -m dataset.scoreboard --gold <gold_testset.jsonl> --clips-root <dir> \
        --model models/whisper-atc-turbo --out docs/RESULTS.md
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import sys

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:  # allow `python -m dataset.scoreboard` and direct import
    sys.path.insert(0, str(_HERE))

from atc_normalization import normalize_atc_text as _basic_norm
from atc_normalize import normalize as _canon_norm
from atc_diarize import extract_callsign

from dataset.normalize import _levenshtein


# ---------------------------------------------------------------------------
# Corpus metrics (edit distance over the whole set, not mean of per-clip rates)
# ---------------------------------------------------------------------------

def _corpus_rate(refs: List[str], hyps: List[str], chars: bool = False) -> float:
    edits, total = 0, 0
    for ref, hyp in zip(refs, hyps):
        r = list(ref.replace(" ", "")) if chars else ref.split()
        h = list(hyp.replace(" ", "")) if chars else hyp.split()
        edits += _levenshtein(r, h)
        total += len(r)
    return edits / max(1, total)


def _canon_callsign(text: str) -> Optional[str]:
    """Spoken callsign span -> canonical form ('delta twelve thirty four' -> 'delta 1234')."""
    span = extract_callsign(text)
    return _canon_norm(span) if span else None


@dataclass
class ModelScore:
    name: str
    n: int
    norm_wer: float
    norm_cer: float
    canon_wer: float
    canon_cer: float
    cs_total: int       # gold rows with an extractable reference callsign
    cs_correct: int     # ... where the hypothesis callsign matches
    cs_false: int       # ... where the hypothesis asserts a DIFFERENT callsign

    @property
    def csa(self) -> Optional[float]:
        return self.cs_correct / self.cs_total if self.cs_total else None

    @property
    def false_cs_rate(self) -> Optional[float]:
        return self.cs_false / self.cs_total if self.cs_total else None


def score_pairs(name: str, refs: List[str], hyps: List[str]) -> ModelScore:
    """Score parallel raw ref/hyp text lists (normalization applied here)."""
    rb, hb = [_basic_norm(t) for t in refs], [_basic_norm(t) for t in hyps]
    rc, hc = [_canon_norm(t) for t in refs], [_canon_norm(t) for t in hyps]

    cs_total = cs_correct = cs_false = 0
    for ref, hyp in zip(refs, hyps):
        ref_cs = _canon_callsign(ref)
        if not ref_cs:
            continue  # CSA measured only where the reference callsign is extractable
        cs_total += 1
        hyp_cs = _canon_callsign(hyp)
        if hyp_cs == ref_cs:
            cs_correct += 1
        elif hyp_cs is not None:
            cs_false += 1  # asserted a callsign, and it contradicts the reference

    return ModelScore(
        name=name,
        n=len(refs),
        norm_wer=_corpus_rate(rb, hb),
        norm_cer=_corpus_rate(rb, hb, chars=True),
        canon_wer=_corpus_rate(rc, hc),
        canon_cer=_corpus_rate(rc, hc, chars=True),
        cs_total=cs_total,
        cs_correct=cs_correct,
        cs_false=cs_false,
    )


# ---------------------------------------------------------------------------
# Input loaders
# ---------------------------------------------------------------------------

def load_gold(path: Path) -> Dict[str, dict]:
    """gold_testset.jsonl rows keyed by segment id ({id, clip, ref, airport, feed, ...})."""
    rows = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            rows[r["id"]] = r
    return rows


def score_hyps_file(name: str, hyps_path: Path, gold: Dict[str, dict]) -> ModelScore:
    """Score a precomputed hypothesis file (rows with id + hyp; ref taken from GOLD)."""
    refs, hyps = [], []
    for line in hyps_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        g = gold.get(r["id"])
        if g is None:
            continue  # hypothesis for a clip not in (this version of) the gold set
        refs.append(g["ref"])
        hyps.append(r["hyp"])
    return score_pairs(name, refs, hyps)


def score_model_live(
    name: str, model_path: str, gold: Dict[str, dict], clips_root: Path,
    device: str = "auto",
) -> ModelScore:
    """Transcribe the gold clips with a checkpoint (HF id or local path) and score."""
    from dataset.scored_transcribe import ScoredTranscriber
    import soundfile as sf

    model = ScoredTranscriber(model_path, device=device, num_beams=1)
    refs, hyps = [], []
    for g in gold.values():
        audio, _ = sf.read(str(clips_root / g["clip"]), dtype="float32")
        res = model.transcribe_scored(audio, context=None)
        refs.append(g["ref"])
        hyps.append(res.text)
    return score_pairs(name, refs, hyps)


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def render_markdown(scores: List[ModelScore], gold_path: Path, extra_note: str = "") -> str:
    def pct(x: Optional[float]) -> str:
        return f"{x * 100:.1f}%" if x is not None else "—"

    lines = [
        "# US Gold Scoreboard",
        "",
        f"Gold set: `{gold_path}` ({scores[0].n if scores else 0} human-verified clips). "
        "canonWER is the operative metric (format-canonicalized both sides); "
        "CSA/falseCS measured on rows with an extractable reference callsign.",
        "",
        "| model | n | normWER | canonWER | canonCER | CSA | falseCS | CS rows |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for s in scores:
        lines.append(
            f"| {s.name} | {s.n} | {pct(s.norm_wer)} | **{pct(s.canon_wer)}** | "
            f"{pct(s.canon_cer)} | {pct(s.csa)} | {pct(s.false_cs_rate)} | {s.cs_total} |"
        )
    if extra_note:
        lines += ["", extra_note]
    lines.append("")
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Score models against the US gold set.")
    ap.add_argument("--gold", required=True, type=Path, help="gold_testset.jsonl")
    ap.add_argument("--hyps", nargs="*", default=[],
                    help="name=path pairs of precomputed hypothesis jsonl files")
    ap.add_argument("--model", default=None, help="checkpoint to transcribe live")
    ap.add_argument("--name", default=None, help="display name for --model")
    ap.add_argument("--clips-root", type=Path, default=None,
                    help="root for resolving gold 'clip' paths (required with --model)")
    ap.add_argument("--device", default="auto")
    ap.add_argument("--out", type=Path, default=None, help="write markdown table here")
    ap.add_argument("--json-out", type=Path, default=None, help="write raw scores here")
    args = ap.parse_args(argv)

    gold = load_gold(args.gold)
    scores: List[ModelScore] = []

    for pair in args.hyps:
        name, _, path = pair.partition("=")
        scores.append(score_hyps_file(name, Path(path), gold))
    if args.model:
        if not args.clips_root:
            ap.error("--model requires --clips-root")
        scores.append(score_model_live(
            args.name or args.model, args.model, gold, args.clips_root, args.device,
        ))

    md = render_markdown(scores, args.gold)
    print(md)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(md, encoding="utf-8")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps([s.__dict__ | {"csa": s.csa, "false_cs_rate": s.false_cs_rate}
                        for s in scores], indent=2),
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
