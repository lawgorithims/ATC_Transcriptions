"""Merge every built cell into ONE national avoid map (MBTiles), z12 down to z8.

    python3 -I lz/avoid/merge.py [--slope-deg 6] [--out $AVOID_WORK/out/avoid_conus.mbtiles]

Cells paint only the pixels they own, so a border tile is the OR of its cells' masks (slope: max,
where 0 means "not mine" and 255 "unknown"). The steep bit is applied HERE from the stored slope, so
the threshold can be recalibrated in minutes without rebuilding a single cell.

The 6° default is calibrated (2026-10-29) against the fine slope in the 91 Southwest landability packs
(1 m lidar where flown, else 10 m; 18,835 land samples). At 30 m the slope reads low on short banks:
above 6° here catches 84% of the ground the fine terrain puts at 12° or more (where the landability
ruleset scores zero) and marks 0.2% of ground it puts at 4° or less. 10° caught only 68%.

Overviews: the hidden hazards (wires, obstacles, solar, orchards) survive any zoom-out (OR of the
2x2 below), because a pilot zoomed out still needs to see a line of wires. The broad cover reasons
(water, developed, trees, steep) need a majority of the 2x2, so they do not swell up the pyramid —
plain OR took the old layer's slope-excluded share from 16% to 73% between z13 and z8.
"""
import argparse
import glob
import hashlib
import json
import os
import sqlite3
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

STAGE = os.path.join(C.WORK, "merge_stage.sqlite")


def ok_cells():
    out = []
    for rp in sorted(glob.glob(os.path.join(C.CELLS, "*.json"))):   # bounded by the cells on disk
        with open(rp) as f:
            r = json.load(f)
        if r.get("status") == "ok" and os.path.exists(rp[:-5] + ".sqlite"):
            out.append(r["cell"])
    return out


def stage_z12(cells):
    """OR every cell's tiles into one staging table (slope: max)."""
    if os.path.exists(STAGE):
        os.remove(STAGE)
    st = sqlite3.connect(STAGE)
    st.execute("CREATE TABLE t (x INTEGER, y INTEGER, mask BLOB, slope BLOB, PRIMARY KEY (x, y))")
    merged = 0
    for i, cell in enumerate(cells):                                # bounded by the cells
        src = sqlite3.connect(os.path.join(C.CELLS, f"{cell}.sqlite"))
        for x, y, mb, sb in src.execute("SELECT x, y, mask, slope FROM tiles"):
            row = st.execute("SELECT mask, slope FROM t WHERE x=? AND y=?", (x, y)).fetchone()
            if row is not None:
                m = C.unpack_tile(row[0]) | C.unpack_tile(mb)
                s = np.maximum(C.unpack_tile(row[1]), C.unpack_tile(sb))
                mb, sb = C.pack_tile(m), C.pack_tile(s)
                merged += 1
            st.execute("INSERT OR REPLACE INTO t VALUES (?, ?, ?, ?)", (x, y, mb, sb))
        src.close()
        if i % 100 == 0:
            st.commit()
    st.commit()
    n = st.execute("SELECT COUNT(*) FROM t").fetchone()[0]
    return st, n, merged


def downsample(children):
    """Four 256x256 child masks (None = clear) → one 256x256 parent."""
    big = np.zeros((2 * C.TILE, 2 * C.TILE), np.uint8)
    for (dx, dy), arr in children.items():
        if arr is not None:
            big[dy * C.TILE:(dy + 1) * C.TILE, dx * C.TILE:(dx + 1) * C.TILE] = arr
    q = [big[0::2, 0::2], big[1::2, 0::2], big[0::2, 1::2], big[1::2, 1::2]]
    hazard = (q[0] | q[1] | q[2] | q[3]) & C.HAZARD
    cover = np.zeros_like(hazard)
    for bit in (C.WATER, C.DEVELOPED, C.TREES, C.STEEP):              # bounded: four reasons
        votes = sum(((a & bit) != 0).astype(np.uint8) for a in q)
        cover[votes >= 2] |= bit
    return hazard | cover


