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
import time
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

# GROUND TRUTH IS PER CELL, and there is no way around that: "the Rio Grande must never read as
# landable" is a fact about one river in one degree square. The structural gates below (round-trip,
# pyramid monotonicity, ODbL independence, size) are cell-agnostic and run everywhere.
#
# A cell with no entry here is NOT silently passed. It reports NO GROUND TRUTH and the final verdict
# is qualified, because "GATE PASS" on a cell where nothing was checked against reality would make
# the word meaningless for exactly the cells that have never been looked at.
GROUND_TRUTH = {
    "n33w107": {
        "airport": "KLRU",
        # Sampled from NWI riverine polygons via PointOnSurface (a centroid falls outside a
        # sinuous river).
        "never_landable": [("Rio Grande", -106.6657, 32.1266),
                           ("Rio Grande", -106.7198, 32.1716),
                           ("Rio Grande", -106.6387, 32.2757)],
        "steep": [("Organ crest", -106.5610, 32.3600)],
        "high_hazard": [("I-10/I-25 interchange", -106.7700, 32.3100)],
        "low_hazard": [("open desert", -106.3000, 32.7000)],
        "not_vetoed": [("7NM1 ranch strip", -106.04527777, 32.93527777)],
    },
}


def ground_truth():
    """Registered truth for the SELECTED cell, or None."""
    return GROUND_TRUTH.get(C.CELL_ID)

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
    """Check the pack against things known to be true on the ground in THIS cell.

    Returns (ok, checked). `checked` is False when no truth is registered for the selected cell —
    the caller qualifies the verdict rather than reporting a pass nobody earned."""
    truth = ground_truth()
    if truth is None:
        print(f"   -- NO GROUND TRUTH registered for {C.CELL_ID}. Structural gates still apply, but "
              f"nothing here was checked against reality.")
        print(f"      Add an entry to GROUND_TRUTH in {os.path.basename(__file__)} once a landmark "
              f"in this cell is known (a river, a ridge, an interchange, a strip).")
        return True, False

    ok = True
    slope_deg = lambda v: None if v == C.SLOPE_NODATA else v * C.SLOPE_STEP_DEG  # noqa: E731

    # Runways: flat, smooth, low hazard. NOT "landable class" — a paved runway maps as developed in
    # land cover, and asserting otherwise would be testing the wrong property.
    apt = truth.get("airport")
    rw = runway_points() if apt else []
    if apt and not rw:
        ok = check(f"{apt} runway geometry available", False, "apt.sqlite not readable")
    elif rw:
        bad = []
        for desig, lon, lat in rw:
            smp = pack.sample(lon, lat)
            if smp is None:
                bad.append(f"{desig} no tile")
                continue
            sd = slope_deg(smp["slope"])
            if sd is None or sd > RUNWAY_MAX_SLOPE_DEG or smp["hazard"] > RUNWAY_MAX_HAZARD:
                bad.append(f"{desig} slope={sd} hz={smp['hazard']}")
        ok &= check(f"{apt} {len(rw)} runway samples flat & low-hazard", not bad,
                    "; ".join(bad[:3]) if bad else
                    f"<= {RUNWAY_MAX_SLOPE_DEG} deg, hz <= {RUNWAY_MAX_HAZARD}")

    for label, lon, lat in truth.get("not_vetoed", []):
        smp = pack.sample(lon, lat)
        ok &= check(f"{label} not vetoed",
                    smp is not None and smp["class"] != C.CLASS_WATER,
                    f"class={C.CLASS_NAMES.get(smp['class']) if smp else 'no tile'}")

    # Water must stay non-landable at EVERY zoom. An overview that averages a river away is the
    # precise failure conservative aggregation exists to prevent.
    bad = []
    for z in range(C.MIN_ZOOM, C.NATIVE_ZOOM + 1):
        for label, lon, lat in truth.get("never_landable", []):
            smp = pack.sample(lon, lat, z)
            if smp and smp["class"] in LANDABLE:
                bad.append(f"{label} z{z} {C.CLASS_NAMES[smp['class']]}")
    if truth.get("never_landable"):
        ok &= check("water never landable, all zooms", not bad, "; ".join(bad[:4]))

    for label, lon, lat in truth.get("steep", []):
        smp = pack.sample(lon, lat)
        sd = slope_deg(smp["slope"]) if smp else None
        ok &= check(f"{label} carries slope", sd is not None and sd >= ORGAN_MIN_SLOPE_DEG,
                    f"{sd} deg (need >= {ORGAN_MIN_SLOPE_DEG})")

    for label, lon, lat in truth.get("high_hazard", []):
        smp = pack.sample(lon, lat)
        ok &= check(f"{label} hazard", smp is not None and smp["hazard"] >= INTERCHANGE_MIN_HAZARD,
                    f"{smp['hazard'] if smp else '-'}/255")

    for label, lon, lat in truth.get("low_hazard", []):
        smp = pack.sample(lon, lat)
        ok &= check(f"{label} stays clean", smp is not None and smp["hazard"] <= DESERT_MAX_HAZARD,
                    f"{smp['hazard'] if smp else '-'}/255")
    return ok, True


