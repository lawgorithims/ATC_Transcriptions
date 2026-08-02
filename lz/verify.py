#!/usr/bin/env python3
"""verify.py — the gate. Checks the SHIPPED .lzpack, not the intermediate arrays.

WHY IT READS THE PACK
    Every earlier stage verifies its own output, which proves the maths. This proves the ARTIFACT:
    the thing the app will actually mount, after quantisation, reprojection, tiling, pyramid
    reduction and compression have each had a chance to lose something. A stage passing and the
    pack being wrong is exactly the gap that ships.

WHAT IT ASSERTS
    Ground truth (coordinates come from the app's own apt.sqlite and from NWI geometry — never
    hand-typed):
      * KLRU's three runways read flat, smooth and low-hazard.
      * Mesa Verde Ranch Strip — a real ranch strip in the cell — is not vetoed.
      * The Rio Grande channel is never landable, AT EVERY ZOOM (an overview that averages the
        river away is the failure mode the conservative aggregation exists to prevent).
      * The Organ Mountains crest carries real slope.
      * The I-10/I-25 interchange carries real hazard; open desert does not.

    Structure:
      * every source in the manifest is present and the pack's metadata agrees with it;
      * the z13 tile count matches the cell footprint;
      * random tiles round-trip decode;
      * PYRAMID MONOTONICITY — a parent's hazard is >= its worst child and its confidence <= its
        best child. If a parent were ever gentler than a child, zooming out would invent safe
        ground;
      * ODbL INDEPENDENCE — the OSM artifact is moved aside, hazard is rebuilt, and the plane must
        come back BIT-IDENTICAL. This is the real proof behind the quarantine, not a code comment;
      * the pack is under the size ceiling.

USAGE
    python3 lz/verify.py                # full gate
    python3 lz/verify.py --skip-odbl    # skip the rebuild (slow) when iterating
"""

import argparse
import hashlib
import json
import math
import os
import shutil
import sqlite3
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C  # noqa: E402

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required")

APT_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "ios", "ATCTranscribe", "Resources", "nav", "apt.sqlite")

# Sampled from NWI riverine polygons via PointOnSurface (a centroid falls outside a sinuous river).
RIO_GRANDE = [(-106.6657, 32.1266), (-106.7198, 32.1716), (-106.6387, 32.2757)]
ORGAN_CREST = (-106.5610, 32.3600)
I10_I25 = (-106.7700, 32.3100)
OPEN_DESERT = (-106.3000, 32.7000)
RANCH_STRIP = ("7NM1", -106.04527777, 32.93527777)

LANDABLE = (C.CLASS_OPEN_FIRM, C.CLASS_CROP)
RUNWAY_MAX_SLOPE_DEG = 4.0
RUNWAY_MAX_HAZARD = 200
ORGAN_MIN_SLOPE_DEG = 12.0
INTERCHANGE_MIN_HAZARD = 60
DESERT_MAX_HAZARD = 60
SAMPLE_TILES = 50


class Pack:
    def __init__(self, path):
        self.path = path
        self.db = sqlite3.connect(path)
        self.meta = {k: v for k, v in self.db.execute("select name,value from metadata")}

    def tile(self, z, x, y):
        row = self.db.execute(
            "select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
            (z, x, C.xyz_to_tms_row(y, z))).fetchone()
        return None if row is None else C.unpack_blob(row[0])

    def counts(self):
        return {z: n for z, n in self.db.execute(
            "select zoom_level, count(*) from tiles group by zoom_level order by zoom_level")}

    def keys(self, z):
        return [(x, C.xyz_to_tms_row(r, z)) for x, r in self.db.execute(
            "select tile_column, tile_row from tiles where zoom_level=?", (z,))]

    def sample(self, lon, lat, z=C.NATIVE_ZOOM):
        """Decode the tile containing a point and return its six plane values + terrain_source."""
        n = 1 << z
        xf = (lon + 180.0) / 360.0 * n
        yf = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
        tx, ty = int(xf), int(yf)
        got = self.tile(z, tx, ty)
        if got is None:
            return None
        planes, tsrc = got
        px = min(C.TILE_SIDE - 1, int((xf - tx) * C.TILE_SIDE))
        py = min(C.TILE_SIDE - 1, int((yf - ty) * C.TILE_SIDE))
        return {"class": int(planes[C.PLANE_CLASS][py, px]),
                "conf": int(planes[C.PLANE_CONF][py, px]),
                "slope": int(planes[C.PLANE_SLOPE][py, px]),
                "rough": int(planes[C.PLANE_ROUGH][py, px]),
                "hazard": int(planes[C.PLANE_HAZARD][py, px]),
                "flags": int(planes[C.PLANE_FLAGS][py, px]),
                "terrain_source": tsrc}


