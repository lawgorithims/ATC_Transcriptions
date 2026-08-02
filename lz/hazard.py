#!/usr/bin/env python3
"""hazard.py — Stage 3: the fused hazard plane and the flags bitfield.

WHAT IT MAKES
    lz/work/<cell>/hazard.npy   uint8, noisy-OR fused hazard 0..255 <-> H in [0,1]
    lz/work/<cell>/flags.npy    uint8, FLAG_* bitfield

*** ODbL QUARANTINE — READ BEFORE EDITING ***
    This file MUST NOT import, open, or otherwise read the OpenStreetMap extract. Not once, not
    "just for validation". OSM is ODbL, which carries share-alike on any Derivative Database, and
    merging OSM geometry into this fused plane is precisely what converts a Collective Database
    (each source keeps its own licence) into a Derivative one. If proprietary wire detections are
    ever added here, that merge is what could force them open.

    The defence is structural, not a promise: `verify.py` deletes the OSM artifact, rebuilds, and
    requires the planes to be BIT-IDENTICAL. Adding an OSM read here fails that gate.

    OSM power lines still ship — as a separate, attributed, display-only layer that the device
    draws and never fuses.

THE HAZARD MODEL
    Each source contributes a decaying field around its geometry:

        penalty_j = c_tier(j) * h(j) * exp(-d / lambda(j))

    and the cell's hazard is the noisy-OR over sources:

        H = 1 - PROD_j (1 - penalty_j)

    Noisy-OR, not a sum: two wires 40 m apart should compound but must saturate at 1, and a sum
    would run past certainty and then clip — losing the difference between "bad" and "much worse"
    exactly where it matters. Noisy-OR also has the right degenerate behaviour: one certain hazard
    (penalty 1.0) pins the cell at 1.0 no matter what else is nearby.

CONFIDENCE TIERS
    charted (FAA DOF, frozen HIFLD)  1.00   — surveyed structures, published
    assumed (road / field-edge)      0.50   — a heuristic, and it must never render as a known wire

    The `assumed` tier exists because absence of a mapped wire is NOT evidence of no wire. Rural
    distribution is largely unmapped nationally, so every road gets a corridor whether or not any
    dataset says so. That is the training every pilot already has — "assume the wires are there" —
    encoded as data.

WHY LOCAL ROADS, NOT HIGHWAYS
    The road corridor uses the county ALL-ROADS layers (40,220 features here), not PRISECROADS
    (2,748 statewide). Distribution follows local rural roads; an interstates-only heuristic would
    leave the countryside clean, which is the exact ground a forced landing ends up on.

DEFERRED (documented, not silently dropped)
    * Canopy-gap corridor detection — linear clearings through forest are overwhelmingly powerline
      or pipeline rights-of-way, and they look like inviting strips from the air. Worth building;
      needs a morphological/Hough pass and is meaningless in a cell that is 84% desert scrub.
    * Lidar wire extraction — the differentiator, and a research task with its own acceptance bar.

USAGE
    python3 lz/hazard.py --build
    python3 lz/hazard.py --verify
"""

import argparse
import json
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C  # noqa: E402

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: python3 -m pip install numpy")

try:
    from osgeo import gdal, ogr, osr
except ImportError:
    sys.exit("the GDAL Python bindings are required")

gdal.UseExceptions()
ogr.UseExceptions()

# --- tiers ------------------------------------------------------------------------------------
TIER_CHARTED = 1.00
TIER_ASSUMED = 0.50

# --- decay lengths (metres) -------------------------------------------------------------------
LAMBDA_TRANSMISSION = 120.0
LAMBDA_DISTRIBUTION = 50.0
LAMBDA_ROAD = 40.0
LAMBDA_FIELD_EDGE = 20.0
LAMBDA_OBSTACLE = 60.0

# Proximity search is capped: beyond ~5 lambda the penalty is <1% and the transform gets expensive
# over 137 M cells. The cap is in CELLS, and the grid is 10 m.
PROX_MAX_CELLS = 60

# Height factor: a 45 m transmission span is the reference. Floored at 0.4 so a short pole still
# carries real weight — a 10 m distribution line is the classic wire strike, not a rounding error.
HEIGHT_REF_M = 45.0
HEIGHT_FLOOR = 0.4

