"""Score the full deterministic snap chain (CallsignSnap -> SlotSnap) on gold.

Airport context per clip comes from the REAL provider chain
(`airport_data.default_source()`: curated configs first, OurAirports internet
fallback underneath) keyed by the clip's feed airport — the same lookup the
app's LiveATC/demo mode performs. ARTCC feeds (ZAN/ZFW/...) have no airport
context; the stage no-ops there by design (measured, not hidden).

Usage (from python-legacy/):
    python -m dataset.slot_snap_score --gold <gold_testset.jsonl> \
        --hyps name=<gold_hyps.jsonl> ...
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from airport_data import default_source
from callsign_snap import snap_transcript
from slot_snap import snap_slots
from dataset.scoreboard import load_gold, score_pairs, _canon_callsign
from dataset.slot_metrics import score_model as slot_score


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--hyps", nargs="+", required=True, help="name=path pairs")
    args = ap.parse_args(argv)

    gold = load_gold(args.gold)
    source = default_source(download=False)
    cs_candidates = sorted({c for g in gold.values() if (c := _canon_callsign(g["ref"]))})

    ctx_cache, no_ctx = {}, set()
    for g in gold.values():
        a = (g.get("airport") or "").upper()
        if a and a not in ctx_cache:
            ctx_cache[a] = source.airport(a)
            if ctx_cache[a] is None:
                no_ctx.add(a)
    print(f"gold: {len(gold)} rows | airport context resolved for "
          f"{sum(1 for v in ctx_cache.values() if v)} / {len(ctx_cache)} facilities "
          f"(no context: {sorted(no_ctx)})\n")

    for pair in args.hyps:
        name, _, path = pair.partition("=")
        rows = []
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            h = json.loads(line)
            g = gold.get(h["id"])
            if g:
                rows.append({"ref": g["ref"], "hyp": h["hyp"],
                             "airport": (g.get("airport") or "").upper()})

        chained, verdicts = [], {}
        for r in rows:
            t1, _cs_edit = snap_transcript(r["hyp"], cs_candidates)
            t2, slot_edits = snap_slots(t1, ctx_cache.get(r["airport"]))
            chained.append(t2)
            for e in slot_edits:
                verdicts[f"{e.slot}:{e.verdict}"] = verdicts.get(f"{e.slot}:{e.verdict}", 0) + 1

        refs = [r["ref"] for r in rows]
        before = score_pairs(name, refs, [r["hyp"] for r in rows])
        after = score_pairs(name + "+snaps", refs, chained)

        s_before = slot_score(rows)
        s_after = slot_score([{"ref": r["ref"], "hyp": h} for r, h in zip(rows, chained)])

        def tot(s, k):
            return sum(v[k] for v in s.values())

        def pct(x):
            return f"{(x or 0) * 100:.1f}%"

        print(f"### {name}")
        print(f"  canonWER {pct(before.canon_wer)} -> {pct(after.canon_wer)} | "
              f"CSA {pct(before.csa)} -> {pct(after.csa)} | "
              f"falseCS {pct(before.false_cs_rate)} -> {pct(after.false_cs_rate)}")
        print(f"  slots: matched {tot(s_before,'matched')} -> {tot(s_after,'matched')}, "
              f"wrong {tot(s_before,'wrong_value')} -> {tot(s_after,'wrong_value')}, "
              f"missing {tot(s_before,'missing')} -> {tot(s_after,'missing')} "
              f"(of {tot(s_before,'ref')})")
        print(f"  slot verdicts: {dict(sorted(verdicts.items()))}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
