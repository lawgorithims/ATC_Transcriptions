"""Safety-slot accuracy on the gold set: the metrics the p(m) phraseology
prior (PR #5) would move, measured BEFORE building it.

CallsignSnap owns the callsign slot (falseCS -> 2%); this quantifies the
remaining ontology-governed slots — squawk, heading, frequency, runway,
altimeter — per model:

  * matched      hyp carries the slot with the SAME value as the reference
  * wrong_value  hyp carries the slot with a DIFFERENT value (assertive
                 failure — the runway/heading equivalent of a false callsign)
  * missing      reference slot absent from the hypothesis
  * hyp_invalid  hypothesis slot value that is PHYSICALLY IMPOSSIBLE per the
                 ontology (squawk digit >7, heading >360, freq off the US
                 raster...) — the subset a pure ontology veto catches for free

Slots are extracted with anchored regexes over the canonical per-digit text
(atc_normalize space) and paired positionally per type.

Usage (from python-legacy/):
    python -m dataset.slot_metrics --gold <gold_testset.jsonl> \
        --hyps name=<gold_hyps.jsonl> ...
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from atc_normalize import normalize as canon
from dataset.scoreboard import load_gold


def _digits(s: str) -> str:
    return "".join(ch for ch in s if ch.isdigit())


def _v_squawk(v: str) -> bool:
    d = _digits(v)
    return len(d) == 4 and all(c <= "7" for c in d)


def _v_heading(v: str) -> bool:
    d = _digits(v)
    return d.isdigit() and 1 <= int(d) <= 360


def _v_freq(v: str) -> bool:
    m = re.match(r"(\d) (\d) (\d) point ((?:\d ?)+)", v)
    if not m:
        return False
    mhz = float("".join(m.groups()[:3]) + "." + _digits(m.group(4)))
    return 118.0 <= mhz <= 136.975


def _v_runway(v: str) -> bool:
    d = _digits(v)
    return d.isdigit() and 1 <= int(d) <= 36


def _v_altimeter(v: str) -> bool:
    d = _digits(v)
    return len(d) == 4 and 2800 <= int(d) <= 3150


# name -> (regex over canonical text, validity fn). Regexes anchor on the
# directive keyword so free digits in chatter don't false-trigger.
SLOTS: Dict[str, Tuple[re.Pattern, callable]] = {
    "squawk": (re.compile(r"\bsquawk((?: \d){4})\b"), _v_squawk),
    "heading": (re.compile(r"\bheading((?: \d){3})\b"), _v_heading),
    "frequency": (re.compile(r"\b(\d \d \d point \d(?: \d)?)\b"), _v_freq),
    "runway": (re.compile(r"\brunway((?: \d){1,2}(?: (?:left|right|center))?)\b"), _v_runway),
    "altimeter": (re.compile(r"\baltimeter((?: \d){4})\b"), _v_altimeter),
}


def extract_slots(text_c: str) -> Dict[str, List[str]]:
    out: Dict[str, List[str]] = {}
    for name, (rx, _) in SLOTS.items():
        vals = [m.group(1).strip() for m in rx.finditer(text_c)]
        if vals:
            out[name] = vals
    return out


def score_model(rows: List[dict]) -> Dict[str, Dict[str, int]]:
    stats = {n: {"ref": 0, "matched": 0, "wrong_value": 0, "missing": 0,
                 "hyp_invalid": 0} for n in SLOTS}
    for r in rows:
        ref_s = extract_slots(canon(r["ref"]))
        hyp_s = extract_slots(canon(r["hyp"]))
        for name in SLOTS:
            rv = ref_s.get(name, [])
            hv = hyp_s.get(name, [])
            stats[name]["ref"] += len(rv)
            for i, v in enumerate(rv):
                if i < len(hv):
                    if _digits(hv[i]) == _digits(v) and hv[i].split()[-1:] == v.split()[-1:]:
                        stats[name]["matched"] += 1
                    else:
                        stats[name]["wrong_value"] += 1
                else:
                    stats[name]["missing"] += 1
            validity = SLOTS[name][1]
            stats[name]["hyp_invalid"] += sum(1 for v in hv if not validity(v))
    return stats


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--hyps", nargs="+", required=True, help="name=path pairs")
    args = ap.parse_args(argv)

    gold = load_gold(args.gold)

    # gold QA: reference slots that fail their own ontology = ref errors to fix
    ref_invalid = []
    for g in gold.values():
        for name, vals in extract_slots(canon(g["ref"])).items():
            for v in vals:
                if not SLOTS[name][1](v):
                    ref_invalid.append((g["id"], name, v))
    if ref_invalid:
        print(f"gold QA: {len(ref_invalid)} reference slot(s) fail the ontology "
              f"(review these): {ref_invalid[:4]}\n")

    for pair in args.hyps:
        name, _, path = pair.partition("=")
        rows = []
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            h = json.loads(line)
            g = gold.get(h["id"])
            if g:
                rows.append({"ref": g["ref"], "hyp": h["hyp"]})
        stats = score_model(rows)
        total = {k: sum(s[k] for s in stats.values())
                 for k in ("ref", "matched", "wrong_value", "missing", "hyp_invalid")}
        print(f"### {name}")
        print(f"{'slot':11s} {'ref':>4s} {'match':>6s} {'wrong':>6s} {'miss':>5s} {'hypInvalid':>10s}")
        for slot, s in stats.items():
            if s["ref"] or s["hyp_invalid"]:
                print(f"{slot:11s} {s['ref']:4d} {s['matched']:6d} {s['wrong_value']:6d} "
                      f"{s['missing']:5d} {s['hyp_invalid']:10d}")
        acc = total["matched"] / total["ref"] * 100 if total["ref"] else 0
        print(f"{'TOTAL':11s} {total['ref']:4d} {total['matched']:6d} {total['wrong_value']:6d} "
              f"{total['missing']:5d} {total['hyp_invalid']:10d}   slot-acc {acc:.0f}%\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