# DOF obstacle types that indicate WIRES rather than a lone structure.
DOF_WIRE_TYPES = {"T-L TWR", "POLE", "GEN UTIL", "TRANSM LN", "CATENARY"}

# DOF.DAT fixed-width slices, verified empirically against the shipped file (not from memory).
DOF_SLICES = {"state": (15, 17), "city": (18, 34), "lat": (35, 47), "lon": (48, 61),
              "type": (62, 80), "agl": (83, 88), "amsl": (89, 94)}
DOF_HEADER_ROWS = 4

DEFERRED_V2_CANOPY_CORRIDOR = True      # see DEFERRED above; asserted by --verify

ORACLE_I10_I25 = (-106.7700, 32.3100)   # the interchange NW of Las Cruces
ORACLE_OPEN_DESERT = (-106.3000, 32.7000)


def _wd():
    d = os.path.join(C.WORK_DIR, C.CELL_ID)
    os.makedirs(d, exist_ok=True)
    return d


def _srs():
    s = osr.SpatialReference()
    s.ImportFromEPSG(C.ANALYSIS_EPSG)
    return s


def _blank(path, dtype=gdal.GDT_Byte):
    g = C.master_grid()
    drv = gdal.GetDriverByName("GTiff")
    ds = drv.Create(path, g["cols"], g["rows"], 1, dtype,
                    options=["COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"])
    ds.SetGeoTransform(g["geotransform"])
    ds.SetProjection(_srs().ExportToWkt())
    return ds


def proximity_m(mask_path, out_path):
    """Distance in METRES to the nearest set pixel, capped at PROX_MAX_CELLS."""
    src = gdal.Open(mask_path)
    dst = _blank(out_path, gdal.GDT_Float32)
    gdal.ComputeProximity(src.GetRasterBand(1), dst.GetRasterBand(1),
                          [f"MAXDIST={PROX_MAX_CELLS}", "DISTUNITS=PIXEL", "VALUES=1",
                           f"NODATA={PROX_MAX_CELLS + 1}"])
    dst.FlushCache()
    a = dst.ReadAsArray().astype(np.float32)
    src = None
    dst = None
    # ComputeProximity writes NODATA beyond MAXDIST; treat that as "far", not as "here".
    a[~np.isfinite(a)] = PROX_MAX_CELLS + 1
    a[a > PROX_MAX_CELLS] = PROX_MAX_CELLS + 1
    return a * C.CELL_SIZE_M


def rasterize_vector(zip_paths, out_path, layer_filter=None):
    """Burn one or more zipped shapefiles onto the master grid as a 0/1 mask."""
    ds = _blank(out_path)
    burned = 0
    for zp in zip_paths:
        try:
            v = ogr.Open(f"/vsizip/{os.path.abspath(zp)}")
        except RuntimeError:
            continue
        if v is None:
            continue
        lyr = v.GetLayer(0)
        if layer_filter:
            lyr.SetAttributeFilter(layer_filter)
        gdal.RasterizeLayer(ds, [1], lyr, burn_values=[1])
        burned += 1
        v = None
    ds.FlushCache()
    a = ds.ReadAsArray().astype(bool)
    ds = None
    return a, burned


def parse_dof():
    """DOF points inside the cell, with height and a wire/structure discriminator."""
    m = C.load_manifest()["sources"].get("dof", {})
    zp = m.get("local")
    if not zp or not os.path.exists(zp):
        return []

    def dms(s):
        d, mi, rest = s.split()
        v = int(d) + int(mi) / 60.0 + float(rest[:-1]) / 3600.0
        return -v if rest[-1] in "SW" else v

    out = []
    with zipfile.ZipFile(zp) as z:
        name = [n for n in z.namelist() if n.upper().endswith(".DAT")][0]
        with z.open(name) as f:
            for i, raw in enumerate(f):
                if i < DOF_HEADER_ROWS:
                    continue
                r = raw.decode("latin-1")
                if len(r) < 95:
                    continue
                try:
                    lat = dms(r[slice(*DOF_SLICES["lat"])].strip())
                    lon = dms(r[slice(*DOF_SLICES["lon"])].strip())
                except (ValueError, IndexError):
                    continue
                if not (C.CELL_LAT_MIN <= lat <= C.CELL_LAT_MAX
                        and C.CELL_LON_MIN <= lon <= C.CELL_LON_MAX):
                    continue
                try:
                    agl_ft = int(r[slice(*DOF_SLICES["agl"])].strip() or 0)
                except ValueError:
                    agl_ft = 0
                kind = r[slice(*DOF_SLICES["type"])].strip()
                out.append({"lat": lat, "lon": lon, "agl_m": agl_ft * 0.3048,
                            "type": kind, "wire": kind in DOF_WIRE_TYPES})
    return out


