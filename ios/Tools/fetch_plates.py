#!/usr/bin/env python3
"""Fetch the FAA d-TPP plate PDFs named by procedures.json into a cycle-scoped cache.

`build_plate_georef_embedded.py` reads the transform out of each plate PDF but does not fetch
anything — it silently counts a missing plate as "not-cached" and moves on, which is how a partial
cache turns into a partial table. This fetches what that builder needs, first.

The cache MUST be scoped to one cycle. Plate filenames are stable across cycles but their contents
are not: 00001AD.PDF was 142,831 bytes in 2607 and 164,419 in 2610. Reusing a previous cycle's PDF
yields a transform for geometry the app will never display, which misplaces the overlay instead of
leaving a gap. So: one directory per cycle, never shared.

Resumable — an existing file that parses as a PDF is left alone, so a re-run only fills the holes.

Usage: fetch_plates.py --cycle 2610 --cache DIR [--procedures J] [--workers N] [--limit N]
                       [--all-plate-types]
"""
import argparse
import concurrent.futures as cf
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

BASE = "https://aeronav.faa.gov/d-tpp"
UA = "Obelisk-plate-georef-build/1.0"
NAV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../ATCTranscribe/Resources/nav")


def looks_like_pdf(path):
    try:
        if os.path.getsize(path) < 1024:
            return False
        with open(path, "rb") as f:
            return f.read(5) == b"%PDF-"
    except OSError:
        return False


def fetch_one(cycle, cache, name, tries=4):
    """Download one plate. Returns 'have' | 'ok' | 'gone' | 'fail:<reason>'."""
    dest = os.path.join(cache, name)
    if looks_like_pdf(dest):
        return "have"
    url = f"{BASE}/{cycle}/{name}"
    last = "unknown"
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=90) as r:
                body = r.read()
            if not body.startswith(b"%PDF-"):
                last = f"not-a-pdf({len(body)}B)"
            else:
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    f.write(body)
                os.replace(tmp, dest)
                return "ok"
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return "gone"
            last = f"http{e.code}"
        except Exception as e:                                  # timeouts, resets, DNS
            last = type(e).__name__
        time.sleep(min(2 ** attempt + random.random(), 20))
    return "fail:" + last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cycle", required=True, help="FAA cycle, e.g. 2610 — must be the one IN FORCE")
    ap.add_argument("--cache", required=True, help="cycle-scoped output dir (never shared between cycles)")
    ap.add_argument("--procedures", default=os.path.join(NAV, "procedures.json"))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--all-plate-types", action="store_true",
                    help="fetch every plate, not just IAPs (the georef builder only uses IAPs)")
    args = ap.parse_args()

    proc = json.load(open(args.procedures))
    if str(proc.get("cycle")) != str(args.cycle):
        sys.exit(f"refusing: --cycle {args.cycle} but {args.procedures} is cycle {proc.get('cycle')}")
    names = sorted({r["f"] for rs in proc["airports"].values() for r in rs
                    if args.all_plate_types or r["c"] == "IAP"})
    if args.limit:
        names = names[:args.limit]
    os.makedirs(args.cache, exist_ok=True)

    print(f"cycle={args.cycle} ({proc.get('from')} → {proc.get('to')})  plates={len(names)}  "
          f"workers={args.workers}  cache={args.cache}", flush=True)

    tally = {"have": 0, "ok": 0, "gone": 0}
    failures = []
    t0 = time.time()
    with cf.ThreadPoolExecutor(args.workers) as ex:
        futs = {ex.submit(fetch_one, args.cycle, args.cache, n): n for n in names}
        for i, fut in enumerate(cf.as_completed(futs), 1):
            name = futs[fut]
            res = fut.result()
            if res.startswith("fail"):
                failures.append((name, res))
            else:
                tally[res] += 1
            if i % 250 == 0 or i == len(names):
                el = time.time() - t0
                print(f"  {i}/{len(names)}  new={tally['ok']} cached={tally['have']} "
                      f"gone={tally['gone']} failed={len(failures)}  "
                      f"{i/el:.1f}/s  eta={(len(names)-i)/max(i/el, 1e-6)/60:.1f}min", flush=True)

    print(f"done in {(time.time()-t0)/60:.1f}min  new={tally['ok']} already-cached={tally['have']} "
          f"404={tally['gone']} failed={len(failures)}")
    for name, why in failures[:40]:
        print(f"  FAILED {name} {why}")
    if len(failures) > 40:
        print(f"  … and {len(failures)-40} more")
    # A failure is a hole in the table, so make it loud: re-run to retry just the holes.
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
