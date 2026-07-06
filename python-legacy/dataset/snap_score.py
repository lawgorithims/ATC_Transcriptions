"""Score the CallsignSnap stage on the gold set, both channels:

  TEXT   — scoreboard metrics (canonWER/CSA/falseCS) recomputed on the
           rewritten transcripts: what the user READS.
  ENTITY — attribution metrics using snap verdicts, where "unverified"
           means abstain (no aircraft attribution): what the app ACTS on.

Candidate list on gold = the session callsign inventory (all reference
callsigns), a stand-in for the live ADS-B in-range list. Real ADS-B adds
coverage gaps (true callsign absent -> snap abstains, safe) and distractors.

Usage (from python-legacy/):
    python -m dataset.snap_score --gold <gold_testset.jsonl> \
        --hyps name=<gold_hyps.jsonl> ... [--write-snapped]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from callsign_snap import snap_transcript, SnapEdit
from dataset.scoreboard import load_gold, score_pairs, _canon_callsign


def entity_metrics(gold_rows: List[dict], edits: List[SnapEdit]) -> Dict[str, float]:
    total = correct = false = abstain = 0
    for g, e in zip(gold_rows, edits):
        ref_cs = _canon_callsign(g["ref"])
        if not ref_cs:
            continue
        total += 1
        if e.verdict in ("verified_exact", "snapped"):
            if e.snapped == ref_cs:
                correct += 1
            else:
                false += 1
        else:  # unverified / no_callsign -> no attribution
            abstain += 1
    n = max(1, total)
    return {"total": total, "csa": correct / n, "false": false / n,
            "abstain": abstain / n}


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--hyps", nargs="+", required=True, help="name=path pairs")
    ap.add_argument("--write-snapped", action="store_true",
                    help="write <hyps>_snap.jsonl next to each input")
    args = ap.parse_args(argv)

    gold = load_gold(args.gold)
    candidates = sorted({c for g in gold.values() if (c := _canon_callsign(g["ref"]))})
    print(f"gold: {len(gold)} rows | candidate inventory: {len(candidates)} callsigns\n")

    header = (f"{'model':24s} {'canonWER':>9s} {'textCSA':>8s} {'textFalse':>9s} "
              f"{'entCSA':>7s} {'entFalse':>8s} {'abstain':>8s}")
    print(header)
    print("-" * len(header))

    for pair in args.hyps:
        name, _, path = pair.partition("=")
        gold_rows, raw_hyps = [], []
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            h = json.loads(line)
            g = gold.get(h["id"])
            if g:
                gold_rows.append(g)
                raw_hyps.append(h["hyp"])

        snapped_texts, edits = [], []
        for hyp in raw_hyps:
            new_text, edit = snap_transcript(hyp, candidates)
            snapped_texts.append(new_text)
            edits.append(edit)

        refs = [g["ref"] for g in gold_rows]
        before = score_pairs(name, refs, raw_hyps)
        after = score_pairs(name + "+snap", refs, snapped_texts)
        ent = entity_metrics(gold_rows, edits)

        def pct(x):
            return f"{x * 100:5.1f}%"

        print(f"{name:24s} {pct(before.canon_wer):>9s} {pct(before.csa or 0):>8s} "
              f"{pct(before.false_cs_rate or 0):>9s} {'—':>7s} {'—':>8s} {'—':>8s}")
        print(f"{name + '+snap':24s} {pct(after.canon_wer):>9s} {pct(after.csa or 0):>8s} "
              f"{pct(after.false_cs_rate or 0):>9s} {pct(ent['csa']):>7s} "
              f"{pct(ent['false']):>8s} {pct(ent['abstain']):>8s}")

        applied = sum(1 for e in edits if e.applied)
        verdicts = {}
        for e in edits:
            verdicts[e.verdict] = verdicts.get(e.verdict, 0) + 1
        print(f"{'':24s} rewrites={applied} verdicts={verdicts}\n")

        if args.write_snapped:
            out = Path(path).with_name(Path(path).stem + "_snap.jsonl")
            with out.open("w", encoding="utf-8") as f:
                for g, t, e in zip(gold_rows, snapped_texts, edits):
                    f.write(json.dumps({"id": g["id"], "ref": g["ref"], "hyp": t,
                                        "verdict": e.verdict}) + "\n")
            print(f"  wrote {out}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