class RunwayClearer:
    """Re-clears runways at every zoom. The cells cleared the surveyed ones at z12, but at a coarser
    level a runway's developed neighbours out-vote it and the airport would paint as built-up (the old
    layer vetoed ~40% of runway centrelines).

    Surveyed rectangles (both ends known) clear EVERY reason: nothing on a runway is a reason to avoid
    it. Estimated ones (`prep_runways_approx`: one-runway fields NASR lists without surveyed ends,
    mostly private strips) clear only what a runway's own pixels collect — built-up, trees, steep,
    orchard — never wires, obstacles or solar, because an estimate can sit beside the strip."""

    SOFT = C.DEVELOPED | C.TREES | C.STEEP | C.ORCHARD

    def __init__(self):
        from osgeo import gdal, ogr, osr
        self.gdal, self.ogr = gdal, ogr
        self.layers = []
        for name, keep in (("runways_3857.gpkg", 0), ("runways_approx_3857.gpkg", 0xFF & ~self.SOFT)):
            ds = ogr.Open(os.path.join(C.SHARED, name))
            assert ds is not None, f"{name} missing — run prep.py"
            self.layers.append((ds, ds.GetLayer(0), keep))
        srs = osr.SpatialReference()
        srs.ImportFromEPSG(3857)
        self.wkt = srs.ExportToWkt()

    def clear(self, arr, z, x, y):
        tile_m = 2 * C.ORIGIN / (1 << z)
        xmin, ymax = -C.ORIGIN + x * tile_m, C.ORIGIN - y * tile_m
        for _, lyr, keep in self.layers:                             # bounded: two layers
            lyr.SetSpatialFilterRect(xmin, ymax - tile_m, xmin + tile_m, ymax)
            if lyr.GetFeatureCount() == 0:
                continue
            mem = self.gdal.GetDriverByName("MEM").Create("", C.TILE, C.TILE, 1, self.gdal.GDT_Byte)
            mem.SetGeoTransform((xmin, tile_m / C.TILE, 0.0, ymax, 0.0, -tile_m / C.TILE))
            mem.SetProjection(self.wkt)
            self.gdal.RasterizeLayer(mem, [1], lyr, burn_values=[1], options=["ALL_TOUCHED=TRUE"])
            on = mem.GetRasterBand(1).ReadAsArray() > 0
            arr[on] &= np.uint8(keep)


def open_mbtiles(tmp, meta):
    """The output, index first: every overview level is built by reading the level below back from it,
    so the pyramid never has to be held in memory (z12 alone is ~10 GB of masks)."""
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    db.execute("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
    db.execute("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
    for k, v in meta.items():
        db.execute("INSERT INTO metadata VALUES (?, ?)", (k, v if isinstance(v, str) else json.dumps(v)))
    db.commit()
    return db


def put(db, z, x, y, arr):
    db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (z, x, C.tms_row(y, z), C.pack_tile(arr)))


def get(db, z, x, y):
    row = db.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                     (z, x, C.tms_row(y, z))).fetchone()
    if row is None:
        return None
    arr = C.unpack_tile(row[0])
    assert arr is not None, f"undecodable tile z{z}/{x}/{y} in the output"
    return arr


def write_z12(st, db, slope_deg, clearer):
    """z12 with the steep bit applied from the stored slope and the runways cleared; all-clear tiles
    are not written (a missing tile is clear)."""
    limit = int(round(slope_deg / C.SLOPE_STEP_DEG))
    n = 0
    for x, y, mb, sb in st.execute("SELECT x, y, mask, slope FROM t"):   # bounded by the staged tiles
        m = C.unpack_tile(mb).copy()
        s = C.unpack_tile(sb)
        m[(s != C.SLOPE_UNKNOWN) & (s > limit)] |= C.STEEP
        clearer.clear(m, C.ZOOM, x, y)
        if m.any():
            put(db, C.ZOOM, x, y, m)
            n += 1
            if n % 5000 == 0:
                db.commit()
    db.commit()
    return n