# ---------------------------------------------------------------------------------------------
# THE RECEIPT
# ---------------------------------------------------------------------------------------------
# ⚠️ A GATE NOTHING CONSULTS IS NOT A GATE. package.py writes the pack, verify.py judges it, and
# publish.py used to upload whatever was in lz/out/ without ever asking how the judging went. When
# a stage fails, build_cell.sh exits — but the PACK IT ALREADY WROTE STAYS ON DISK, so a rejected
# cell sits there looking exactly like an accepted one. n33w119 and n34w119 failed their gate and
# were one `publish.py --publish` away from every device.
#
# So a pass now leaves a receipt keyed to the pack's exact bytes, and publish.py refuses to upload
# anything new without one. Keyed by sha256 rather than by cell name because a rebuilt pack is a
# different pack: a stale receipt must not vouch for bytes it never saw.

def receipt_path(pack_path):
    return pack_path + ".verified.json"


def pack_sha256(pack_path):
    h = hashlib.sha256()
    with open(pack_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):         # bounded by file size
            h.update(chunk)
    return h.hexdigest()


def write_receipt(pack_path, skipped_odbl, truth_checked):
    rec = {"cell": C.CELL_ID, "sha256": pack_sha256(pack_path),
           "bytes": os.path.getsize(pack_path),
           "verified_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "odbl_gate": "skipped" if skipped_odbl else "ran",
           "ground_truth": "checked" if truth_checked else "none registered"}
    with open(receipt_path(pack_path), "w") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
    print(f"\nreceipt written: {os.path.basename(receipt_path(pack_path))}")


def clear_receipt(pack_path):
    """A failing pack must not keep a receipt from an earlier, luckier run."""
    try:
        os.remove(receipt_path(pack_path))
        print("previous receipt REVOKED — this pack no longer vouches for itself")
    except FileNotFoundError:
        pass


