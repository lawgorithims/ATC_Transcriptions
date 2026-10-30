"""Ground-truth gate for the avoid map: does it mark what it claims to, and leave runways clear?

    python3 -I lz/avoid/gate.py [--map $AVOID_WORK/out/avoid_conus.mbtiles] [--json out.json]

Features come from OpenStreetMap through Overpass, for EVALUATION ONLY (cached under lz/data/eval/,
never fused into the map). They are independent of every source the map was built from, except that
~24% of the HIFLD lines cite OSM, so line recall is partly circular.

Each check runs at z12 (the map's resolution) and at z10, where a pilot looks at a whole region: the
hazards must survive the zoom-out and the runways must not drown in their neighbours.

  hard  blocks publishing (exit 1)
  soft  reported for triage
  info  measured and reported, no bar (what the map says it does NOT map)

TWO QUESTIONS, KEPT APART (first run, 2026-10-29). Against OSM, lines scored 87.5% and solar 75%, and
the misses were NOT the pipeline: 74% of missed line samples are over 1.5 km from any HIFLD line and
87% of missed solar plants over 300 m from any USPVDB polygon — features the public-domain national
sources do not contain. So:
  * FIDELITY (hard, 99%): sampled from the map's OWN sources, the map must mark them. This is the
    pipeline test, and the one a silent drop would fail.
  * COVERAGE (hard floor just under the first measurement; the number is disclosed): what share of the
    hazards OSM knows the sources hold. A fall below the floor means a source changed or broke.
Runways: the map can only clear runways it knows. The bar applies to OSM runways near an airport the
FAA lists; runways with no listed airport within 1.5 km are reported, not judged.
"""
import argparse
import json
import math
import os
import random
import sqlite3
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import common as C  # noqa: E402
import eval_groundtruth as EG  # noqa: E402   (Overpass cache, point sampling)

IOWA = (42.10, -94.10, 42.55, -93.50)
NC = (35.35, -78.45, 35.80, -77.85)
FLORIDA = (27.70, -81.75, 28.15, -81.25)
HUDSON = (41.45, -74.25, 41.90, -73.80)
FRONT_RANGE = (39.55, -105.35, 40.05, -104.85)
SWEETWATER = (32.25, -100.75, 32.70, -100.15)
YAKIMA = (46.25, -120.75, 46.70, -120.20)
TEHACHAPI = (34.95, -118.45, 35.20, -118.10)

ANY = 0xFF
SHOWN = C.HAZARD | C.STEEP          # what the app draws with "cover" off (the default)

