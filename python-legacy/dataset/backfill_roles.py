#!/usr/bin/env python3
"""backfill_roles.py — re-tag existing accepted transcripts with the CURRENT
atc_diarize.classify_turn and write role_overrides.jsonl for the rows whose role changed.

emit_metadata.to_train_metadata prefers these overrides, so a tagger improvement reaches
historical training rows WITHOUT rewriting the live (append-only) manifest — no race with
the running collector, no collector pause. Re-run after any atc_diarize change.

    python -m dataset.backfill_roles          # writes <data-root>/us_pseudo/role_overrides.jsonl
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from atc_diarize import classify_turn  # noqa: E402


def run(data_root):
    us = os.path.join(data_root, "us_pseudo")
    rows = [json.loads(l) for l in open(os.path.join(us, "manifest.jsonl")) if l.strip()]
    tdir = os.path.join(us, "transcripts")  # reconstruct from id (stored paths may be stale)
    out, changed, miss = [], 0, 0
    for r in rows:
        p = os.path.join(tdir, r["id"] + ".txt")
        if not os.path.exists(p):
            miss += 1
            continue
        lbl = classify_turn(open(p, encoding="utf-8").read().strip())
        if lbl.role != r.get("role"):
            out.append({"id": r["id"], "role": lbl.role,
                        "role_confidence": round(lbl.confidence, 4)})
            changed += 1
    dst = os.path.join(us, "role_overrides.jsonl")
    with open(dst, "w", encoding="utf-8") as f:
        for o in out:
            f.write(json.dumps(o) + "\n")
    print(f"re-tagged {len(rows)} rows: {changed} role changes, {miss} missing transcripts")
    print(f"wrote {dst}")
    return changed


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", default=os.path.expanduser("~/CommSight/atc-data"))
    run(ap.parse_args(argv).data_root)


if __name__ == "__main__":
    main()
