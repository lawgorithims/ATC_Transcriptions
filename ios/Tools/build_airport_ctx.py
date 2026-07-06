#!/usr/bin/env python3
"""Build the bundled airport-context table (runways + airband frequencies).

Companion to build_nav_db.py (same OurAirports upstream, same provenance):
where nav_coords.json answers "where is ident X / what is near here",
airport_ctx.json answers "what runways and frequencies does airport X have" —
the grounding data for the CallsignSnap/SlotSnap correction stages
(python-legacy/docs/PIPELINE.md).

Output schema (compact; Swift `AirportContextStore` decodes it):
    { "KDFW": [["13L","13R",...], {"TWR": [124.15], "GND": [121.65], ...}], ... }

Coverage: airports of type large/medium/small with at least one open runway
or one airband (118.0-136.975 MHz) frequency. US + worldwide; run with
--us-only if bundle size ever matters more than international coverage.

Usage:
    python build_airport_ctx.py --data-dir <dir with OurAirports CSVs> \
        --out ../ATCTranscribe/Resources/nav/airport_ctx.json
CSVs (airports.csv, runways.csv, airport-frequencies.csv) are downloaded from
https://davidmegginson.github.io/ourairports-data/ if missing (public domain).
"""

import argparse
import csv
import json
import urllib.request
from pathlib import Path

URL = "https://davidmegginson.github.io/ourairports-data/{}.csv"
TYPES = {"large_airport", "medium_airport", "small_airport"}
AIRBAND = (118.0, 136.975)


def fetch(data_dir: Path, name: str) -> Path:
    p = data_dir / f"{name}.csv"
    if not p.exists():
        data_dir.mkdir(parents=True, exist_ok=True)
        print(f"downloading {name}.csv ...")
        urllib.request.urlretrieve(URL.format(name), p)
    return p


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--us-only", action="store_true")
    args = ap.parse_args()

    airports = {}
    with open(fetch(args.data_dir, "airports"), encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            if row["type"] not in TYPES:
                continue
            if args.us_only and row["iso_country"] != "US":
                continue
            airports[row["ident"]] = True

    runways = {}
    with open(fetch(args.data_dir, "runways"), encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            ident = row["airport_ident"]
            if ident not in airports or row["closed"] == "1":
                continue
            lst = runways.setdefault(ident, [])
            for e in (row["le_ident"].strip(), row["he_ident"].strip()):
                if e and e not in lst:
                    lst.append(e)

    freqs = {}
    with open(fetch(args.data_dir, "airport-frequencies"), encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            ident = row["airport_ident"]
            if ident not in airports:
                continue
            try:
                mhz = round(float(row["frequency_mhz"]), 3)
            except ValueError:
                continue
            if not (AIRBAND[0] <= mhz <= AIRBAND[1]):
                continue
            t = row["type"].strip().upper()[:4] or "ATC"
            lst = freqs.setdefault(ident, {}).setdefault(t, [])
            if mhz not in lst:
                lst.append(mhz)

    table = {}
    for ident in airports:
        r, fq = sorted(runways.get(ident, [])), freqs.get(ident, {})
        if r or fq:
            table[ident] = [r, {k: sorted(v) for k, v in sorted(fq.items())}]

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(table, separators=(",", ":")), encoding="utf-8")
    size = args.out.stat().st_size
    print(f"{len(table)} airports -> {args.out} ({size/1e6:.1f} MB)")


if __name__ == "__main__":
    main()
