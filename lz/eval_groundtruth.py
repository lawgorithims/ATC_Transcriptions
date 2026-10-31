#!/usr/bin/env python3
"""Ground-truth evaluation of the landability packs: the DEVICE's own verdict, at real places.

WHY THIS EXISTS. Every pack this pipeline built passed `verify.py`, and every one of those gates is
structural — tile counts, decode round-trips, that slope was measured at all. None of them ever asked
the question the layer exists to answer: does it call the right ground landable? The first time that
was asked (2026-10), the device's verdict offered 79% of solar farms, 53% of Fresno's orchards and
vineyards, and 27% of the ground directly under transmission lines as landing candidates, while
vetoing ~40% of runway centrelines. Structural validity is not having measured anything; this measures.

WHAT IT DOES
  1. Ports the device scoring EXACTLY — `LZRulesetCompiler` + `LZTileCompositor.verdict`, integer
     arithmetic and all — and pins the port to Swift through `lz/eval/golden_scores.json`, which a
     Swift test (`LZScoreGoldenTests`) recomputes on the device code. If either side drifts, a test
     fails; the evaluator can never quietly measure a different layer from the one pilots see.
  2. Samples every built pack, read-only, at independently mapped ground: OpenStreetMap features of
     known landability (runways, dry lakebeds, farmland; orchards, vineyards, solar farms, ground under
     power lines, fences, canals, residential). Each pixel is read from the pack whose own 1° cell
     contains it — the device's owner-pack rule — never from a neighbour's margin.
  3. Reports, per feature set: how often the device paints it green, how often the site finder would
     OFFER it (score >= 55, not vetoed), and how often it is excluded. Optionally the glide survey and
     the route-exposure table from the same deep dive.
  4. `--gate` turns the thresholds into an exit status, for any future pack or rule change.

⚠️ OSM IS EVALUATION-ONLY. OpenStreetMap is ODbL, and the pipeline's licence boundary is that it never
fuses into a pack (see `verify.gate_odbl`). Features are fetched at run time, cached under the
gitignored `lz/data/eval/`, used to score the packs, and written nowhere else.

Usage:
  python3 lz/eval_groundtruth.py                  # feature-set table
  python3 lz/eval_groundtruth.py --survey --routes
  python3 lz/eval_groundtruth.py --gate           # exit 1 if any threshold fails
  python3 lz/eval_groundtruth.py --golden-write   # regenerate the Swift pin (after a ruleset change)
  python3 lz/eval_groundtruth.py --golden-check   # the port still matches the pinned cases
"""
import argparse
import hashlib
import json
import math
import os
import random
import sqlite3
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lzcommon as C                                                    # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, ".."))
RULESET = os.path.join(ROOT, "ios", "ATCTranscribe", "Resources", "lz", "lz_ruleset_v1.json")
TERRAIN = os.path.join(ROOT, "ios", "ATCTranscribe", "Resources", "terrain")
APT_DB = os.path.join(ROOT, "ios", "ATCTranscribe", "Resources", "nav", "apt.sqlite")
OUT_DIR = os.path.join(HERE, "out")
CACHE_DIR = os.path.join(HERE, "data", "eval")                          # gitignored (lz/data/)
GOLDEN = os.path.join(HERE, "eval", "golden_scores.json")
UA = "CommSight-LZ-groundtruth-eval/1.0 (research; read-only)"
OVERPASS = "https://overpass-api.de/api/interpreter"

GREEN_FROM = 62          # LZTileCompositor: the green band starts at 0.62
OFFER_FROM = 55          # LZSiteFinder.minScore
UNKNOWN, EXCLUDED = -2, -1


def swift_round(x):
    """Swift's `.rounded()` — halves away from zero. Python's round() is banker's and would differ."""
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def interpolate(pts, x):
    """`LZRulesetCompiler.interpolate`: piecewise linear over [[x, y], ...], clamped at both ends."""
    if x <= pts[0][0]:
        return pts[0][1]
    prev = pts[0]
    for p in pts[1:]:
        if x <= p[0]:
            span = p[0] - prev[0]
            if span <= 0:
                return p[1]
            return prev[1] + (x - prev[0]) / span * (p[1] - prev[1])
        prev = p
    return prev[1]