# expect "marked": rate = share of samples with any of `bits` set; "clear": share with none set.
CHECKS = [
    {"name": "transmission lines (OSM coverage)", "level": "hard", "expect": "marked", "bits": C.WIRES,
     "min": 0.85, "kind": "line", "every": 60, "filter": '["power"="line"]', "limit": 300,
     "boxes": [EG.MESILLA, EG.IMPERIAL, EG.WEST_PHX, IOWA, NC, HUDSON]},
    {"name": "solar plants (OSM coverage)", "level": "hard", "expect": "marked", "bits": C.SOLAR, "min": 0.70,
     "kind": "poly", "k": 8, "filter": '["power"="plant"]["plant:source"="solar"]', "limit": 200,
     "boxes": EG.SOLAR + [NC, FLORIDA]},
    {"name": "wind turbines", "level": "hard", "expect": "marked", "bits": C.OBSTACLE, "min": 0.95,
     "kind": "node", "filter": '["generator:source"="wind"]', "limit": 400,
     "boxes": [SWEETWATER, IOWA, TEHACHAPI]},
    {"name": "runways at FAA-listed fields", "level": "hard", "expect": "clear", "bits": ANY, "min": 0.98,
     "kind": "line", "every": 60, "filter": '["aeroway"="runway"]', "limit": 100, "near_faa": True,
     "boxes": [EG.MESILLA, EG.IMPERIAL, EG.FRESNO, IOWA, NC, FLORIDA, HUDSON]},
    {"name": "runways the map cannot place", "level": "info", "expect": "clear", "bits": ANY, "min": 0.0,
     "kind": "line", "every": 60, "filter": '["aeroway"="runway"]', "limit": 100, "near_faa": False,
     "boxes": [EG.MESILLA, EG.IMPERIAL, EG.FRESNO, IOWA, NC, FLORIDA, HUDSON]},
    {"name": "HIFLD lines (fidelity)", "level": "hard", "expect": "marked", "bits": C.WIRES, "min": 0.99,
     "kind": "source", "source": "lines", "boxes": [EG.MESILLA, IOWA, NC, HUDSON, FRONT_RANGE]},
    {"name": "USPVDB solar (fidelity)", "level": "hard", "expect": "marked", "bits": C.SOLAR, "min": 0.99,
     "kind": "source", "source": "solar", "boxes": EG.SOLAR + [NC, FLORIDA]},
    {"name": "obstacles + turbines (fidelity)", "level": "hard", "expect": "marked", "bits": C.OBSTACLE | C.WIRES,
     "min": 0.99, "kind": "source", "source": "points", "boxes": [SWEETWATER, IOWA, TEHACHAPI, NC, HUDSON]},
    {"name": "orchards and vineyards", "level": "soft", "expect": "marked", "bits": C.ORCHARD | C.TREES,
     "min": 0.75, "kind": "poly", "k": 4, "filter": '["landuse"~"^(orchard|vineyard)$"]', "limit": 300,
     "boxes": [EG.FRESNO, EG.MESILLA, YAKIMA]},
    {"name": "forest", "level": "soft", "expect": "marked", "bits": C.TREES, "min": 0.80,
     "kind": "poly", "k": 4, "filter": '["landuse"="forest"]', "limit": 300, "boxes": [NC, HUDSON, FRONT_RANGE]},
    {"name": "residential", "level": "soft", "expect": "marked", "bits": C.DEVELOPED, "min": 0.60,
     "kind": "poly", "k": 3, "filter": '["landuse"="residential"]', "limit": 300, "boxes": [EG.PHX, HUDSON]},
    {"name": "farmland interiors (as drawn)", "level": "soft", "expect": "clear", "bits": SHOWN, "min": 0.90,
     "kind": "poly", "k": 6, "filter": '["landuse"="farmland"]', "limit": 300, "boxes": [EG.IMPERIAL, IOWA]},
    {"name": "dry lakebeds (any reason)", "level": "soft", "expect": "clear", "bits": ANY, "min": 0.95,
     "kind": "poly", "k": 40, "filter": f'["name"~"^({EG.LAKEBEDS})( Dry)? (Lake|Playa)$"]', "limit": 50,
     "boxes": [(32.0, -122.0, 37.0, -105.0)]},
    {"name": "distribution lines (not mapped)", "level": "info", "expect": "marked", "bits": C.WIRES,
     "min": 0.0, "kind": "line", "every": 60, "filter": '["power"="minor_line"]', "limit": 300,
     "boxes": [EG.MESILLA, IOWA, NC]},
]
FAA_RADIUS_KM = 1.5
# FAA records that cannot place their own runway, each checked against OSM's geometry for that runway.
# Their runways are reported with the unlisted ones ("cannot place"), not judged: the map clears what a
# record locates, and a record that puts the field elsewhere locates nothing.
KNOWN_MISPLACED_FIELDS = {
    "CA41": "Quinn, private: NASR reference point 423 m from the runway's centre (OSM area runway 776 m, "
            "137° true; NASR 13/31, 2,400 ft, no surveyed ends). Found 2026-10-29: 19 of the 25 painted "
            "z10 samples at FAA-listed fields.",
}
ZOOMS = (C.ZOOM, 10)


class MapSampler:
    """Pixel lookup in the merged map at one zoom (tiles cached). A missing tile is all-clear: the
    merge writes only tiles with something in them."""

    def __init__(self, path, zoom):
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.zoom, self.cache = zoom, {}

    def byte(self, lon, lat):
        n = 1 << self.zoom
        fx = (lon + 180.0) / 360.0 * n
        fy = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
        x, y = int(fx), int(fy)
        if (x, y) not in self.cache:
            row = self.db.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                                  (self.zoom, x, C.tms_row(y, self.zoom))).fetchone()
            t = C.unpack_tile(row[0]) if row else None
            assert row is None or t is not None, f"undecodable tile z{self.zoom}/{x}/{y}"
            self.cache[(x, y)] = t
        t = self.cache[(x, y)]
        if t is None:
            return 0
        return int(t[min(C.TILE - 1, int((fy - y) * C.TILE)), min(C.TILE - 1, int((fx - x) * C.TILE))])


def faa_fields():
    """NASR airports, gliderports and ultralight fields as a 0.1° grid of (lon, lat, ident)."""
    apt = os.path.join(os.path.dirname(os.path.dirname(HERE)), "ios", "ATCTranscribe", "Resources", "nav", "apt.sqlite")
    db = sqlite3.connect(f"file:{apt}?mode=ro", uri=True)
    grid = {}
    for ident, lat, lon in db.execute("SELECT ident, lat, lon FROM airport WHERE site_type IN ('A','G','U') AND lat IS NOT NULL"):
        grid.setdefault((int(lon * 10), int(lat * 10)), []).append((lon, lat, ident))
    return grid


def near_faa(grid, lon, lat):
    """True when the nearest listed field within FAA_RADIUS_KM is one whose record places its runway."""
    best = None
    for gx in range(int(lon * 10) - 1, int(lon * 10) + 2):           # bounded: 3x3 grid cells
        for gy in range(int(lat * 10) - 1, int(lat * 10) + 2):
            for alon, alat, ident in grid.get((gx, gy), ()):
                d = math.hypot((alon - lon) * 111.32 * math.cos(math.radians(lat)), (alat - lat) * 110.54)
                if d <= FAA_RADIUS_KM and (best is None or d < best[0]):
                    best = (d, ident)
    return best is not None and best[1] not in KNOWN_MISPLACED_FIELDS


