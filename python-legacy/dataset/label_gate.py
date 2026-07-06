"""pm-as-labeler-gate (plan C from the PR #5 review): ground pseudo-labels in the
feed's airport context before they become training data.

Two-model consensus can agree on a plausible-but-wrong transcription (both
teachers share error modes), so this gate applies knowledge the models don't
have: the feed's REAL runways and published frequencies, plus the static ATC
ontology (a squawk can never contain an 8). Three outcomes per label:

  * FIX    — a slot snaps (unique digit-edit-1 onto a real runway/frequency):
             the label text is corrected in place. Cleaner data, kept.
  * REJECT — a runway that does not exist at the airport, or a physically
             impossible squawk/heading/frequency/altimeter value: the label
             is dropped (the audio still feeds the SSL corpus).
  * PASS   — nothing suspicious.

Wired into `pseudo_label.evaluate_segment` behind `FilterThresholds.slot_gate`;
also a CLI to retro-measure the gate over already-collected trainsets:

    python -m dataset.label_gate --data-root <dir with trainset_*/manifest_rel.jsonl> \
        [--no-download]
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from atc_normalize import normalize as canon
from slot_snap import snap_slots
from airport_data import AirportContext

from dataset.slot_metrics import SLOTS


@dataclass
class GateResult:
    ok: bool
    label: str                      # possibly slot-snapped (fixed) text
    fixed: bool = False
    reasons: List[str] = field(default_factory=list)


def assess_label(label: str, airport_ctx: Optional[AirportContext]) -> GateResult:
    """Grounded + ontology assessment of one candidate pseudo-label."""
    reasons: List[str] = []
    out_text = label

    # 1. context-grounded slots (needs an airport; centers pass None -> skipped)
    if airport_ctx is not None:
        snapped_text, edits = snap_slots(label, airport_ctx)
        if any(e.applied for e in edits):
            out_text = snapped_text
        for e in edits:
            if e.slot == "runway" and e.verdict == "unverified":
                reasons.append(f"runway_not_at_airport:{e.original}")
            elif e.slot == "frequency" and e.verdict == "invalid":
                reasons.append(f"impossible_frequency:{e.original}")

    # 2. static ontology hard-fails (independent of airport context): consensus
    #    CAN agree on an impossible value; those labels teach the model garbage.
    text_c = canon(out_text)
    for name, (rx, valid) in SLOTS.items():
        for m in rx.finditer(text_c):
            v = m.group(1).strip()
            if not valid(v):
                reasons.append(f"invalid_{name}:{v}")

    reasons = sorted(set(reasons))
    return GateResult(ok=not reasons, label=out_text,
                      fixed=out_text != label, reasons=reasons)


# ---------------------------------------------------------------------------
# retro-measurement CLI over collected trainsets
# ---------------------------------------------------------------------------

def _iter_rows(data_root: Path):
    for man in sorted(data_root.glob("trainset_*/**/manifest_rel.jsonl")) or \
               sorted(data_root.glob("**/manifest_rel.jsonl")):
        base = man.parent
        for line in man.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            r = json.loads(line)
            text = r.get("text") or r.get("transcript")
            if text is None and r.get("transcript_path"):
                p = base / r["transcript_path"]
                text = p.read_text(encoding="utf-8").strip() if p.exists() else None
            if text:
                yield r.get("airport") or "", text, r.get("id")


def main(argv=None) -> int:
    import argparse
    from airport_data import default_source

    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", required=True, type=Path)
    ap.add_argument("--no-download", action="store_true",
                    help="use only cached/curated airport data")
    ap.add_argument("--samples", type=int, default=6)
    args = ap.parse_args(argv)

    source = default_source(download=not args.no_download)
    ctx_cache = {}
    totals = {"rows": 0, "pass": 0, "fixed": 0, "rejected": 0}
    reason_counts: dict = {}
    samples: List[str] = []

    for airport, text, seg_id in _iter_rows(args.data_root):
        totals["rows"] += 1
        a = airport.upper()
        if a not in ctx_cache:
            try:
                ctx_cache[a] = source.airport(a) if a else None
            except Exception:
                ctx_cache[a] = None
        res = assess_label(text, ctx_cache[a])
        if res.fixed:
            totals["fixed"] += 1
        if res.ok:
            totals["pass"] += 1
        else:
            totals["rejected"] += 1
            for reason in res.reasons:
                key = reason.split(":")[0]
                reason_counts[key] = reason_counts.get(key, 0) + 1
            if len(samples) < args.samples:
                samples.append(f"  [{a}] {seg_id}: {res.reasons} :: {text[:90]}")

    print(f"rows={totals['rows']}  pass={totals['pass']}  "
          f"fixed-in-place={totals['fixed']}  rejected={totals['rejected']} "
          f"({totals['rejected'] / max(1, totals['rows']) * 100:.1f}%)")
    for k, v in sorted(reason_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {k:28s} {v}")
    if samples:
        print("sample rejections:")
        print("\n".join(samples))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