def quantise(u):
    return int(max(0, min(255, swift_round(max(0.0, min(1.0, u)) * 255))))


CLASS_CODE = {"unknown": 0, "open_firm": 1, "open_soft": 2, "crop": 3, "brush": 4, "forest": 5,
              "developed_open": 6, "developed_dense": 7, "barren_rough": 8, "water": 9,
              "wetland": 10, "snow_ice": 11}
FLAG_BIT = {"dof_tower": C.FLAG_DOF_TOWER, "tx_corridor": C.FLAG_TX_CORRIDOR,
            "road_buffer": C.FLAG_ROAD_BUFFER, "water_veto": C.FLAG_WATER_VETO,
            "wetland": C.FLAG_WETLAND, "coarse_terrain": C.FLAG_COARSE_TERRAIN}


class DeviceScore:
    """The device verdict for ONE aircraft — an exact port, pinned by `golden_scores.json`.

    Defaults to the ruleset's own aircraft (no profile), which is what a pilot gets until they enter
    their numbers, and what every table in the deep dive was measured with.
    """

    def __init__(self, doc, vref=None, book_ft=None):
        d = doc["aircraft_defaults"]
        vref = max(30.0, min(200.0, float(vref if vref is not None else int(d["vref_kt"]))))
        book = book_ft if book_ft is not None else d.get("landing_over_50ft") or 1600.0
        book = max(300.0, min(12_000.0, book))
        w = [doc["weights"][k] for k in ("surface", "slope", "rough", "hazard")]
        assert abs(sum(w) - 1.0) < 0.001, "weights must partition unity"
        self.w = [int(swift_round(x * 255)) for x in w]
        slope_scale = max(0.6, min(1.6, (d["vref_kt"] / vref) * d["slope_tolerance_scale"]))
        U = doc["utilities"]
        self.slope = [0 if raw == C.SLOPE_NODATA else
                      quantise(interpolate(U["slope_deg"]["breakpoints"], raw * C.SLOPE_STEP_DEG / slope_scale))
                      for raw in range(256)]
        self.rough = [0 if raw == C.ROUGH_NODATA else
                      quantise(interpolate(U["rough_m"]["breakpoints"], raw / 100.0)) for raw in range(256)]
        self.hazard = [quantise(interpolate(U["hazard"]["breakpoints"], raw / 255.0)) for raw in range(256)]

        e = doc["energy_model"]
        emul = max(e["multiplier_min"], min(e["multiplier_max"], 1.3 - vref / e["reference_kt"]))
        dm = doc.get("distance_model") or {}
        table = U["surface_class"]["table"]
        names = {v: k for k, v in CLASS_CODE.items()}
        self.surface = []
        for code in range(256):
            name = names.get(code, "unknown")
            u = table.get(name, 0.0)
            if name in e["applies_to"]:
                u = min(1.0, u * emul)
            if dm and name in dm.get("applies_to", []):
                # The device divides the per-surface factor straight back out (LZRuleset.swift), so
                # the ratio is reference / book. Ported as the device does it, not as intended.
                ratio = dm["reference_over_50ft"] / max(1.0, book)
                u = min(1.0, u * max(dm["multiplier_min"], min(dm["multiplier_max"], ratio)))
            self.surface.append(quantise(u))

        self.veto_class = set()
        self.veto_no_data = False
        self.slope_veto_above = 254
        for r in doc["vetoes"]:
            when = r["when"]
            if when.startswith("class == "):
                self.veto_class.add(CLASS_CODE[when[len("class == "):]])
            elif when == "slope == nodata":
                self.veto_no_data = True
            elif when.startswith("slope_deg > "):
                deg = float(when[len("slope_deg > "):])
                self.slope_veto_above = int(max(0, min(254, swift_round(deg / C.SLOPE_STEP_DEG))))
        self.cap_coarse, self.cap_flag = 100, {}
        self.conf_below, self.conf_cap = 0, 100
        for r in doc["caps"]:
            when, cap = r["when"], r["cap"]
            if when == "terrain_source != fine":
                self.cap_coarse = cap
            elif when.startswith("flag "):
                self.cap_flag[FLAG_BIT[when[5:]]] = cap
            elif when.startswith("conf < "):
                self.conf_below, self.conf_cap = int(when[len("conf < "):]), cap
        em = doc.get("extent_model")
        self.extent_cap, self.extent_veto_at = [], None
        if em:
            req = book * 0.3048 * em["unprepared_factor"]
            self.required_run_m = req
            self.extent_cap = [100 if raw == 255 else
                               int(max(0, min(100, swift_round(interpolate(em["cap_by_ratio"], raw * 10.0 / req)))))
                               for raw in range(256)]
            steps = math.floor(req * em["veto_below_ratio"] / 10.0)
            if steps >= 1:
                self.extent_veto_at = min(254, max(1, steps))

    def verdict(self, cls, conf, slope, rough, hazard, flags, coarse, extent):
        """UNKNOWN, EXCLUDED, or 0…100 — `LZTileCompositor.verdict`, line for line."""
        if cls == 0:
            return UNKNOWN
        if self.veto_no_data and slope == C.SLOPE_NODATA:
            return UNKNOWN
        if cls in self.veto_class:
            return EXCLUDED
        if slope != C.SLOPE_NODATA and slope > self.slope_veto_above:
            return EXCLUDED
        if extent and self.extent_veto_at is not None and extent <= self.extent_veto_at:
            return EXCLUDED
        total = (self.w[0] * self.surface[cls] + self.w[1] * self.slope[slope]
                 + self.w[2] * self.rough[rough] + self.w[3] * self.hazard[hazard])
        s = (total // 255) * 100 // 255
        if coarse:
            s = min(s, self.cap_coarse)
        for bit, cap in self.cap_flag.items():
            if flags & bit:
                s = min(s, cap)
        if conf != 255 and conf < self.conf_below:
            s = min(s, self.conf_cap)
        if extent and self.extent_cap:
            s = min(s, self.extent_cap[extent])
        return max(0, min(100, s))


# ---------------------------------------------------------------------------------------------
# the golden pin
# ---------------------------------------------------------------------------------------------

def golden_cases(n=3000, seed=20261023):
    """Deterministic fact tuples: every class at the edges that matter, plus a seeded spread."""
    rng = random.Random(seed)
    edge_slopes = [0, 9, 10, 25, 40, 59, 60, 61, 120, 254, 255]
    edge_rough = [0, 15, 24, 25, 60, 119, 120, 254, 255]
    edge_haz = [0, 1, 51, 127, 204, 254, 255]
    flag_sets = [0, C.FLAG_TX_CORRIDOR, C.FLAG_ROAD_BUFFER, C.FLAG_WETLAND, C.FLAG_DOF_TOWER,
                 C.FLAG_WATER_VETO, C.FLAG_COARSE_TERRAIN, C.FLAG_TX_CORRIDOR | C.FLAG_WETLAND]
    edge_ext = [0, 1, 36, 37, 44, 63, 64, 73, 95, 146, 254, 255]
    out = []
    for cls in range(12):
        for sl in edge_slopes:
            out.append((cls, 62, sl, 5, 0, 0, 0, 0))
        for ro in edge_rough:
            out.append((cls, 62, 5, ro, 0, 0, 0, 0))
        for hz in edge_haz:
            out.append((cls, 62, 5, 5, hz, 0, 0, 0))
        for fl in flag_sets:
            out.append((cls, 62, 5, 5, 0, fl, 0, 0))
        for ex in edge_ext:
            out.append((cls, 62, 5, 5, 0, 0, 0, ex))
        for conf in (20, 38, 39, 40, 62, 255):
            out.append((cls, conf, 5, 5, 0, 0, 0, 0))
        out.append((cls, 62, 5, 5, 0, 0, 1, 0))
    while len(out) < n:
        out.append((rng.randrange(12), rng.choice([20, 38, 62, 255]), rng.randrange(256),
                    rng.randrange(256), rng.randrange(256), rng.choice(flag_sets),
                    rng.randrange(2), rng.choice([0] + list(range(1, 256)))))
    return out


def ruleset_sha():
    with open(RULESET, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def golden_write(scorer):
    os.makedirs(os.path.dirname(GOLDEN), exist_ok=True)
    cases = [list(c) + [scorer.verdict(*c)] for c in golden_cases()]
    doc = {"note": "Fact tuples [cls, conf, slope, rough, hazard, flags, coarse, extent, expected] "
                   "scored by the DEFAULT aircraft (no profile). expected: -2 unknown, -1 excluded, "
                   "else 0..100. Written by lz/eval_groundtruth.py --golden-write; recomputed on the "
                   "device code by LZScoreGoldenTests. Regenerate whenever the ruleset changes.",
           "ruleset_sha256": ruleset_sha(), "cases": cases}
    with open(GOLDEN, "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    print(f"wrote {len(cases)} golden cases to {os.path.relpath(GOLDEN, ROOT)}")


def golden_check(scorer):
    with open(GOLDEN) as fh:
        doc = json.load(fh)
    if doc["ruleset_sha256"] != ruleset_sha():
        sys.exit("golden cases were made with a different ruleset — run --golden-write and re-run "
                 "LZScoreGoldenTests")
    bad = [c for c in doc["cases"] if scorer.verdict(*c[:8]) != c[8]]
    if bad:
        sys.exit(f"{len(bad)} of {len(doc['cases'])} golden cases disagree, e.g. {bad[0]}")
    print(f"port matches all {len(doc['cases'])} pinned cases")


# ---------------------------------------------------------------------------------------------
# reading the packs — read-only, owner-pack rule
# ---------------------------------------------------------------------------------------------

class PackSampler:
    """Reads the pack whose OWN 1° cell contains a point. Strictly read-only (`mode=ro`)."""

    def __init__(self, out_dir=OUT_DIR, max_tiles=600):
        self.out_dir, self.max_tiles = out_dir, max_tiles
        self.conn, self.tiles = {}, {}

    @staticmethod
    def cell_of(lon, lat):
        return f"n{math.floor(lat) + 1}w{-math.floor(lon)}"

    def facts(self, lon, lat, z=C.NATIVE_ZOOM):
        cell = self.cell_of(lon, lat)
        if cell not in self.conn:
            p = os.path.join(self.out_dir, f"{cell}.lzpack")
            self.conn[cell] = sqlite3.connect(f"file:{p}?mode=ro", uri=True) if os.path.exists(p) else None
        db = self.conn[cell]
        if db is None:
            return None
        n = 1 << z
        xf = (lon + 180) / 360 * n
        yf = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
        tx, ty = int(xf), int(yf)
        key = (cell, tx, ty)
        if key not in self.tiles:
            if len(self.tiles) >= self.max_tiles:                  # bounded memory
                self.tiles.pop(next(iter(self.tiles)))
            row = db.execute("select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
                             (z, tx, C.xyz_to_tms_row(ty, z))).fetchone()
            self.tiles[key] = None if row is None else C.unpack_blob(row[0])
        got = self.tiles[key]
        if got is None:
            return None
        planes, tsrc = got
        px = min(C.TILE_SIDE - 1, int((xf - tx) * C.TILE_SIDE))
        py = min(C.TILE_SIDE - 1, int((yf - ty) * C.TILE_SIDE))
        v = [int(planes[i][py, px]) for i in range(len(planes))]
        extent = v[C.PLANE_EXTENT] if len(v) > C.PLANE_EXTENT else 0
        return (v[C.PLANE_CLASS], v[C.PLANE_CONF], v[C.PLANE_SLOPE], v[C.PLANE_ROUGH],
                v[C.PLANE_HAZARD], v[C.PLANE_FLAGS], int(tsrc != C.TERRAIN_SRC_FINE), extent)


# ---------------------------------------------------------------------------------------------
# independently mapped ground (OSM, evaluation only)
# ---------------------------------------------------------------------------------------------

MESILLA = (32.00, -106.92, 32.45, -106.62)
IMPERIAL = (32.62, -115.75, 33.15, -115.35)
FRESNO = (36.55, -119.95, 36.95, -119.45)
WEST_PHX = (33.00, -112.60, 33.50, -112.00)
PHX = (33.30, -112.20, 33.70, -111.70)
LA = (34.00, -118.50, 34.30, -118.10)
SOLAR = [IMPERIAL, (32.80, -113.00, 33.50, -112.40), (34.60, -118.60, 35.10, -117.60)]
LAKEBEDS = ("Rosamond|El Mirage|Lucerne|Ivanpah|Searles|Willcox|Bristol|Cadiz|Roach|Lavic|Koehn|"
            "Bicycle|Danby|Cuddeback")

# expect: "good" = should be offered; "bad" = must not be.
FEATURE_SETS = [
    {"name": "runway centrelines", "expect": "good", "kind": "line", "every": 60,
     "filter": '["aeroway"="runway"]', "boxes": [MESILLA, IMPERIAL, FRESNO] + SOLAR, "limit": 100},
    {"name": "dry lakebeds", "expect": "good", "kind": "poly", "k": 40,
     "filter": f'["name"~"^({LAKEBEDS})( Dry)? (Lake|Playa)$"]', "boxes": [(32.0, -122.0, 37.0, -105.0)],
     "limit": 50},
    {"name": "farmland interiors (Imperial)", "expect": "good", "kind": "poly", "k": 6,
     "filter": '["landuse"="farmland"]', "boxes": [IMPERIAL], "limit": 300},
    {"name": "orchards + vineyards (Fresno)", "expect": "bad", "kind": "poly", "k": 4,
     "filter": '["landuse"~"^(orchard|vineyard)$"]', "boxes": [FRESNO], "limit": 300},
    {"name": "pecan orchards (Mesilla)", "expect": "bad", "kind": "poly", "k": 6,
     "filter": '["landuse"="orchard"]', "boxes": [MESILLA], "limit": 400},
    {"name": "solar farms", "expect": "bad", "kind": "poly", "k": 8,
     "filter": '["power"="plant"]["plant:source"="solar"]', "boxes": SOLAR, "limit": 200},
    {"name": "under transmission lines", "expect": "bad", "kind": "line", "every": 50,
     "filter": '["power"="line"]', "boxes": [MESILLA, IMPERIAL, FRESNO, WEST_PHX], "limit": 300},
    {"name": "under distribution lines", "expect": "bad", "kind": "line", "every": 50,
     "filter": '["power"="minor_line"]', "boxes": [MESILLA, IMPERIAL, FRESNO, WEST_PHX], "limit": 300},
    {"name": "on fences", "expect": "bad", "kind": "line", "every": 50,
     "filter": '["barrier"="fence"]', "boxes": [MESILLA, IMPERIAL, FRESNO, WEST_PHX], "limit": 300},
    {"name": "on canals / ditches", "expect": "bad", "kind": "line", "every": 50,
     "filter": '["waterway"~"^(canal|ditch|drain)$"]', "boxes": [MESILLA, IMPERIAL, FRESNO, WEST_PHX],
     "limit": 300},
    {"name": "residential areas", "expect": "bad", "kind": "poly", "k": 3,
     "filter": '["landuse"="residential"]', "boxes": [PHX, LA], "limit": 300},
]

# The gate. "bad" ground may be OFFERED at most this often; "good" ground must be offered at least
# this often. Today's packs fail it — by design, so the next pack build has a bar to clear.
GATE_BAD_MAX_OFFERED = 0.05
GATE_GOOD_MIN_OFFERED = 0.85


def overpass(query):
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, hashlib.sha1(query.encode()).hexdigest()[:16] + ".json")
    if os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    req = urllib.request.Request(OVERPASS, data=urllib.parse.urlencode({"data": query}).encode(),
                                 headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(4):                                          # bounded retries
        try:
            els = json.load(urllib.request.urlopen(req, timeout=200))["elements"]
            with open(path, "w") as fh:
                json.dump(els, fh)
            time.sleep(3)                                             # be a polite client
            return els
        except Exception as ex:                                       # noqa: BLE001
            print(f"  overpass retry {attempt + 1}: {type(ex).__name__}", file=sys.stderr)
            time.sleep(20)
    raise RuntimeError("Overpass unreachable — refusing to report a table built on no features")


def _pip(x, y, g):
    inside, j = False, len(g) - 1
    for i in range(len(g)):
        xi, yi = g[i]
        xj, yj = g[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi + 1e-15) + xi:
            inside = not inside
        j = i
    return inside


def points_for(fs, rng):
    pts = []
    for (s, w, n, e) in fs["boxes"]:
        els = overpass(f'[out:json][timeout:150];way{fs["filter"]}({s},{w},{n},{e});out geom {fs["limit"]};')
        for el in els:
            tags = el.get("tags", {})
            if tags.get("disused") == "yes" or "abandoned:aeroway" in tags:
                continue
            g = [(p["lon"], p["lat"]) for p in el.get("geometry", [])]
            if fs["kind"] == "line":
                for (x1, y1), (x2, y2) in zip(g, g[1:]):
                    m = max(1, int(math.hypot((x2 - x1) * 111320 * math.cos(math.radians(y1)),
                                              (y2 - y1) * 110540) / fs["every"]))
                    pts += [(x1 + (x2 - x1) * t / m, y1 + (y2 - y1) * t / m) for t in range(m)]
            elif len(g) >= 4:
                xs, ys = [p[0] for p in g], [p[1] for p in g]
                got = tries = 0
                while got < fs["k"] and tries < 200:                  # bounded
                    tries += 1
                    x, y = rng.uniform(min(xs), max(xs)), rng.uniform(min(ys), max(ys))
                    # 30 m inset: score the feature, not the boundary pixel shared with its neighbour.
                    if all(_pip(x + dx, y + dy, g) for dx, dy in
                           ((0, 0), (3e-4, 0), (-3e-4, 0), (0, 3e-4), (0, -3e-4))):
                        pts.append((x, y))
                        got += 1
    rng.shuffle(pts)
    return pts[:4000]


def evaluate_sets(scorer, sampler, seed=5):
    rng = random.Random(seed)
    rows = []
    for fs in FEATURE_SETS:
        verdicts = []
        for x, y in points_for(fs, rng):
            f = sampler.facts(x, y)
            if f is None:
                continue
            v = scorer.verdict(*f)
            if v != UNKNOWN:
                verdicts.append(v)
        n = len(verdicts)
        rows.append({"name": fs["name"], "expect": fs["expect"], "n": n,
                     "green": sum(1 for v in verdicts if v >= GREEN_FROM) / n if n else None,
                     "offered": sum(1 for v in verdicts if v >= OFFER_FROM) / n if n else None,
                     "excluded": sum(1 for v in verdicts if v == EXCLUDED) / n if n else None})
    return rows


# ---------------------------------------------------------------------------------------------
# glide survey and route exposure — the deep dive's tables B and C
# ---------------------------------------------------------------------------------------------

class Terrain:
    """The app's own bundled glide grid (max-aggregated, 60 cells/degree), read-only."""

    def __init__(self):
        import numpy as np
        with open(os.path.join(TERRAIN, "terrain_conus.json")) as fh:
            self.h = json.load(fh)
        self.g = np.memmap(os.path.join(TERRAIN, "terrain_conus.bin"), dtype="<i2", mode="r",
                           shape=(self.h["rows"], self.h["cols"]))

    def ft(self, lat, lon):
        r = int((self.h["latMax"] - lat) * self.h["cellsPerDegree"])
        c = int((lon - self.h["lonMin"]) * self.h["cellsPerDegree"])
        if not (0 <= r < self.h["rows"] and 0 <= c < self.h["cols"]):
            return None
        v = int(self.g[r, c])
        return None if v == self.h["noData"] else v * 3.28084


def runway_ends(min_len=1500):
    db = sqlite3.connect(f"file:{APT_DB}?mode=ro", uri=True)
    try:
        return db.execute("""select e.lat, e.lon, coalesce(e.elev_ft, a.elev_ft, 0) from runway_end e
                             join runway r on r.ident=e.ident and r.designator=e.designator
                             join airport a on a.ident=e.ident
                             where r.length_ft >= ? and e.lat between 30 and 38.5
                               and e.lon between -123 and -103""", (min_len,)).fetchall()
    finally:
        db.close()


def _nm(a, b, c, d):
    return math.hypot((c - a) * 60, (d - b) * 60 * math.cos(math.radians((a + c) / 2)))


def glide_survey(scorer, sampler, n=300, agls=(1500, 3000, 5000), gr=9.0, reserve=1000.0, seed=21):
    """Straight-line reach, terrain at the destination only — a framing estimate, not the app model."""
    rng = random.Random(seed)
    ter, rw = Terrain(), runway_ends()
    cells = sorted(p[:-7] for p in os.listdir(sampler.out_dir) if p.endswith(".lzpack") and p.startswith("n"))
    origins = []
    while len(origins) < n:                                           # bounded by the sampler
        c = rng.choice(cells)
        la, lw = int(c[1:3]), int(c[4:7])
        lat, lon = rng.uniform(la - 1, la), rng.uniform(-lw, -lw + 1)
        g = ter.ft(lat, lon)
        if g is not None and sampler.facts(lon, lat) is not None:
            origins.append((lat, lon, g))
    rows = []
    for agl in agls:
        apt = offered = only = none = 0
        for lat, lon, g0 in origins:
            msl = g0 + agl
            a = any(msl - e - reserve >= _nm(lat, lon, la2, lo2) * 6076 / gr
                    for la2, lo2, e in rw if _nm(lat, lon, la2, lo2) < 15)
            best = None
            for b in range(0, 360, 10):
                for k in range(1, 41):
                    d = k * 0.3
                    la2 = lat + d / 60 * math.cos(math.radians(b))
                    lo2 = lon + d / 60 * math.sin(math.radians(b)) / math.cos(math.radians(lat))
                    gd = ter.ft(la2, lo2)
                    if gd is None or msl - gd - reserve < d * 6076 / gr:
                        continue
                    f = sampler.facts(lo2, la2)
                    if f is None:
                        continue
                    v = scorer.verdict(*f)
                    if v >= OFFER_FROM and (best is None or v > best):
                        best = v
            apt += a
            offered += best is not None
            only += (not a and best is not None)
            none += (not a and best is None)
        rows.append({"agl_ft": agl, "runway": apt / n, "offered": offered / n,
                     "offered_no_runway": only / n, "nothing": none / n})
    return rows


ROUTES = [("LRU", "TUS", (8500, 10500)), ("LRU", "ABQ", (7500, 9500)), ("ABQ", "FLG", (10500, 12500)),
          ("ELP", "PHX", (8500, 10500)), ("TUS", "SAN", (8500, 10500)), ("FLG", "LAS", (10500, 12500))]


def route_exposure(gr=9.0, reserve=1000.0, tas_kt=110):
    """Share of a DIRECT route out of glide of any runway — still air, terrain at the runway only."""
    import numpy as np
    ter, rw = Terrain(), np.array(runway_ends(), float)
    db = sqlite3.connect(f"file:{APT_DB}?mode=ro", uri=True)
    pos = {i: (la, lo) for i, la, lo in db.execute("select ident, lat, lon from airport")}
    db.close()
    rows = []
    for a, b, alts in ROUTES:
        if a not in pos or b not in pos:
            continue
        (la1, lo1), (la2, lo2) = pos[a], pos[b]
        n = int(_nm(la1, lo1, la2, lo2))
        for msl in alts:
            gap = cur = longest = 0
            for i in range(n + 1):
                t = i / max(1, n)
                la, lo = la1 + (la2 - la1) * t, lo1 + (lo2 - lo1) * t
                d = np.hypot((rw[:, 0] - la) * 60, (rw[:, 1] - lo) * 60 * math.cos(math.radians(la)))
                if np.any(msl - rw[:, 2] - reserve >= d * 6076 / gr):
                    cur = 0
                else:
                    gap += 1
                    cur += 1
                    longest = max(longest, cur)
            rows.append({"route": f"K{a}-K{b}", "nm": n, "msl": msl, "exposed": gap / (n + 1),
                         "longest_gap_nm": longest, "longest_gap_min": 60 * longest / tas_kt})
    return rows


# ---------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--survey", action="store_true", help="also run the glide survey (table B)")
    ap.add_argument("--routes", action="store_true", help="also run the route exposure table (C)")
    ap.add_argument("--gate", action="store_true", help="exit 1 if any feature-set threshold fails")
    ap.add_argument("--golden-write", action="store_true", help="regenerate the Swift pin")
    ap.add_argument("--golden-check", action="store_true", help="check the port against the pin")
    ap.add_argument("--json", help="also write all tables to this path")
    ap.add_argument("--packs", default=OUT_DIR, help="directory of built .lzpack files (read-only)")
    a = ap.parse_args()

    with open(RULESET) as fh:
        scorer = DeviceScore(json.load(fh))
    if a.golden_write:
        golden_write(scorer)
        return 0
    if a.golden_check:
        golden_check(scorer)
        return 0

    sampler = PackSampler(a.packs)
    report = {"sets": evaluate_sets(scorer, sampler)}
    print(f"## Device verdict at independently mapped ground (default aircraft; green >= {GREEN_FROM}, "
          f"offered >= {OFFER_FROM})\n")
    print(f"   {'ground':34s} {'expect':6s} {'n':>5s} {'green':>6s} {'offered':>8s} {'excluded':>9s}")
    failures = []
    for r in report["sets"]:
        if not r["n"]:
            print(f"   {r['name']:34s} {r['expect']:6s}     0   (no samples inside built packs)")
            continue
        print(f"   {r['name']:34s} {r['expect']:6s} {r['n']:5d} {100 * r['green']:5.0f}% "
              f"{100 * r['offered']:7.0f}% {100 * r['excluded']:8.0f}%")
        if r["expect"] == "bad" and r["offered"] > GATE_BAD_MAX_OFFERED:
            failures.append(f"{r['name']}: offered {100 * r['offered']:.0f}% > {100 * GATE_BAD_MAX_OFFERED:.0f}%")
        if r["expect"] == "good" and r["offered"] < GATE_GOOD_MIN_OFFERED:
            failures.append(f"{r['name']}: offered {100 * r['offered']:.0f}% < {100 * GATE_GOOD_MIN_OFFERED:.0f}%")

    if a.survey:
        report["survey"] = glide_survey(scorer, sampler)
        print("\n## Glide survey (9:1, 1,000 ft reserve, straight-line reach)\n")
        for r in report["survey"]:
            print(f"   {r['agl_ft']:5,d} ft AGL  runway {100 * r['runway']:3.0f}%  offered {100 * r['offered']:3.0f}%"
                  f"  offered-no-runway {100 * r['offered_no_runway']:3.0f}%  nothing {100 * r['nothing']:3.0f}%")
    if a.routes:
        report["routes"] = route_exposure()
        print("\n## Route exposure (direct, still air, 9:1, 1,000 ft reserve)\n")
        for r in report["routes"]:
            print(f"   {r['route']:12s} {r['msl']:6,d} ft  out of glide {100 * r['exposed']:3.0f}%"
                  f"  longest gap {r['longest_gap_nm']:4d} NM = {r['longest_gap_min']:3.0f} min")
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(report, fh, indent=1)

    if failures:
        print("\nGATE FAIL\n   " + "\n   ".join(failures))
        return 1 if a.gate else 0
    print("\nGATE PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