def source_points(check, rng):
    """Points ON the map's own inputs inside the check's boxes (lon, lat)."""
    from osgeo import ogr
    ogr.UseExceptions()
    pts = []
    for (s, w, n, e) in check["boxes"]:                               # bounded by the boxes
        x0, y0 = C.lonlat_to_merc(w, s)
        x1, y1 = C.lonlat_to_merc(e, n)
        if check["source"] == "points":
            pz = np.load(os.path.join(C.SHARED, "points.npz"))
            sel = (pz["x"] >= x0) & (pz["x"] <= x1) & (pz["y"] >= y0) & (pz["y"] <= y1) & ((pz["bit"] & C.OBSTACLE) != 0)
            pts += [_ll(x, y) for x, y in zip(pz["x"][sel], pz["y"][sel])]
            continue
        ds = ogr.Open(os.path.join(C.SHARED, {"lines": "lines_3857.gpkg", "solar": "solar_3857.gpkg"}[check["source"]]))
        lyr = ds.GetLayer(0)
        lyr.SetSpatialFilterRect(x0, y0, x1, y1)
        for f in lyr:                                                 # bounded by the features in a box
            g = f.GetGeometryRef()
            if check["source"] == "lines":
                g = g.Clone()
                g.Segmentize(60.0 / math.cos(math.radians((s + n) / 2)))
                for part in ([g] if g.GetGeometryCount() == 0 else [g.GetGeometryRef(i) for i in range(g.GetGeometryCount())]):
                    pts += [_ll(*part.GetPoint_2D(i)) for i in range(part.GetPointCount())]
            else:
                env = g.GetEnvelope()
                for _ in range(40):                                   # bounded tries per polygon
                    x, y = rng.uniform(env[0], env[1]), rng.uniform(env[2], env[3])
                    pt = ogr.Geometry(ogr.wkbPoint)
                    pt.AddPoint_2D(x, y)
                    if g.Contains(pt):
                        pts.append(_ll(x, y))
                        break
    pts = [p for p in pts if _box_of(check, *p)]                    # whole features reach past their box
    rng.shuffle(pts)
    return pts[:4000]


def _ll(x, y):
    return C.merc_x_to_lon(float(x)), C.merc_y_to_lat(float(y))


def _box_of(check, lon, lat):
    return next((b for b in check["boxes"] if b[1] <= lon <= b[3] and b[0] <= lat <= b[2]), None)


def points(check, rng, grid):
    if check["kind"] == "source":
        return source_points(check, rng)
    if check["kind"] == "node":
        pts = []
        for (s, w, n, e) in check["boxes"]:                           # bounded by the boxes
            els = EG.overpass(f'[out:json][timeout:150];node{check["filter"]}({s},{w},{n},{e});out {check["limit"]};')
            pts += [(el["lon"], el["lat"]) for el in els if "lon" in el]
        rng.shuffle(pts)
        return pts[:4000]
    pts = EG.points_for(check, rng)
    if "near_faa" in check:
        pts = [p for p in pts if near_faa(grid, *p) == check["near_faa"]]
    return pts


def run(path):
    samplers = {z: MapSampler(path, z) for z in ZOOMS}
    rng = random.Random(1029)
    grid = faa_fields()
    results, failed = [], []
    for check in CHECKS:                                              # bounded: the check list
        pts = points(check, rng, grid)
        assert check["level"] == "info" or pts, f"{check['name']}: no OSM features — Overpass?"
        for z in ZOOMS:                                               # bounded: two zooms
            hits = sum(1 for lon, lat in pts if samplers[z].byte(lon, lat) & check["bits"])
            share = hits / len(pts) if pts else 0.0
            rate = share if check["expect"] == "marked" else 1.0 - share
            ok = rate >= check["min"]
            tag = "info" if check["level"] == "info" else ("PASS" if ok else check["level"].upper())
            results.append({"check": check["name"], "zoom": z, "n": len(pts), "rate": round(rate, 3),
                            "min": check["min"], "expect": check["expect"], "level": check["level"], "pass": ok})
            print(f"{tag:5s} z{z}  {check['name']:34s} {rate:6.1%} {check['expect']:6s} "
                  f"(n={len(pts)}, bar {check['min']:.0%})", flush=True)
            if check["level"] == "hard" and not ok:
                failed.append(f"{check['name']} @z{z}: {rate:.1%} < {check['min']:.0%}")
    return results, failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default=os.path.join(C.WORK, "out", "avoid_conus.mbtiles"))
    ap.add_argument("--json")
    a = ap.parse_args()
    assert os.path.exists(a.map), f"no map at {a.map}"
    results, failed = run(a.map)
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"map": a.map, "results": results, "failed": failed}, f, indent=1)
    if failed:
        print("GATE FAILED:\n  " + "\n  ".join(failed))
        sys.exit(1)
    print("GATE PASSED")


if __name__ == "__main__":
    main()