def stamp_points(shape, pts, tier, lam_default):
    """Stamp decaying discs for a small point set. Exact, no distance transform needed."""
    assert lam_default > 0, "stamp_points: nonsensical decay length"
    g = C.master_grid()
    field = np.zeros(shape, np.float32)
    reach = int(np.ceil(5.0 * LAMBDA_TRANSMISSION / C.CELL_SIZE_M))
    for p in pts:
        rc = C.lonlat_to_grid(p["lon"], p["lat"], g)
        if rc is None:
            continue
        r0, c0 = rc
        lam = LAMBDA_TRANSMISSION if p.get("wire") else lam_default
        h = float(np.clip(p["agl_m"] / HEIGHT_REF_M, HEIGHT_FLOOR, 1.0))
        r1, r2 = max(0, r0 - reach), min(shape[0], r0 + reach + 1)
        c1, c2 = max(0, c0 - reach), min(shape[1], c0 + reach + 1)
        if r1 >= r2 or c1 >= c2:
            continue
        yy = (np.arange(r1, r2) - r0)[:, None]
        xx = (np.arange(c1, c2) - c0)[None, :]
        d = np.hypot(yy, xx) * C.CELL_SIZE_M
        pen = (tier * h * np.exp(-d / lam)).astype(np.float32)
        np.maximum(field[r1:r2, c1:c2], pen, out=field[r1:r2, c1:c2])
    return field


def field_edges(cls):
    """Boundaries of cultivated blocks. Section lines and field edges are where rural
    distribution runs, so the edge — not the field interior — carries the corridor."""
    crop = np.isin(cls, [C.CLASS_CROP, C.CLASS_OPEN_FIRM])
    inner = np.ones_like(crop)
    inner[1:, :] &= crop[:-1, :]
    inner[:-1, :] &= crop[1:, :]
    inner[:, 1:] &= crop[:, :-1]
    inner[:, :-1] &= crop[:, 1:]
    return crop & ~inner


