#!/usr/bin/env python3
"""Distill a compact per-airport PLATE INDEX from the offline OCR corpus (plate_ocr.jsonl).

For each airport, collect the unique frequencies, fix idents, and courses that appear across ALL its
OCR'd plates. This ~0.7 MB index is bundled and injected into the ATC speech/LLM context when a flight
plan is filed, so transcription + correction are attuned to what's actually printed on the route's
charts (the reason the OCR harvest kept every text box).

Usage:  build_plate_index.py --corpus <plate_ocr.jsonl> --out <nav/plate_index.json>
"""
import argparse, json, collections, os


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="/Users/bsusl/CommSight/plate-georef-out/plate_ocr.jsonl")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__),
                                                  "../ATCTranscribe/Resources/nav/plate_index.json"))
    # Per-airport caps keep the bundle small and bound how much can bias the decode/correction.
    ap.add_argument("--max-freqs", type=int, default=40)
    ap.add_argument("--max-fixes", type=int, default=160)
    ap.add_argument("--max-courses", type=int, default=80)
    args = ap.parse_args()

    apt = collections.defaultdict(lambda: {"f": set(), "x": set(), "c": set()})
    cycle, n = "", 0
    for line in open(args.corpus):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        n += 1
        cycle = o.get("cycle", cycle)
        a = (o.get("airport") or "").upper()
        if not a:
            continue
        apt[a]["f"].update(o.get("frequencies", []))
        apt[a]["x"].update(f["id"] for f in o.get("fixes", []) if f.get("id"))
        apt[a]["c"].update(str(c) for c in o.get("courses", []))

    airports = {
        a: {
            "f": sorted(v["f"])[: args.max_freqs],
            "x": sorted(v["x"])[: args.max_fixes],
            "c": sorted(v["c"])[: args.max_courses],
        }
        for a, v in apt.items()
        if v["f"] or v["x"] or v["c"]
    }

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as fh:
        json.dump({"cycle": cycle, "airports": airports}, fh, separators=(",", ":"), sort_keys=True)
    print(f"corpus lines={n}  airports={len(airports)}  cycle={cycle}  "
          f"bytes={os.path.getsize(out)} -> {out}")


if __name__ == "__main__":
    main()