def runway_points():
    """KLRU runway ends and interpolated centreline points, from the app's own airport DB."""
    if not os.path.exists(APT_DB):
        return []
    db = sqlite3.connect(APT_DB)
    ends = {}
    for ident, desig, end_id, lat, lon in db.execute(
            "select ident, designator, end_id, lat, lon from runway_end where ident='LRU'"):
        ends.setdefault(desig, []).append((lon, lat))
    pts = []
    for desig, e in ends.items():
        if len(e) != 2:
            continue
        (x0, y0), (x1, y1) = e
        for t in (0.15, 0.5, 0.85):     # skip the very thresholds; sample the usable surface
            pts.append((desig, x0 + t * (x1 - x0), y0 + t * (y1 - y0)))
    return pts


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    return ok


def gate_ground_truth(pack):
    ok = True
    slope_deg = lambda v: None if v == C.SLOPE_NODATA else v * C.SLOPE_STEP_DEG  # noqa: E731

    # KLRU runways: flat, smooth, low hazard. Not "landable class" — a paved runway maps as
    # developed in land cover, and asserting otherwise would be testing the wrong property.
    rw = runway_points()
    if not rw:
        ok = check("KLRU runway geometry available", False, "apt.sqlite not readable")
    else:
        bad = []
        for desig, lon, lat in rw:
            s = pack.sample(lon, lat)
            if s is None:
                bad.append(f"{desig} no tile")
                continue
            sd = slope_deg(s["slope"])
            if sd is None or sd > RUNWAY_MAX_SLOPE_DEG or s["hazard"] > RUNWAY_MAX_HAZARD:
                bad.append(f"{desig} slope={sd} hz={s['hazard']}")
        ok &= check(f"KLRU {len(rw)} runway samples flat & low-hazard", not bad,
                    "; ".join(bad[:3]) if bad else
                    f"<= {RUNWAY_MAX_SLOPE_DEG} deg, hz <= {RUNWAY_MAX_HAZARD}")

    # A real ranch strip in the cell must not be vetoed outright.
    ident, lon, lat = RANCH_STRIP
    s = pack.sample(lon, lat)
    ok &= check(f"{ident} ranch strip not vetoed", s is not None and s["class"] != C.CLASS_WATER,
                f"class={C.CLASS_NAMES.get(s['class']) if s else 'no tile'}")

    # The river must stay non-landable at EVERY zoom. An overview that averages it away is the
    # precise failure conservative aggregation exists to prevent.
    bad = []
    for z in range(C.MIN_ZOOM, C.NATIVE_ZOOM + 1):
        for lon, lat in RIO_GRANDE:
            s = pack.sample(lon, lat, z)
            if s and s["class"] in LANDABLE:
                bad.append(f"z{z} {C.CLASS_NAMES[s['class']]}")
    ok &= check("Rio Grande never landable, all zooms", not bad, "; ".join(bad[:4]))

    s = pack.sample(*ORGAN_CREST)
    sd = slope_deg(s["slope"]) if s else None
    ok &= check("Organ crest carries slope", sd is not None and sd >= ORGAN_MIN_SLOPE_DEG,
                f"{sd} deg (need >= {ORGAN_MIN_SLOPE_DEG})")

    s = pack.sample(*I10_I25)
    ok &= check("I-10/I-25 interchange hazard", s is not None and s["hazard"] >= INTERCHANGE_MIN_HAZARD,
                f"{s['hazard'] if s else '-'}/255")

    s = pack.sample(*OPEN_DESERT)
    ok &= check("open desert stays clean", s is not None and s["hazard"] <= DESERT_MAX_HAZARD,
                f"{s['hazard'] if s else '-'}/255")
    return ok


def gate_structure(pack):
    ok = True
    counts = pack.counts()
    expect13 = len(C.cell_tiles(C.NATIVE_ZOOM))
    ok &= check(f"z{C.NATIVE_ZOOM} tile count", counts.get(C.NATIVE_ZOOM, 0) <= expect13
                and counts.get(C.NATIVE_ZOOM, 0) > expect13 * 0.5,
                f"{counts.get(C.NATIVE_ZOOM,0)} of {expect13} possible")
    ok &= check("pyramid spans the declared zooms",
                set(counts) == set(range(C.MIN_ZOOM, C.NATIVE_ZOOM + 1)),
                ", ".join(f"z{z}={n}" for z, n in sorted(counts.items())))

    ok &= check("lz_schema matches the decoder",
                int(pack.meta.get("lz_schema", -1)) == C.LZ_SCHEMA)
    ok &= check("plane order recorded in metadata",
                pack.meta.get("lz_planes") == ",".join(C.PLANE_NAMES),
                pack.meta.get("lz_planes", ""))

    # Every manifest source must appear in the pack's vintage record — provenance has to survive
    # into the artifact, or the card cannot say how old the data is.
    man = C.load_manifest()["sources"]
    try:
        vin = json.loads(pack.meta.get("lz_vintages", "{}"))
    except json.JSONDecodeError:
        vin = {}
    missing = sorted(set(man) - set(vin))
    ok &= check("every source's provenance is in the pack", not missing, str(missing))

    # Random round-trip decode.
    keys = pack.keys(C.NATIVE_ZOOM)
    rng = np.random.default_rng(11)
    picks = rng.choice(len(keys), size=min(SAMPLE_TILES, len(keys)), replace=False)
    bad = 0
    for i in picks:
        x, y = keys[int(i)]
        got = pack.tile(C.NATIVE_ZOOM, x, y)
        if got is None or len(got[0]) != C.PLANE_COUNT:
            bad += 1
            continue
        if any(p.shape != (C.TILE_SIDE, C.TILE_SIDE) for p in got[0]):
            bad += 1
    ok &= check(f"{len(picks)} random tiles round-trip decode", bad == 0, f"{bad} bad")

    size = os.path.getsize(pack.path)
    ok &= check("pack under the size ceiling", size <= 200 << 20, f"{size/1e6:.1f} MB")
    return ok