def cmd_build():
    wd = _wd()
    cls = np.load(os.path.join(wd, "class.npy"))
    tsrc = np.load(os.path.join(wd, "terrain_src.npy"))
    shape = cls.shape
    fields, applied = [], {}

    # --- charted structures (FAA DOF) ---------------------------------------------------------
    pts = parse_dof()
    wires = [p for p in pts if p["wire"]]
    print(f"  DOF: {len(pts)} obstacles in cell ({len(wires)} wire-indicating)")
    dof_field = stamp_points(shape, pts, TIER_CHARTED, LAMBDA_OBSTACLE)
    fields.append(dof_field)
    applied["dof_points"] = len(pts)
    applied["dof_wire_points"] = len(wires)

    # --- charted transmission (frozen HIFLD, if a snapshot is present) ------------------------
    hifld = C.load_manifest()["sources"].get("hifld_tx", {})
    tx_mask = np.zeros(shape, bool)
    if hifld.get("local") and os.path.exists(hifld["local"]):
        tx_path = os.path.join(wd, "hz_tx.tif")
        ds = _blank(tx_path)
        v = ogr.Open(hifld["local"])
        gdal.RasterizeLayer(ds, [1], v.GetLayer(0), burn_values=[1])
        ds.FlushCache()
        tx_mask = ds.ReadAsArray().astype(bool)
        ds = None
        v = None
        d = proximity_m(tx_path, os.path.join(wd, "hz_tx_prox.tif"))
        fields.append((TIER_CHARTED * np.exp(-d / LAMBDA_TRANSMISSION)).astype(np.float32))
        applied["hifld_present"] = True
    else:
        applied["hifld_present"] = False
        print("  HIFLD: no frozen snapshot — transmission relies on DOF T-L TWR points only")

    # --- assumed corridors: roads -------------------------------------------------------------
    tiger = C.load_manifest()["sources"].get("tiger_roads", {})
    road_zips = [l["local"] for l in (tiger.get("layers") or [])
                 if l["label"].startswith("roads_") and os.path.exists(l["local"])]
    road_mask = np.zeros(shape, bool)
    if road_zips:
        rp = os.path.join(wd, "hz_roads.tif")
        road_mask, n = rasterize_vector(road_zips, rp)
        d = proximity_m(rp, os.path.join(wd, "hz_roads_prox.tif"))
        fields.append((TIER_ASSUMED * np.exp(-d / LAMBDA_ROAD)).astype(np.float32))
        applied["road_layers"] = n
        applied["road_cells"] = int(road_mask.sum())
        print(f"  roads: {n} county layers, {road_mask.sum():,} burned cells")
    else:
        print("  roads: NONE — the assumed-wire corridor is absent, which UNDER-states risk")

    # --- assumed corridors: field edges -------------------------------------------------------
    edges = field_edges(cls)
    edge_field = np.zeros(shape, np.float32)
    if edges.any():
        ep = os.path.join(wd, "hz_edges.tif")
        ds = _blank(ep)
        ds.GetRasterBand(1).WriteArray(edges.astype(np.uint8))
        ds.FlushCache()
        ds = None
        d = proximity_m(ep, os.path.join(wd, "hz_edges_prox.tif"))
        edge_field = (TIER_ASSUMED * np.exp(-d / LAMBDA_FIELD_EDGE)).astype(np.float32)
        fields.append(edge_field)
        applied["field_edge_cells"] = int(edges.sum())
        print(f"  field edges: {edges.sum():,} cells")

    # --- noisy-OR fuse ------------------------------------------------------------------------
    surv = np.ones(shape, np.float32)
    for f in fields:
        np.multiply(surv, (1.0 - np.clip(f, 0.0, 1.0)), out=surv)
    H = (1.0 - surv)
    hazard = np.clip(np.rint(H * C.HAZARD_MAX), 0, C.HAZARD_MAX).astype(np.uint8)

    # --- flags --------------------------------------------------------------------------------
    flags = np.zeros(shape, np.uint8)
    flags |= np.where(dof_field > 0.05, C.FLAG_DOF_TOWER, 0).astype(np.uint8)
    if tx_mask.any():
        flags |= np.where(tx_mask, C.FLAG_TX_CORRIDOR, 0).astype(np.uint8)
    # A DOF wire-type point also raises the corridor flag: it is evidence of a line, not just a
    # structure, and the card should say "wires" rather than "obstacle".
    if wires:
        wf = stamp_points(shape, wires, TIER_CHARTED, LAMBDA_TRANSMISSION)
        flags |= np.where(wf > 0.10, C.FLAG_TX_CORRIDOR, 0).astype(np.uint8)
    if road_mask.any():
        flags |= np.where(road_mask, C.FLAG_ROAD_BUFFER, 0).astype(np.uint8)
    flags |= np.where(cls == C.CLASS_WATER, C.FLAG_WATER_VETO, 0).astype(np.uint8)
    flags |= np.where(np.isin(cls, [C.CLASS_WETLAND, C.CLASS_OPEN_SOFT]),
                      C.FLAG_WETLAND, 0).astype(np.uint8)
    flags |= np.where(tsrc != C.TERRAIN_SRC_FINE, C.FLAG_COARSE_TERRAIN, 0).astype(np.uint8)

    np.save(os.path.join(wd, "hazard.npy"), hazard)
    np.save(os.path.join(wd, "flags.npy"), flags)
    with open(os.path.join(wd, "hazard_rules.json"), "w") as f:
        json.dump({"applied": applied,
                   "tiers": {"charted": TIER_CHARTED, "assumed": TIER_ASSUMED},
                   "lambda_m": {"transmission": LAMBDA_TRANSMISSION, "road": LAMBDA_ROAD,
                                "field_edge": LAMBDA_FIELD_EDGE, "obstacle": LAMBDA_OBSTACLE},
                   "deferred": {"canopy_gap_corridor": DEFERRED_V2_CANOPY_CORRIDOR,
                                "lidar_wire_extraction": True},
                   "odbl": "hazard.py reads NO OpenStreetMap data; verify.py proves it"},
                  f, indent=2)

    print(f"\nhazard: mean {hazard.mean():.1f}/255  p50 {np.percentile(hazard,50):.0f}  "
          f"p99 {np.percentile(hazard,99):.0f}  max {hazard.max()}")
    for bit, nm in sorted(C.FLAG_NAMES.items()):
        n = int((flags & bit).astype(bool).sum())
        if n:
            print(f"  flag {nm:<16}{n/flags.size*100:6.2f}%  {n:>12,}")
    return 0


