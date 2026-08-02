#!/usr/bin/env python3
"""surface.py — Stage 2: fuse land cover, wetlands and canopy into a surface class + confidence.

WHAT IT MAKES
    lz/work/<cell>/class.npy   uint8, one CLASS_* per 10 m cell
    lz/work/<cell>/conf.npy    uint8, 0..100 percent (255 = unknown)
    lz/work/<cell>/canopy.npy  float32 canopy height in metres (kept for the hazard stage)

WHY A DECISION LIST AND NOT A BAYESIAN FUSION
    The rule chain below is priority-ordered and first-match-wins. That is a deliberate choice
    over anything probabilistic:
      * it is bit-reproducible — the same inputs give the same byte, forever, which is what makes
        a post-incident "why did it say that" answerable;
      * it is explainable — every cell can name the rule that classified it, which is the same
        invariant the device honours when a veto names itself on the card;
      * it has no hidden priors. A probabilistic blend would let two mediocre sources agree their
        way into a confident answer, and confidence is exactly what must not be manufactured.

CONFIDENCE ONLY EVER GOES DOWN
    conf = min(confidence of the sources the matched rule actually used) * age decay. Fusing more
    sources can hold or lower it, never raise it. Two sources agreeing is not evidence; it is two
    guesses. The min() enforces that structurally rather than by discipline.

WHAT THE CANOPY LAYER IS AND IS NOT
    Meta/WRI v2's source imagery is 2016 — about ten years stale at time of writing. Trees grow
    ~0.3-0.5 m/yr, so the raster is treated as a MINIMUM height, never as truth: it can promote a
    cell to forest/brush but can never demote one that land cover already calls forest. Erring
    toward "taller than mapped" is the safe direction, because obstacle height is what displaces
    a landing threshold.

DATUM NOTE (easy to get wrong)
    Annual NLCD ships as `+proj=aea +lat_0=23 +lon_0=-96 +lat_1=29.5 +lat_2=45.5 +datum=WGS84`.
    Those are the EPSG:5070 parameters — but 5070 is NAD83/GRS80, not WGS84. The CRSs look
    identical in a PROJ string and differ by ~1-2 m on the ground. Warp explicitly; do not assume
    an identity transform because the parameters match.

    Land cover is resampled with NEAREST and never anything else: these are class CODES. Bilinear
    on a class raster invents category 47 halfway between 41 and 52.

DEFERRED (documented rather than silently dropped)
    * USDA CDL crop type — would refine `crop` into a seasonal model (standing corn vs harvested
      wheat). NLCD's cultivated-crops class carries v1; the seasonal engine is a later feature.
    * Annual NLCD Land Cover CONFIDENCE — a real per-pixel confidence plane exists, but it is
      ~7.9 GB per year against 1.4 GB for land cover itself. v1 uses class-based base confidence
      with age decay. Wiring it in later changes only CONF_BASE below.
    * NHDPlus HR — NLCD's open-water class resolves the Rio Grande at 30 m, which is what the
      water veto needs. NHD would add ephemeral channels and canal networks.

USAGE
    python3 lz/surface.py --build
    python3 lz/surface.py --verify        # Rio Grande water, valley cropland, class-share sanity
"""

