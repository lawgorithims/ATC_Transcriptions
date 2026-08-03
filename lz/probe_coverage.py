#!/usr/bin/env python3
"""Ask USGS which cells have 1 m lidar, WITHOUT downloading anything.

WHY THIS EXISTS. The build cost per cell is bimodal and the two modes differ by an order of
magnitude: a cell with 1 m lidar streams ~145 source tiles and takes ~58 minutes; a cell that falls
back to 1/3 arc-second reads one tile and takes ~5. Committing a laptop to a wide-area run without
knowing the mix is committing it to somewhere between three days and five weeks, which is not a
decision anyone should make from a guess.

This asks the same National Map product API `fetch.py` already uses, reads only the RESULT COUNT,
and answers in about two seconds per cell with no payload at all.

    python3 lz/probe_coverage.py --bbox 31 49 -125 -66 --sample 60
    python3 lz/probe_coverage.py --cells n36w107 n37w107 ...

⚠️ IT ANSWERS "IS 1 m PUBLISHED HERE", NOT "IS IT ANY GOOD". A cell can report 1 m coverage that is
partial, or flown in 2014, or over only the populated third of the cell. `fetch.py` computes the
actual percentage when it builds; this is a planning estimate and should be quoted as one.
"""

import argparse
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
WESM_URL = ("/vsicurl/https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/metadata/WESM.gpkg")

# ⚠️ CALL THE BUILDER'S OWN QUERY, DO NOT WRITE A SECOND ONE. The first version of this file
# reimplemented the National Map request and got 0 of 6 on cells that are provably 100% 1 m lidar —
# `urlencode` renders spaces in the dataset name as `+` and the API wants `%20`, so every answer came
# back "no 1 m". It looked entirely plausible: a tidy table saying CONUS was cheap to build, which
# would have sent a multi-week decision the wrong way on a formatting difference.
#
# Reusing `ThreeDEP` means this cannot disagree with what the build actually resolves, which is the
# only property that makes the estimate worth anything.

# Measured on this machine, 2026-08-02. See [[lz-silent-empty-failures]].
MIN_PER_1M_CELL = 58.0
MIN_PER_COARSE_CELL = 5.5


def cell_id(lat_north, lon_west):
    """USGS NW-corner convention: n36w107 spans 35-36 N and 106-107 W."""
    return f"n{lat_north:02d}w{abs(lon_west):03d}"