def write_level(db, z, clearer):
    """One overview level, from the level below as written."""
    below = 1 << (z + 1)
    kids = db.execute("SELECT tile_column, tile_row FROM tiles WHERE zoom_level=?", (z + 1,)).fetchall()
    parents = sorted({(x // 2, (below - 1 - r) // 2) for x, r in kids})   # TMS row → XYZ parent
    n = 0
    for px, py in parents:                                           # bounded by the tiles below
        arr = downsample({(dx, dy): get(db, z + 1, 2 * px + dx, 2 * py + dy) for dx in (0, 1) for dy in (0, 1)})
        clearer.clear(arr, z, px, py)
        if arr.any():
            put(db, z, px, py, arr)
            n += 1
    db.commit()
    return n


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):             # bounded by the file
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slope-deg", type=float, default=6.0)
    ap.add_argument("--out", default=os.path.join(C.WORK, "out", "avoid_conus.mbtiles"))
    ap.add_argument("--reuse-stage", action="store_true", help="skip re-staging (threshold recalibration)")
    a = ap.parse_args()
    assert 4.0 <= a.slope_deg <= 25.0, "slope threshold out of range"
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    t0 = time.time()
    cells = ok_cells()
    assert len(cells) > 800, f"only {len(cells)} built cells — the run is not finished"
    if a.reuse_stage and os.path.exists(STAGE):
        st = sqlite3.connect(STAGE)
        n12, merged = st.execute("SELECT COUNT(*) FROM t").fetchone()[0], None
    else:
        st, n12, merged = stage_z12(cells)
    print(f"staged {n12} z12 tiles from {len(cells)} cells ({merged} border merges) {time.time() - t0:.0f}s",
          flush=True)
    with open(os.path.join(C.SHARED, "inputs.json")) as f:
        inputs = json.load(f)
    tmp = a.out + ".part"
    db = open_mbtiles(tmp, build_meta(cells, a.slope_deg, inputs))
    clearer = RunwayClearer()
    counts = {C.ZOOM: write_z12(st, db, a.slope_deg, clearer)}
    print(f"z{C.ZOOM}: {counts[C.ZOOM]} tiles {time.time() - t0:.0f}s", flush=True)
    for z in range(C.ZOOM - 1, C.MIN_ZOOM - 1, -1):                  # bounded: z11..z8
        counts[z] = write_level(db, z, clearer)
        print(f"z{z}: {counts[z]} tiles {time.time() - t0:.0f}s", flush=True)
    db.execute("VACUUM")
    db.close()
    os.replace(tmp, a.out)
    size = os.path.getsize(a.out)
    digest = sha256(a.out)
    report = {"path": a.out, "bytes": size, "sha256": digest, "tiles_per_zoom": counts,
              "cells": len(cells), "slope_deg": a.slope_deg, "seconds": round(time.time() - t0)}
    with open(a.out + ".json", "w") as f:
        json.dump(report, f, indent=1)
    print(json.dumps(report, indent=1))


def build_meta(cells, slope_deg, inputs):
    return {
        "name": "Obelisk where-not-to-go map (CONUS)",
        "format": "avoid1",
        "avoid_schema": "1",
        "minzoom": str(C.MIN_ZOOM), "maxzoom": str(C.ZOOM),
        "bounds": ",".join(str(v) for v in C.CONUS_BBOX),
        "bits": {name: bit for bit, name in C.BIT_NAMES.items()},
        "cover_bits": str(C.COVER), "hazard_bits": str(C.HAZARD),
        "slope_threshold_deg": str(slope_deg),
        "cells": cells,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "vintages": inputs.get("vintages", {}),
        "built_from": inputs.get("built_from", {}),
        "license": "ODbL-1.0",
        "attribution": ("Land cover: USGS Annual NLCD. Crops: USDA NASS CDL. Elevation: USGS 3DEP. "
                        "Obstacles: FAA DOF. Solar: USGS USPVDB. Wind turbines: USGS USWTDB. "
                        "Transmission lines: HIFLD/ORNL, which includes data © OpenStreetMap contributors. "
                        "Advisory only — not for navigation."),
        "caveat": ("Shows only reasons NOT to land. Unpainted ground is not checked: distribution wires, "
                   "fences, ditches, crops, livestock and surface condition are not mapped anywhere public."),
    }


if __name__ == "__main__":
    main()