import argparse
import json
import os
import sys

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
gdal.SetConfigOption("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
gdal.SetConfigOption("GDAL_HTTP_TIMEOUT", "120")
gdal.SetConfigOption("VSI_CACHE", "TRUE")
gdal.SetConfigOption("VSI_CACHE_SIZE", str(64 << 20))

# --- NLCD Anderson Level II codes -> our classes -----------------------------------------------
NLCD_TO_CLASS = {
    11: C.CLASS_WATER,            # open water
    12: C.CLASS_SNOW_ICE,
    21: C.CLASS_DEVELOPED_OPEN,   # developed, open space — parks, verges, golf
    22: C.CLASS_DEVELOPED_DENSE,  # low intensity
    23: C.CLASS_DEVELOPED_DENSE,  # medium
    24: C.CLASS_DEVELOPED_DENSE,  # high
    31: C.CLASS_BARREN_ROUGH,     # barren land — roughness decides how rough
    41: C.CLASS_FOREST, 42: C.CLASS_FOREST, 43: C.CLASS_FOREST,
    51: C.CLASS_BRUSH, 52: C.CLASS_BRUSH,
    71: C.CLASS_OPEN_FIRM, 72: C.CLASS_OPEN_FIRM,   # grassland / sedge
    73: C.CLASS_BARREN_ROUGH, 74: C.CLASS_BARREN_ROUGH,   # lichen / moss
    81: C.CLASS_OPEN_FIRM,        # hay/pasture — the classic good field
    82: C.CLASS_CROP,             # cultivated crops
    90: C.CLASS_WETLAND, 95: C.CLASS_WETLAND,
}

# Base confidence per source, before age decay. Deliberately unheroic numbers: 30 m land cover
# upsampled to 10 m cannot be better than "probably".
CONF_BASE = {"nlcd": 80, "nwi": 85, "canopy": 70, "default": 40}
TAU_YEARS = {"nlcd": 4.0, "nwi": 20.0, "canopy": 8.0}
BUILD_YEAR = 2026

CANOPY_FOREST_M = 2.0      # above this a cell is forest regardless of land cover
CANOPY_BRUSH_M = 0.5       # 0.5-2 m is brush
CANOPY_MAX_PLAUSIBLE_M = 80.0   # guard: the CHM has occasional spikes over buildings
# Cropland is MANAGED vegetation, so a canopy reading over it is not evidence of brush or forest —
# it is evidence that something was growing on the day the imagery was taken. Cotton is ~1 m and
# corn reaches 2.5-3 m, so a naive height rule reclassifies every field in an irrigated valley as
# brush or forest and deletes the best landing surfaces in the cell. Canopy may therefore override
# `crop` only at unambiguous TREE height, which no annual crop reaches but a pecan orchard does —
# and orchards are a real obstacle worth promoting.
CANOPY_ORCHARD_M = 4.0
# Canopy has NO nodata, deliberately. The source COGs are unsigned BYTE metres with no nodata set,
# and 0 m is a perfectly real canopy height over bare desert. Setting any sentinel here backfires
# twice over:
#   * dst_nodata=0 makes GDAL shift every genuine 0 to 1 ("Value 0 ... changed to 1 to avoid being
#     treated as NoData"), pushing the whole desert over the 0.5 m brush threshold;
#   * dst_nodata=-9999 looks safer but the output inherits the source's Byte type, so -9999 is
#     clamped back to 0 and reproduces the identical bug.
# Both turned the Chihuahuan desert into scrub-everywhere (96.5% of cells reading exactly 1.00 m).
CANOPY_NODATA = None

# NWI ATTRIBUTE codes: first letter is the SYSTEM (R=riverine, L=lacustrine, P=palustrine,
# E=estuarine, M=marine); for riverine the second character is the SUBSYSTEM, and 4 = intermittent.
#
# That distinction matters here. The Rio Grande below Caballo Dam is a regulated channel that is
# dry for much of the year, and NWI maps it accordingly: the largest features in this cell are
# `R4SBCx` / `R4SB3J` — Riverine, Intermittent, Streambed. Calling that "open water" would paint a
# blue river across dry sand. But it is not landable either: a sandy arroyo is soft, banked and
# scoured. So intermittent riverine becomes OPEN_SOFT (poor, honest) while perennial water and
# lakes become WATER (veto).
NWI_WATER_PREFIX = ("L", "M", "E")          # always open water
NWI_RIVERINE = "R"
NWI_INTERMITTENT_SUBSYSTEM = "4"

# Ground truth taken from the NWI riverine polygons themselves (largest by acreage inside the
# cell), not from a guessed coordinate: the channel is narrow and a hand-picked lat/lon lands in
# the adjacent fields.
#
# These are POINT-ON-SURFACE, not centroids. A river polygon is long and sinuous, so its centroid
# reliably falls OUTSIDE it — measured here, the centroid of all five largest reaches lies off the
# channel, one of them in cropland. An oracle built on centroids tests the neighbouring farm.
ORACLE_RIO_GRANDE = [(-106.6657, 32.1266), (-106.7198, 32.1716), (-106.6387, 32.2757)]
ORACLE_VALLEY_BOX = (-106.85, 32.22, -106.78, 32.30)
# The safety-relevant assertion is not "is it blue" but "is it offered as landable".
ORACLE_LANDABLE_CLASSES = (C.CLASS_OPEN_FIRM, C.CLASS_CROP)


def _workdir():
    d = os.path.join(C.WORK_DIR, C.CELL_ID)
    os.makedirs(d, exist_ok=True)
    return d


def _manifest_source(name):
    return C.load_manifest()["sources"].get(name, {})


def _grid_warp_raster(src, dst_path, resample="near", src_nodata=None, dst_nodata=0):
    """Warp any raster onto the master grid. Nearest by default — see the datum note."""
    g = C.master_grid()
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(C.ANALYSIS_EPSG)
    gdal.Warp(dst_path, src, dstSRS=srs.ExportToWkt(), resampleAlg=resample,
              outputBounds=(g["x_min"], g["y_min"], g["x_max"], g["y_max"]),
              xRes=C.CELL_SIZE_M, yRes=C.CELL_SIZE_M,
              srcNodata=src_nodata, dstNodata=dst_nodata,
              creationOptions=["COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"])
    ds = gdal.Open(dst_path)
    a = ds.ReadAsArray()
    ds = None
    return a


def build_nlcd():
    m = _manifest_source("nlcd")
    zip_path = m.get("local")
    if not zip_path or not os.path.exists(zip_path):
        sys.exit("nlcd not fetched — run: python3 lz/fetch.py --fetch --source nlcd")
    import zipfile
    with zipfile.ZipFile(zip_path) as z:
        tif = [n for n in z.namelist() if n.lower().endswith(".tif")][0]
    src = f"/vsizip/{os.path.abspath(zip_path)}/{tif}"
    out = os.path.join(_workdir(), "nlcd_10m.tif")
    print("  warping Annual NLCD (30 m, AEA/WGS84) -> master grid (10 m, EPSG:5070), nearest ...")
    return _grid_warp_raster(src, out, resample="near", dst_nodata=0).astype(np.uint8)


def build_canopy():
    """Stream the cell's canopy quadkeys, mosaic, and put them on the master grid."""
    p = os.path.join(C.DATA_DIR, C.CELL_ID, "canopy", "keys.json")
    if not os.path.exists(p):
        print("  canopy not resolved — skipping (land cover will carry vegetation)")
        return None
    with open(p) as f:
        d = json.load(f)
    keys = d.get("keys", [])
    if not keys:
        return None
    vsis = [f"/vsicurl/{d['bucket']}/{k}" for k in keys]
    wd = _workdir()
    vrt = os.path.join(wd, "canopy.vrt")
    print(f"  streaming {len(keys)} canopy COGs -> mosaic ...")
    gdal.BuildVRT(vrt, vsis)
    out = os.path.join(wd, "canopy_10m.tif")
    # Canopy is 1 m; reducing to 10 m takes the MAX, not the mean. A 20 m tree in a 10 m cell is
    # an obstacle whether or not it has nine open neighbours, and averaging would hide it.
    a = _grid_warp_raster(vrt, out, resample="max",
                          dst_nodata=CANOPY_NODATA).astype(np.float32)
    a[~np.isfinite(a)] = 0.0
    a[a == CANOPY_NODATA] = 0.0          # unmapped reads as "no canopy evidence", not as height
    a[a > CANOPY_MAX_PLAUSIBLE_M] = 0.0
    return a


def build_nwi():
    """Rasterise wetland polygons, separating open water from palustrine wetland."""
    m = _manifest_source("nwi")
    src = m.get("local")
    if not src or not os.path.exists(src):
        print("  nwi not fetched — skipping wetland refinement")
        return None, None
    g = C.master_grid()
    wd = _workdir()
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(C.ANALYSIS_EPSG)

    ds = ogr.Open(src)
    layer = ds.GetLayer(0)
    fields = [layer.GetLayerDefn().GetFieldDefn(i).GetName()
              for i in range(layer.GetLayerDefn().GetFieldCount())]
    attr = next((f for f in fields if f.upper().endswith("ATTRIBUTE")), None)
    ds = None

    def rasterise(where, name):
        out = os.path.join(wd, f"nwi_{name}.tif")
        drv = gdal.GetDriverByName("GTiff")
        tgt = drv.Create(out, g["cols"], g["rows"], 1, gdal.GDT_Byte,
                         options=["COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"])
        tgt.SetGeoTransform(g["geotransform"])
        tgt.SetProjection(srs.ExportToWkt())
        vds = ogr.Open(src)
        lyr = vds.GetLayer(0)
        if where:
            lyr.SetAttributeFilter(where)
        gdal.RasterizeLayer(tgt, [1], lyr, burn_values=[1])
        tgt.FlushCache()
        arr = tgt.ReadAsArray().astype(bool)
        tgt = None
        vds = None
        return arr

    if attr:
        pre = "','".join(NWI_WATER_PREFIX)
        perennial_river = (f"(SUBSTR({attr},1,1) = '{NWI_RIVERINE}' AND "
                           f"SUBSTR({attr},2,1) <> '{NWI_INTERMITTENT_SUBSYSTEM}')")
        water = rasterise(f"SUBSTR({attr},1,1) IN ('{pre}') OR {perennial_river}", "water")
        soft = rasterise(f"SUBSTR({attr},1,1) = '{NWI_RIVERINE}' AND "
                         f"SUBSTR({attr},2,1) = '{NWI_INTERMITTENT_SUBSYSTEM}'", "soft")
        wet = rasterise(f"SUBSTR({attr},1,1) NOT IN ('{pre}','{NWI_RIVERINE}')", "wet")
    else:
        water = rasterise(None, "water")
        soft = np.zeros_like(water)
        wet = np.zeros_like(water)
    return water, soft, wet


def _decay(source, vintage_year):
    """conf multiplier = exp(-age/tau). Old data is not wrong, but it is less load-bearing."""
    tau = TAU_YEARS.get(source, 8.0)
    age = max(0.0, BUILD_YEAR - float(vintage_year))
    return float(np.exp(-age / tau))


def cmd_build():
    wd = _workdir()
    nlcd = build_nlcd()
    canopy = build_canopy()
    water_nwi, soft_nwi, wet_nwi = build_nwi()

    rows, cols = nlcd.shape
    cls = np.full((rows, cols), C.CLASS_UNKNOWN, np.uint8)
    conf = np.full((rows, cols), C.CONF_UNKNOWN, np.uint8)

    nlcd_conf = int(CONF_BASE["nlcd"] * _decay("nlcd", 2025))
    nwi_conf = int(CONF_BASE["nwi"] * _decay("nwi", 2010))
    can_conf = int(CONF_BASE["canopy"] * _decay("canopy", 2016))

    # ---- the decision list. Written LOWEST priority first, so later writes override earlier
    # ones; the effective order is the reverse of the code order and is printed by --verify.
    applied = {}

    # 7. land cover (the base map)
    for code, klass in NLCD_TO_CLASS.items():
        sel = (nlcd == code)
        if sel.any():
            cls[sel] = klass
            conf[sel] = nlcd_conf
    applied["nlcd_base"] = int((cls != C.CLASS_UNKNOWN).sum())

    # 6/5/4. canopy promotes vegetation. It may only make a cell MORE obstructed (see the
    # staleness note): brush -> forest yes, forest -> open never.
    if canopy is not None:
        is_crop = (cls == C.CLASS_CROP)
        # Trees. Over cropland this needs unambiguous tree height (orchard), not crop height.
        tall = np.where(is_crop, canopy >= CANOPY_ORCHARD_M, canopy >= CANOPY_FOREST_M)
        promote = tall & (cls != C.CLASS_FOREST) & (cls != C.CLASS_WATER)
        cls[promote] = C.CLASS_FOREST
        conf[promote] = min(nlcd_conf, can_conf)
        applied["canopy_forest"] = int(promote.sum())

        # Brush. Never applied to cropland — a 1 m reading over a cotton field is the cotton.
        mid = (canopy >= CANOPY_BRUSH_M) & (canopy < CANOPY_FOREST_M)
        promote_b = mid & np.isin(cls, [C.CLASS_OPEN_FIRM, C.CLASS_BARREN_ROUGH])
        cls[promote_b] = C.CLASS_BRUSH
        conf[promote_b] = min(nlcd_conf, can_conf)
        applied["canopy_brush"] = int(promote_b.sum())

    # 3. NWI palustrine wetland — the deceptive open-meadow trap.
    if wet_nwi is not None and wet_nwi.any():
        sel = wet_nwi & (cls != C.CLASS_WATER)
        cls[sel] = C.CLASS_WETLAND
        conf[sel] = min(nwi_conf, nlcd_conf)
        applied["nwi_wetland"] = int(sel.sum())

    # 2b. Intermittent riverine — a dry arroyo. Soft and banked, so never landable, but not water.
    if soft_nwi is not None and soft_nwi.any():
        sel = soft_nwi & (cls != C.CLASS_WATER)
        cls[sel] = C.CLASS_OPEN_SOFT
        conf[sel] = min(nwi_conf, nlcd_conf)
        applied["nwi_intermittent_river"] = int(sel.sum())

    # 2. NWI open water.
    if water_nwi is not None and water_nwi.any():
        cls[water_nwi] = C.CLASS_WATER
        conf[water_nwi] = nwi_conf
        applied["nwi_water"] = int(water_nwi.sum())

    # 1. NLCD open water wins outright — a hard veto input, so it is decided last.
    sel = (nlcd == 11)
    cls[sel] = C.CLASS_WATER
    conf[sel] = nlcd_conf
    applied["nlcd_water"] = int(sel.sum())

    # Anything still unknown keeps CONF_UNKNOWN — never quietly promoted to a default class.
    unknown = (cls == C.CLASS_UNKNOWN)
    conf[unknown] = C.CONF_UNKNOWN
    applied["left_unknown"] = int(unknown.sum())

    np.save(os.path.join(wd, "class.npy"), cls)
    np.save(os.path.join(wd, "conf.npy"), conf)
    if canopy is not None:
        np.save(os.path.join(wd, "canopy.npy"), canopy)
    with open(os.path.join(wd, "surface_rules.json"), "w") as f:
        json.dump({"applied": applied, "conf": {"nlcd": nlcd_conf, "nwi": nwi_conf,
                                                "canopy": can_conf}}, f, indent=2)

    print(f"\nclass {cols}x{rows}")
    tot = cls.size
    for k in sorted(C.CLASS_NAMES, key=lambda k: -int((cls == k).sum())):
        n = int((cls == k).sum())
        if n:
            print(f"  {C.CLASS_NAMES[k]:<16} {n/tot*100:6.2f}%  {n:>10,}")
    print("\nrule hits: " + json.dumps(applied))
    return 0


def cmd_verify():
    wd = _workdir()
    p = os.path.join(wd, "class.npy")
    if not os.path.exists(p):
        sys.exit("no surface build — run --build")
    cls = np.load(p)
    conf = np.load(os.path.join(wd, "conf.npy"))
    g = C.master_grid()
    ok = True

    # 1. The Rio Grande channel must never be offered as landable. Asserting "is it water" would
    #    be the wrong test — NWI maps this reach as R4 (intermittent) streambed and it is dry for
    #    much of the year. What matters for safety is that it is not offered as a field.
    hits, seen = 0, []
    for lon, lat in ORACLE_RIO_GRANDE:
        rc = C.lonlat_to_grid(lon, lat, g)
        if not rc:
            continue
        k = int(cls[rc[0], rc[1]])
        seen.append(C.CLASS_NAMES[k])
        if k not in ORACLE_LANDABLE_CLASSES:
            hits += 1
    good = hits == len(ORACLE_RIO_GRANDE)
    print(f"{'ok  ' if good else 'FAIL'} Rio Grande channel not landable at {hits}/"
          f"{len(ORACLE_RIO_GRANDE)} points {seen}")
    ok &= good

    # 2. The irrigated valley must be predominantly cultivable, not desert scrub.
    rc0 = C.lonlat_to_grid(ORACLE_VALLEY_BOX[0], ORACLE_VALLEY_BOX[3], g)
    rc1 = C.lonlat_to_grid(ORACLE_VALLEY_BOX[2], ORACLE_VALLEY_BOX[1], g)
    if rc0 and rc1:
        sub = cls[min(rc0[0], rc1[0]):max(rc0[0], rc1[0]) + 1,
                  min(rc0[1], rc1[1]):max(rc0[1], rc1[1]) + 1]
        farm = float(np.isin(sub, [C.CLASS_CROP, C.CLASS_OPEN_FIRM]).mean() * 100)
        good = farm >= 25.0
        print(f"{'ok  ' if good else 'FAIL'} Mesilla valley crop/open share {farm:.1f}% (need >=25)")
        ok &= good
    else:
        print("FAIL valley oracle box outside the grid")
        ok = False

    # 3. Water must be a minority of a desert cell — a runaway water class means the warp or the
    #    nodata handling is wrong, which would veto the whole map.
    wshare = float((cls == C.CLASS_WATER).mean() * 100)
    good = wshare < 5.0
    print(f"{'ok  ' if good else 'FAIL'} water share {wshare:.2f}% of grid (need <5 in a desert cell)")
    ok &= good

    # 4. Confidence must never exceed the best single source — fusion cannot manufacture it.
    real = conf[conf != C.CONF_UNKNOWN]
    hi = int(real.max()) if real.size else 0
    good = hi <= max(CONF_BASE.values())
    print(f"{'ok  ' if good else 'FAIL'} max confidence {hi} <= best base {max(CONF_BASE.values())}")
    ok &= good

    # 5. Unknown must stay unknown, not silently become a class.
    unk = float((cls == C.CLASS_UNKNOWN).mean() * 100)
    print(f"info unknown {unk:.2f}% of grid (bbox exceeds the cell by ~18% — see cone_convergence)")

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
