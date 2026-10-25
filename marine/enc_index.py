#!/usr/bin/env python3
"""enc_index.py — catalogue an expanded NOAA ENC_ROOT into one JSON index.

    ./enc_index.py <ENC_ROOT dir> <out.json>

Every downstream step (region cutting, pack building, coverage reporting) reads this index instead
of re-walking 7,303 S-57 files. One pass costs about a minute; everything after it is instant.

Per cell we record what the DATA says about itself, never what the filename implies:

    band   DSID_INTU   intended usage band 1-6. The 3rd character of the cell name usually agrees,
                       but it is a naming convention, not a guarantee — read the field.
    scale  DSPM_CSCL   compilation scale, used to cross-check the band → zoom assignment.
    issued DSID_ISDT   issue date (YYYYMMDD). The newest ISDT in a pack is that pack's vintage,
                       so the artifact's date is derived from its contents rather than the clock.
    edn/upd DSID_EDTN/DSID_UPDN  edition and update number, for diffing one weekly set against the next.
    bbox   M_COVR extent — the cell's real coverage polygon, not its data extent. Every one of the
                       7,303 cells carries M_COVR, which is also where region cutlines come from
                       (NOAA ENCs ship no separate clip shapes, unlike the FAA chart pipeline).

Refuses to write an index in which any cell lacks a band, a bbox, or an issue date: a cell we
cannot date or place cannot be assigned to a zoom window or a region, and a silently dropped cell
is a hole in the chart that nothing downstream would report.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import encspec  # noqa: E402

os.environ["OGR_S57_OPTIONS"] = encspec.OGR_S57_OPTIONS
from osgeo import gdal, ogr  # noqa: E402

gdal.UseExceptions()
gdal.PushErrorHandler("CPLQuietErrorHandler")


def find_cells(root):
    out = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(".000"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def read_cell(path):
    ident = os.path.basename(path)[:-4]
    ds = ogr.Open(path)
    if ds is None:
        return {"ident": ident, "error": "unreadable"}

    rec = {"ident": ident, "path": path}

    dsid = ds.GetLayerByName("DSID")
    if dsid is not None:
        f = dsid.GetNextFeature()
        if f is not None:
            def g(name):
                i = f.GetFieldIndex(name)
                return f.GetField(i) if i >= 0 else None
            rec["band"] = g("DSID_INTU")
            rec["scale"] = g("DSPM_CSCL")
            rec["issued"] = g("DSID_ISDT")
            rec["edition"] = g("DSID_EDTN")
            rec["update"] = g("DSID_UPDN")
            rec["agency"] = g("DSID_AGEN")

    # Coverage, from M_COVR — this is the cell's authoritative footprint and the source of the
    # cutline. Fall back to the union of all layer extents only if M_COVR is missing, and say so.
    mc = ds.GetLayerByName("M_COVR")
    if mc is not None and mc.GetFeatureCount() > 0:
        x0, x1, y0, y1 = mc.GetExtent()
        rec["bbox"] = [round(x0, 7), round(y0, 7), round(x1, 7), round(y1, 7)]
        rec["bbox_from"] = "M_COVR"
    else:
        ext = None
        for i in range(ds.GetLayerCount()):
            lyr = ds.GetLayer(i)
            if lyr.GetFeatureCount() == 0:
                continue
            try:
                x0, x1, y0, y1 = lyr.GetExtent()
            except Exception:
                continue
            ext = (min(ext[0], x0), min(ext[1], y0), max(ext[2], x1), max(ext[3], y1)) if ext \
                else (x0, y0, x1, y1)
        if ext:
            rec["bbox"] = [round(v, 7) for v in ext]
            rec["bbox_from"] = "layer-extents"

    # Which of the classes we care about this cell actually populates. Stored so the pack builder
    # never asks a cell for a layer it does not have (ogr2ogr treats that as a hard failure) and
    # so coverage questions are answerable without reopening the cell.
    present = {}
    for name in encspec.LAYERS:
        lyr = ds.GetLayerByName(name)
        if lyr is None:
            continue
        n = lyr.GetFeatureCount()
        if n > 0:
            present[name] = n
    rec["layers"] = present
    return rec


def main(argv):
    if len(argv) != 3:
        sys.exit(f"usage: {os.path.basename(argv[0])} <ENC_ROOT> <out.json>")
    root, outpath = argv[1], argv[2]
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    paths = find_cells(root)
    if not paths:
        sys.exit(f"no .000 cells found under {root} — is this an expanded ENC_ROOT?")

    t0 = time.time()
    cells, bad = [], []
    for i, p in enumerate(paths, 1):
        rec = read_cell(p)
        if not rec.get("band") or not rec.get("bbox") or not rec.get("issued"):
            bad.append(rec)
        else:
            cells.append(rec)
        if i % 1000 == 0:
            print(f"  {i}/{len(paths)} cells  ({time.time()-t0:.0f}s)", file=sys.stderr)

    if bad:
        print(f"!! {len(bad)} cell(s) lack band/bbox/issue date — refusing to write a partial index:",
              file=sys.stderr)
        for r in bad[:20]:
            print(f"     {r.get('ident')}  band={r.get('band')} bbox={'y' if r.get('bbox') else 'n'} "
                  f"issued={r.get('issued')} {r.get('error','')}", file=sys.stderr)
        sys.exit(1)

    issued = sorted(c["issued"] for c in cells)
    index = {
        "source": "https://charts.noaa.gov/ENCs/All_ENCs.zip",
        "enc_root": os.path.abspath(root),
        "cell_count": len(cells),
        # The set's vintage is the newest issue date it contains — derived from the data, so a pack
        # built from a stale download cannot label itself current.
        "enc_vintage": issued[-1],
        "enc_oldest": issued[0],
        "indexed_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "band_zoom": {str(k): list(v) for k, v in encspec.BAND_ZOOM.items()},
        "cells": cells,
    }
    with open(outpath, "w") as fh:
        json.dump(index, fh)

    by_band = {}
    for c in cells:
        by_band.setdefault(c["band"], []).append(c)
    print(f"\nindexed {len(cells)} cells in {time.time()-t0:.0f}s  →  {outpath}")
    print(f"ENC vintage (newest cell issue date): {index['enc_vintage']}   "
          f"oldest: {index['enc_oldest']}")
    print(f"{'band':>4} {'name':9s} {'zooms':>7} {'cells':>6} {'median 1:scale':>15} {'natural z':>10}")
    for b in sorted(by_band):
        cs = by_band[b]
        scales = sorted(c["scale"] for c in cs if c.get("scale"))
        med = scales[len(scales) // 2] if scales else 0
        zlo, zhi = encspec.BAND_ZOOM.get(b, (None, None))
        print(f"{b:>4} {encspec.BAND_NAME.get(b,'?'):9s} {f'z{zlo}-{zhi}':>7} {len(cs):6d} "
              f"{med:15,} {encspec.natural_zoom(med):10.1f}")
    nonmcovr = [c for c in cells if c.get("bbox_from") != "M_COVR"]
    if nonmcovr:
        print(f"\n⚠ {len(nonmcovr)} cell(s) had no M_COVR; bbox came from layer extents")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