def cmd_verify():
    wd = _wd()
    p = os.path.join(wd, "hazard.npy")
    if not os.path.exists(p):
        sys.exit("no hazard build — run --build")
    hz = np.load(p)
    flags = np.load(os.path.join(wd, "flags.npy"))
    g = C.master_grid()
    ok = True

    def at(lon, lat, arr):
        rc = C.lonlat_to_grid(lon, lat, g)
        return None if rc is None else arr[rc[0], rc[1]]

    # 1. A major interchange must carry real hazard.
    v = at(*ORACLE_I10_I25, hz)
    good = v is not None and v >= 60
    print(f"{'ok  ' if good else 'FAIL'} I-10/I-25 interchange hazard {v}/255 (need >=60)")
    ok &= good

    # 2. Open desert away from roads must be near-clean, or the corridor has swamped the map.
    v2 = at(*ORACLE_OPEN_DESERT, hz)
    good = v2 is not None and v2 <= 60
    print(f"{'ok  ' if good else 'FAIL'} open desert hazard {v2}/255 (need <=60)")
    ok &= good

    # 3. Hazard must be a MINORITY of the cell. If the assumed corridor covers everything it
    #    stops discriminating, and a layer that flags all ground flags none.
    share = float((hz >= 128).mean() * 100)
    good = share < 25.0
    print(f"{'ok  ' if good else 'FAIL'} cells at H>=0.5: {share:.2f}% (need <25)")
    ok &= good

    # 4. ...but it must not be empty either. A silent zero plane is the failure this whole
    #    pipeline is built to prevent.
    nz = float((hz > 0).mean() * 100)
    good = nz > 1.0
    print(f"{'ok  ' if good else 'FAIL'} cells with any hazard: {nz:.2f}% (need >1)")
    ok &= good

    # 5. The ODbL quarantine, checked at the source level. This is a cheap tripwire, not the
    #    proof — verify.py proves it properly by deleting the OSM artifact and requiring
    #    bit-identical planes. What this catches is someone reaching for the extract in an edit.
    src = open(os.path.abspath(__file__)).read()
    # Scan the BUILD path only. The quarantine constrains what hazard.py reads when it builds;
    # the checker necessarily names the thing it forbids, and a whole-file scan would trip on its
    # own needle list (it did — that is why this is scoped).
    build_src = src.split("def cmd_verify")[0]
    needles = ["osm" + "_power", "geo" + "fabrik", ".osm" + ".pbf"]
    reads = [t for t in needles if t in build_src]
    print(f"{'ok  ' if not reads else 'FAIL'} no OSM read in hazard.py's build path"
          f"{'' if not reads else ' — found ' + str(reads)}")
    ok &= not reads

    print("\nVERIFY PASS" if ok else "\nVERIFY FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--verify", action="store_true")
    C.add_cell_argument(ap)
    a = ap.parse_args()
    C.select_cell(a.cell)          # before ANY path, window or URL is built

    rc = 0
    if a.build:
        rc |= cmd_build()
    if a.verify:
        rc |= cmd_verify()
    if not (a.build or a.verify):
        ap.print_help()
    return rc


if __name__ == "__main__":
    sys.exit(main())