def gate_pyramid(pack):
    """A parent may never be gentler than its worst child."""
    rng = np.random.default_rng(5)
    bad = []
    for z in range(C.MIN_ZOOM + 1, C.NATIVE_ZOOM + 1):
        keys = pack.keys(z)
        if not keys:
            continue
        picks = rng.choice(len(keys), size=min(20, len(keys)), replace=False)
        for i in picks:
            x, y = keys[int(i)]
            child = pack.tile(z, x, y)
            parent = pack.tile(z - 1, x // 2, y // 2)
            if child is None or parent is None:
                continue
            ch, pa = child[0], parent[0]
            if pa[C.PLANE_HAZARD].max() < ch[C.PLANE_HAZARD].max():
                bad.append(f"z{z} ({x},{y}) hazard {pa[C.PLANE_HAZARD].max()}"
                           f" < child {ch[C.PLANE_HAZARD].max()}")
            real_c = ch[C.PLANE_CONF][ch[C.PLANE_CONF] != C.CONF_UNKNOWN]
            real_p = pa[C.PLANE_CONF][pa[C.PLANE_CONF] != C.CONF_UNKNOWN]
            if real_c.size and real_p.size and real_p.min() > real_c.min():
                bad.append(f"z{z} ({x},{y}) conf {real_p.min()} > child {real_c.min()}")
    return check("pyramid monotonic (parent never gentler than child)", not bad,
                 "; ".join(bad[:3]))


def gate_odbl():
    """Move the OSM extract aside, rebuild the hazard plane, require bit-identical output.

    This is the proof behind the quarantine. A comment saying hazard.py does not read OSM is worth
    nothing; a rebuild that produces the same bytes with the file gone is worth everything, because
    it is what keeps the fused plane a Collective and not a Derivative Database."""
    wd = os.path.join(C.WORK_DIR, C.CELL_ID)
    hz = os.path.join(wd, "hazard.npy")
    fl = os.path.join(wd, "flags.npy")
    if not os.path.exists(hz):
        return check("ODbL independence", False, "no hazard build to compare")
    before = (hashlib.sha256(open(hz, "rb").read()).hexdigest(),
              hashlib.sha256(open(fl, "rb").read()).hexdigest())

    man = C.load_manifest()["sources"].get("osm_power", {})
    osm = man.get("local")
    moved = None
    if osm and os.path.exists(osm):
        moved = osm + ".quarantined"
        shutil.move(osm, moved)
    try:
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "hazard.py"),
                            "--build"], capture_output=True, text=True, timeout=3600)
        if r.returncode != 0:
            return check("ODbL independence", False, "rebuild failed")
        after = (hashlib.sha256(open(hz, "rb").read()).hexdigest(),
                 hashlib.sha256(open(fl, "rb").read()).hexdigest())
    finally:
        if moved:
            shutil.move(moved, osm)
    return check("ODbL independence: planes identical with OSM removed", before == after,
                 "hazard+flags sha256 unchanged" if before == after else "PLANES CHANGED")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", default=os.path.join(C.OUT_DIR, f"{C.CELL_ID}.lzpack"))
    ap.add_argument("--skip-odbl", action="store_true", help="skip the (slow) rebuild proof")
    a = ap.parse_args()
    if not os.path.exists(a.pack):
        sys.exit(f"no pack at {a.pack} — run: python3 lz/package.py --build")
    pack = Pack(a.pack)
    print(f"verifying {os.path.basename(a.pack)} "
          f"({os.path.getsize(a.pack)/1e6:.1f} MB, built {pack.meta.get('built_at')})\n")

    print("-- ground truth --")
    ok = gate_ground_truth(pack)
    print("\n-- structure --")
    ok &= gate_structure(pack)
    print("\n-- pyramid --")
    ok &= gate_pyramid(pack)
    print("\n-- licence --")
    if a.skip_odbl:
        print("skip ODbL independence rebuild (--skip-odbl)")
    else:
        ok &= gate_odbl()

    print("\nGATE PASS" if ok else "\nGATE FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