def gate_structure(pack):
    ok = True
    counts = pack.counts()
    expect13 = len(C.cell_tiles(C.NATIVE_ZOOM))
    got13 = counts.get(C.NATIVE_ZOOM, 0)
    # ⚠️ MEASURE THE TILE COUNT AGAINST THE GROUND THAT EXISTS, NOT AGAINST THE WHOLE CELL.
    #
    # This used to demand more than HALF the cell's 644 z13 tiles, which is right inland and wrong
    # wherever the United States has an edge. 3DEP stops at the coast and at the border, so a
    # coastal cell legitimately packs fewer tiles: n34w119 is most of the Santa Barbara Channel and
    # produced 235, a correct pack that the gate rejected. It would have taken Los Angeles out of
    # the build, and every remaining coastal cell with it — the second time the same flat 50%
    # assumption has mistaken geography for a broken build.
    #
    # ⚠️ AND THE NEW RULE IS STRICTER WHERE IT MATTERS, NOT LOOSER. The failure this gate exists for
    # is n35w108: a failed DEM read produced an 11 MB pack claiming a whole degree of New Mexico had
    # nowhere to land. That cell's DEM coverage was ~100%, so scaling by coverage demands ~483 tiles
    # of it rather than the old 322 — it fails harder than before. What changes is only that a cell
    # which is half ocean is no longer required to invent tiles over water.
    cov = None
    try:
        dem = C.load_manifest()["sources"].get("dem_3dep", {})
        cov = float(dem["coverage_pct"]) / 100.0
    except (KeyError, TypeError, ValueError, FileNotFoundError):
        cov = None
    if cov is None:
        # No manifest to compare against (a re-verify after cleanup). Fall back to the old absolute
        # rule and SAY SO, rather than passing something that was never actually checked.
        floor, basis = expect13 * 0.5, "no manifest — absolute floor, coverage unverified"
    else:
        floor = expect13 * cov * 0.75
        basis = f"{100 * cov:.1f}% DEM coverage, so at least {floor:.0f}"
    ok &= check(f"z{C.NATIVE_ZOOM} tile count", got13 <= expect13 and got13 > floor,
                f"{got13} of {expect13} possible ({basis})")
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

    # ⚠️ A PACK THAT MEASURED NOTHING PASSES EVERY CHECK ABOVE. Right tile count, right schema,
    # right plane order, clean round-trip, comfortably under the ceiling — and every fact byte the
    # same "unknown". n35w108 shipped exactly that: a failed DEM stream became an all-nodata slope
    # plane, no cell could pass the extent scan, and the pack asserted that a whole 1-degree cell of
    # New Mexico has nowhere with room to land. It gated green at 11 MB beside 55 MB neighbours.
    #
    # Structural validity is not the same as having measured anything, and only the second one is
    # worth shipping. A cell with genuinely zero open ground anywhere does not occur at this scale.
    scanned, measured, open_cells = 0, 0, 0
    for i in picks:                                                  # bounded: the same sample
        x, y = keys[int(i)]
        got = pack.tile(C.NATIVE_ZOOM, x, y)
        if got is None:
            continue
        planes = got[0]
        scanned += planes[C.PLANE_SLOPE].size
        measured += int((planes[C.PLANE_SLOPE] != C.SLOPE_NODATA).sum())
        if C.PLANE_EXTENT < len(planes):
            open_cells += int((planes[C.PLANE_EXTENT] > 0).sum())
    ok &= check("the pack actually measured slope", scanned > 0 and measured > scanned // 10,
                f"{100.0 * measured / max(1, scanned):.1f}% of sampled cells carry a slope")
    ok &= check("some ground in the cell has room to land", open_cells > 0,
                f"{open_cells} sampled cells with any open run")

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
        # ⚠️ `--cell` IS LOAD-BEARING. Without it this rebuilt the DEFAULT cell while comparing
        # hashes against the cell under test — so the file being checked was never touched, the
        # before/after sha256 matched trivially, and the gate reported PASS having proved nothing.
        # Every non-default cell "passed" the licence proof vacuously from the moment the pipeline
        # was parameterised by cell.
        #
        # It surfaced only because clearing the default cell's scratch made this subprocess fail,
        # which turned a silent vacuous pass into an honest failure.
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "hazard.py"),
                            "--cell", C.CELL_ID, "--build"],
                           capture_output=True, text=True, timeout=3600)
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
    # default resolved AFTER select_cell — at definition time C.CELL_ID is still the
    # default cell, so a literal default here would verify n33w107's pack for every --cell.
    ap.add_argument("--pack", default=None)
    ap.add_argument("--skip-odbl", action="store_true", help="skip the (slow) rebuild proof")
    C.add_cell_argument(ap)
    a = ap.parse_args()
    C.select_cell(a.cell)          # before ANY path, window or URL is built

    pack_path = a.pack or os.path.join(C.OUT_DIR, f"{C.CELL_ID}.lzpack")
    if not os.path.exists(pack_path):
        sys.exit(f"no pack at {pack_path} — run: python3 lz/package.py --build --cell {C.CELL_ID}")
    pack = Pack(pack_path)
    print(f"verifying {os.path.basename(pack_path)} "
          f"({os.path.getsize(pack_path)/1e6:.1f} MB, built {pack.meta.get('built_at')})\n")

    print("-- ground truth --")
    ok, truth_checked = gate_ground_truth(pack)
    print("\n-- structure --")
    ok &= gate_structure(pack)
    print("\n-- pyramid --")
    ok &= gate_pyramid(pack)
    print("\n-- licence --")
    if a.skip_odbl:
        print("skip ODbL independence rebuild (--skip-odbl)")
    else:
        ok &= gate_odbl()

    if ok:
        write_receipt(pack_path, skipped_odbl=a.skip_odbl, truth_checked=truth_checked)
    else:
        clear_receipt(pack_path)
    if not ok:
        print("\nGATE FAIL")
    elif truth_checked:
        print("\nGATE PASS")
    else:
        print(f"\nGATE PASS (STRUCTURE ONLY — no ground truth registered for {C.CELL_ID})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