def load_survey_index(max_gsd=1.0):
    """Every 3DEP survey footprint at or finer than `max_gsd`, read ONCE.

    ⚠️ ONE QUERY, NOT ONE PER CELL. The first version asked the product API per cell, which made a
    CONUS estimate ~1000 network calls and — during an outage — impossible. The WESM index holds all
    3,268 survey footprints in a single file that GDAL reads remotely in about a second, so the whole
    country can be costed locally, offline of the flaky API, in the time one cell used to take.
    """
    from osgeo import ogr, gdal
    gdal.UseExceptions()
    gdal.SetConfigOption("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".gpkg")
    ds = ogr.Open(WESM_URL)
    if ds is None:
        raise RuntimeError("WESM.gpkg unreachable")
    layer = ds.GetLayer(0)
    keep = []
    for feat in layer:                                               # bounded: 3268 features
        gsd = feat.GetField("dem_gsd_meters")
        if gsd is None or float(gsd) > max_gsd:
            continue
        geom = feat.GetGeometryRef()
        if geom is not None:
            keep.append(geom.Clone())
    return ds, keep


def cell_rect(lat_north, lon_west):
    from osgeo import ogr
    r = ogr.Geometry(ogr.wkbLinearRing)
    for x, y in ((lon_west, lat_north - 1), (lon_west + 1, lat_north - 1),
                 (lon_west + 1, lat_north), (lon_west, lat_north), (lon_west, lat_north - 1)):
        r.AddPoint_2D(x, y)
    poly = ogr.Geometry(ogr.wkbPolygon)
    poly.AddGeometry(r)
    return poly


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bbox", nargs=4, type=float, metavar=("S", "N", "W", "E"),
                    help="probe a lat/lon box, e.g. --bbox 31 49 -125 -66 for CONUS")
    ap.add_argument("--cells", nargs="+", default=[], help="probe these cell ids instead")
    ap.add_argument("--sample", type=int, default=0,
                    help="probe only N cells drawn evenly at random from the box (fast estimate)")
    ap.add_argument("--seed", type=int, default=17, help="sampling seed, so a run is repeatable")
    ap.add_argument("--out", default="", help="write the per-cell answers here as JSON")
    a = ap.parse_args()

    targets = []
    if a.cells:
        for c in a.cells:
            targets.append((int(c[1:3]), -int(c[4:7])))
    elif a.bbox:
        s, n, w, e = a.bbox
        for lat in range(int(s) + 1, int(n) + 1):                    # bounded (rule 2)
            for lon in range(int(w), int(e)):                        # bounded (rule 2)
                targets.append((lat, lon))
    else:
        ap.error("give --bbox or --cells")

    total_in_box = len(targets)
    if a.sample and a.sample < len(targets):
        random.Random(a.seed).shuffle(targets)
        targets = targets[:a.sample]

    print(f"probing {len(targets)} cell(s)"
          + (f" sampled from {total_in_box} in the box" if a.sample else "") + " …", flush=True)
    fine = coarse = unknown = 0
    answers = {}
    t0 = time.time()
    _ds, footprints = load_survey_index()
    print(f"  survey index: {len(footprints)} footprints at <=1 m ({time.time()-t0:.0f}s)",
          flush=True)
    for i, (lat, lon) in enumerate(targets, 1):                      # bounded (rule 2)
        cid = cell_id(lat, lon)
        box = cell_rect(lat, lon)
        got = any(box.Intersects(g) for g in footprints)             # bounded (rule 2)
        answers[cid] = got
        if got is None:
            unknown += 1
        elif got:
            fine += 1
        else:
            coarse += 1
        if i % 10 == 0 or i == len(targets):
            print(f"  {i}/{len(targets)}  1m={fine}  coarse={coarse}  unknown={unknown}"
                  f"  ({time.time()-t0:.0f}s)", flush=True)

    answered = fine + coarse
    if not answered:
        print("\nno cell answered — the product API may be down; nothing can be estimated")
        return 1

    pct1m = 100.0 * fine / answered
    print(f"\n1 m lidar published over {fine}/{answered} probed cells ({pct1m:.0f}%)")
    if unknown:
        print(f"{unknown} cell(s) gave no answer and are excluded from the estimate")

    # Project onto the whole box, since a sample is only useful as a projection.
    n_cells = total_in_box
    if a.sample:
        print(f"\nprojecting that mix onto all {n_cells} cells in the box:")
    est_1m = n_cells * pct1m / 100.0
    est_coarse = n_cells - est_1m
    hours = (est_1m * MIN_PER_1M_CELL + est_coarse * MIN_PER_COARSE_CELL) / 60.0
    print(f"  ~{est_1m:.0f} at 1 m  x {MIN_PER_1M_CELL:.0f} min")
    print(f"  ~{est_coarse:.0f} coarse x {MIN_PER_COARSE_CELL:.1f} min")
    print(f"  ≈ {hours:.0f} hours of continuous build  ({hours/24:.1f} days)")
    print(f"  ≈ {n_cells * 0.062:.0f} GB of packs")
    print("\n⚠️ 'published' is not 'complete': a cell can report 1 m over only part of its area, so "
          "treat this as a planning estimate, not a measurement.")

    if a.out:
        with open(a.out, "w") as f:
            json.dump({"answers": answers, "pct_1m": pct1m, "cells_in_box": n_cells}, f, indent=2)
        print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
