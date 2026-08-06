#!/usr/bin/env python3
"""terrain.py — Stage 1: slope, roughness and micro-relief, reduced from NATIVE 1 m lidar.

WHAT IT MAKES
    lz/work/<cell>/tiles10m/<tile>.tif   per-source-tile, 4-band float32 at 10 m in the tile's
                                         native CRS: [slope_deg, rough_m, micro_m, elev_m]
    lz/work/<cell>/slope.npy             \\
    lz/work/<cell>/rough.npy              |  mosaicked onto the EPSG:5070 master grid
    lz/work/<cell>/micro.npy              |
    lz/work/<cell>/terrain_src.npy       /   0=fine(1 m) 1=mixed 2=coarse(1/3")
    lz/terrain_archive/elev10m_<cell>.tif    THE HEIGHT ITSELF — int16 m, DEFLATE, EPSG:5070.
                                         NOT scratch: this survives the per-cell cleanup.

WHY THE ELEVATION IS KEPT
    The landability planes need only the DERIVATIVES of height, so height was computed, used and
    discarded — throwing away the ~45 min and ~30 GB of streaming that produced it. Anything wanting
    the terrain itself (synthetic vision) would have to pull the whole lot again. The block mean is
    already computed as the datum the roughness residuals are measured against, so keeping it is
    nearly free. Held at the full 10 m analysis posting rather than the ~30 m a horizon view needs:
    coarsening later is instant, re-downloading is not.

WHY THE STATISTICS COME FROM 1 m AND NOT FROM A 10 m GRID
    This is the one ordering mistake that silently produces a confident wrong answer. Detrended
    roughness and micro-relief are DEFINED as sub-10 m variation. Warp the DEM to 10 m first and
    that variation is gone — every cell comes back smooth, the roughness veto never fires, and
    boulder fields score like hayfields. So each source tile is read at its native 1 m posting and
    REDUCED to 10 m here; resampling happens only afterwards, on the already-computed statistics.

    The corollary is that this stage is I/O-bound on ~30 GB for a single 1x1 degree cell (155
    tiles x ~198 MB). The tiles are LZW GeoTIFFs on S3 with `Accept-Ranges: bytes`, so they are
    STREAMED through GDAL's /vsicurl/ and never stored. Peak disk is the 10 m output.

THE THREE METRICS
    slope_deg  — Horn 3x3 gradient at 1 m, then the MEDIAN over each 10x10 block. Median, not
                 mean: a single noisy lidar return should not define a cell, but a real bank
                 must survive. (Same reasoning as the shipped terrain grid's max-aggregation:
                 pick the statistic that cannot be talked out of a real feature.)
    rough_m    — sigma of the residuals after a least-squares PLANE is removed from each 10x10
                 block. This is what separates "steep but smooth" (landable downhill) from
                 "boulder field" (not landable at any angle). Without detrending, every slope
                 would read as rough. VERIFIED: flat+noise and a 20-degree plane+the same noise
                 return sigma identical to four decimals.
    micro_m    — detrended peak-to-peak inside the same block: max(residual) - min(residual).
                 A ditch, berm or gully crossing the cell shows up here even when sigma stays
                 small, because a narrow deep feature moves the extremes far more than the
                 spread. VERIFIED: a 1 m wide, 1.5 m deep ditch reads micro 1.54 m / sigma 0.45 m.
                 This is the "hidden ditch" veto input.

    All three share one plane fit per block, computed in closed form (the block's x/y offsets are
    a fixed centred lattice, so the normal equations collapse to two dot products).

REQUIREMENTS
    numpy and the GDAL PYTHON BINDINGS (osgeo). The rest of the pipeline is CLI-only, but reading
    windows out of 155 remote LZW GeoTIFFs through subprocesses meant a temp-file round-trip per
    strip; the bindings do it in one call with no intermediate file and no parsing.

CELL NOTE — n33w107
    3DEP 1 m covers 100% of this cell from six projects flown 2014-2020, so terrain_src is FINE
    everywhere and the coarse-DEM cap is NOT exercised here. That rule still has to be tested:
    the packaging fixture carries a synthetic coarse tile for exactly that reason.

USAGE
    python3 lz/terrain.py --selftest              # metric maths against hand-computable surfaces
    python3 lz/terrain.py --build                 # all tiles, resumable
    python3 lz/terrain.py --build --limit 4       # smoke test on four tiles
    python3 lz/terrain.py --mosaic                # per-tile products -> master grid
    python3 lz/terrain.py --verify                # Organ Mountains / Mesilla Valley oracles
"""

import argparse
import json
import math
import os
import sys
import warnings

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C  # noqa: E402

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: python3 -m pip install numpy")

try:
    from osgeo import gdal, osr
except ImportError:
    sys.exit("the GDAL Python bindings are required: python3 -m pip install gdal "
             "(or use the GDAL that ships with your package manager)")

gdal.UseExceptions()
gdal.SetConfigOption("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
gdal.SetConfigOption("GDAL_HTTP_TIMEOUT", "120")
gdal.SetConfigOption("VSI_CACHE", "TRUE")
gdal.SetConfigOption("VSI_CACHE_SIZE", str(64 << 20))
gdal.SetConfigOption("CPL_VSIL_CURL_CHUNK_SIZE", str(1 << 20))

BLOCK = 10                      # 1 m samples per 10 m output cell
STRIP_BLOCKS = 200              # output rows per streamed read -> 2000 source rows, ~80 MB
NODATA_OUT = float("nan")

# Oracle boxes (lon_min, lat_min, lon_max, lat_max). Ground truth for --verify.
ORACLE_ORGAN_CREST = (-106.58, 32.32, -106.53, 32.40)     # Organ Mountains spine
ORACLE_MESILLA_FLOOR = (-106.85, 32.22, -106.78, 32.30)   # irrigated valley floor
ORACLE_ORGAN_MIN_SLOPE_DEG = 15.0
ORACLE_VALLEY_MAX_SLOPE_DEG = 3.0
ORACLE_MIN_SEPARATION_DEG = 10.0


def _tiles():
    p = os.path.join(C.DATA_DIR, C.CELL_ID, "dem_3dep", "tiles_1m.json")
    if not os.path.exists(p):
        sys.exit("dem_3dep not resolved — run: python3 lz/fetch.py --fetch --source dem_3dep")
    with open(p) as f:
        return json.load(f)


def block_stats(z, nodata=None):
    """Reduce a 1 m elevation array to 10 m [slope_deg, rough_m, micro_m].

    One closed-form plane fit per 10x10 block serves all three metrics. Rows/cols arrive trimmed
    to whole blocks by the caller."""
    assert z.ndim == 2, "block_stats: expected a 2-D array"
    assert z.shape[0] % BLOCK == 0 and z.shape[1] % BLOCK == 0, "block_stats: ragged block grid"
    h, w = z.shape
    bh, bw = h // BLOCK, w // BLOCK
    zz = z.astype(np.float64, copy=False)
    valid = np.isfinite(zz)
    if nodata is not None:
        valid &= (zz != nodata)
    zz = np.where(valid, zz, np.nan)

    # Horn 3x3 slope at NATIVE resolution, before any reduction.
    gy, gx = np.gradient(zz)
    slope_1m = np.degrees(np.arctan(np.hypot(gx, gy)))

    # A block that is entirely nodata legitimately reduces to NaN — that is the correct answer
    # ("we do not know here"), and NaN is what the packer turns into the nodata byte. numpy still
    # warns on every all-NaN slice, so silence those specifically rather than let real warnings
    # drown in them.
    with np.errstate(all="ignore"), warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="All-NaN slice encountered")
        warnings.filterwarnings("ignore", message="Mean of empty slice")
        sl = slope_1m.reshape(bh, BLOCK, bw, BLOCK).transpose(0, 2, 1, 3).reshape(bh, bw, -1)
        slope = np.nanmedian(sl, axis=2)

        # Centred lattice: sum(x)=0, so the normal equations decouple into two dot products.
        t = np.arange(BLOCK, dtype=np.float64) - (BLOCK - 1) / 2.0
        X = np.repeat(t[:, None], BLOCK, axis=1).ravel()
        Y = np.repeat(t[None, :], BLOCK, axis=0).ravel()
        sxx, syy = (X * X).sum(), (Y * Y).sum()

        blk = zz.reshape(bh, BLOCK, bw, BLOCK).transpose(0, 2, 1, 3).reshape(bh, bw, -1)
        mean = np.nanmean(blk, axis=2, keepdims=True)
        d = blk - mean
        a = np.nansum(d * X, axis=2) / sxx
        b = np.nansum(d * Y, axis=2) / syy
        resid = d - (a[..., None] * X + b[..., None] * Y)
        rough = np.sqrt(np.nanmean(resid * resid, axis=2))
        micro = np.nanmax(resid, axis=2) - np.nanmin(resid, axis=2)
    # ELEVATION COMES FREE. `mean` is the block's mean height, already computed above as the datum
    # the plane fit measures residuals against. Returning it costs one array copy and saves having to
    # stream ~145 source tiles a second time if anything ever needs the terrain itself — synthetic
    # vision being the obvious candidate. The landability planes discard height and keep only its
    # derivatives, so without this the elevation we paid 45 minutes to download is thrown away.
    return (slope.astype(np.float32), rough.astype(np.float32), micro.astype(np.float32),
            mean[..., 0].astype(np.float32))


def build_tile(url, out_path, force=False):
    """Stream one 1 m source tile and write its 10 m 3-band product. Resumable."""
    assert url.endswith(".tif"), "build_tile: expected a GeoTIFF url"
    if os.path.exists(out_path) and not force:
        return "skip"
    try:
        ds = gdal.Open("/vsicurl/" + url)
    except RuntimeError:
        return "unreadable"
    if ds is None:
        return "unreadable"
    w, h = ds.RasterXSize, ds.RasterYSize
    band = ds.GetRasterBand(1)
    nodata = band.GetNoDataValue()
    gt = ds.GetGeoTransform()
    wkt = ds.GetProjection()
    bh, bw = h // BLOCK, w // BLOCK
    if bh < 1 or bw < 1:
        return "too-small"

    slope = np.full((bh, bw), np.nan, np.float32)
    rough = np.full((bh, bw), np.nan, np.float32)
    micro = np.full((bh, bw), np.nan, np.float32)
    elev = np.full((bh, bw), np.nan, np.float32)

    for b0 in range(0, bh, STRIP_BLOCKS):
        nb = min(STRIP_BLOCKS, bh - b0)
        y0, ny = b0 * BLOCK, nb * BLOCK
        # One-row halo so the gradient is correct across strip seams.
        pre = 1 if y0 > 0 else 0
        post = 1 if y0 + ny < h else 0
        arr = band.ReadAsArray(0, y0 - pre, bw * BLOCK, ny + pre + post)
        if arr is None:
            ds = None
            return "read-failed"
        s, ro, mi, el = block_stats(arr[pre:pre + ny, :].astype(np.float64), nodata)
        slope[b0:b0 + nb, :] = s
        rough[b0:b0 + nb, :] = ro
        micro[b0:b0 + nb, :] = mi
        elev[b0:b0 + nb, :] = el
    ds = None

    gt10 = (gt[0], gt[1] * BLOCK, gt[2], gt[3], gt[4], gt[5] * BLOCK)
    _write_stack(out_path, np.stack([slope, rough, micro, elev]), gt10, wkt)
    return "built"


def build_coarse_tile(url, out_path, force=False):
    """Build a 10 m product from a 1/3 arc-second (~10 m) DEM, for ground with no 1 m lidar.

    ⚠️ SLOPE SURVIVES THE DOWNGRADE. ROUGHNESS AND MICRO-RELIEF DO NOT, AND MUST STAY UNKNOWN.
    `rough` and `micro` are measurements of variation WITHIN a 10 m cell — the plough furrow, the
    irrigation ditch, the berm. A 1/3 arc-second source has one sample per cell, so that variation is
    not attenuated here, it is absent. Computing them anyway would yield ~0, and zero roughness is
    the single most dangerous value this pipeline can emit: it reads as "smooth", it is what the
    ditch veto tests, and it would make unsurveyed ground score BETTER than ground we measured
    properly. They are written as NaN — "not known" — and the coarse cap on the device is what keeps
    the resulting score honest.

    Slope is computed on the native 10 m grid, which is a real measurement at this scale: a 3 deg
    field still reads as 3 deg. It is only the sub-cell detail that is gone."""
    assert url.endswith(".tif"), "build_coarse_tile: expected a GeoTIFF url"
    if os.path.exists(out_path) and not force:
        return "skip"
    try:
        ds = gdal.Open("/vsicurl/" + url)
    except RuntimeError:
        return "unreadable"
    if ds is None:
        return "unreadable"
    band = ds.GetRasterBand(1)
    nodata = band.GetNoDataValue()
    gt, wkt = ds.GetGeoTransform(), ds.GetProjection()
    z = band.ReadAsArray()
    ds = None
    if z is None:
        return "read-failed"
    z = z.astype(np.float64)
    if nodata is not None:
        z = np.where(z == nodata, np.nan, z)

    # Horn 3x3 on the native grid. The cell is not square in metres at this latitude — the source is
    # geographic — so each axis gets its own spacing or the slope is wrong by the cosine of latitude.
    lat = gt[3] + gt[5] * (z.shape[0] / 2.0)
    dy_m = abs(gt[5]) * 111_320.0
    dx_m = abs(gt[1]) * 111_320.0 * math.cos(math.radians(lat))
    assert dx_m > 0 and dy_m > 0, "build_coarse_tile: degenerate pixel size"
    # ⚠️ A TILE OF PURE NODATA IS A FAILED READ, NOT A FLAT CELL. When a /vsicurl stream fails
    # part-way, GDAL hands back a perfectly valid array filled with the band's nodata value; the
    # masking above then turns all of it into NaN and everything downstream carries on. That is
    # exactly what happened to n35w108: an all-NaN slope plane, so no cell could pass the extent
    # scan, so the pack said NOWHERE in a 1-degree cell has room to land — and it verified, gated
    # and shipped at 11 MB while its neighbours were 55. The source DEM was fine the whole time.
    #
    # Nothing else in the pipeline can tell that apart from real terrain, so it has to be caught here.
    finite = int(np.isfinite(z).sum())
    if finite == 0:
        return "read-failed"
    # ⚠️ AND A PARTIAL TILE IS NOT AUTOMATICALLY A FAILED ONE. The first version of this guard read
    # "under half the tile carried elevation" as a broken stream, which is true inland and WRONG
    # everywhere the United States has an edge. 3DEP carries nodata over ocean and stops at the
    # border, so a coastal or borderland cell is legitimately half empty: n33w117 is 53% Mexico and
    # measured 41.4% — a perfectly good read of a cell that is mostly somewhere else. It cost San
    # Diego and its neighbour, and every remaining coastal cell was queued to fail the same way.
    #
    # So TEST THE HYPOTHESIS instead of proxying it. A broken stream is transient and a coastline is
    # not: re-read the tile with the HTTP cache dropped and compare the valid masks. Identical means
    # geography, which is a real answer; different means the read is unstable, which is not. One
    # extra read, paid only in the suspicious case.
    #
    # The missing ground is not invented either way — it stays NaN, lands as `unknown` in the class
    # plane, and the device scores it as unmeasured rather than as anything a pilot could use.
    if finite < z.size // 2:
        pct = 100.0 * finite / z.size
        gdal.VSICurlClearCache()
        try:
            again = gdal.Open("/vsicurl/" + url)
            z2 = again.GetRasterBand(1).ReadAsArray() if again is not None else None
            again = None
        except RuntimeError:
            z2 = None
        if z2 is None:
            print(f"     ^ {pct:.1f}% of {os.path.basename(url)} and the re-read failed outright",
                  flush=True)
            return "read-failed"
        mask2 = np.ones_like(z2, bool) if nodata is None else (z2 != nodata)
        finite2 = int(mask2.sum())
        if finite2 != finite:
            print(f"     ^ {os.path.basename(url)} read {pct:.1f}% then "
                  f"{100.0 * finite2 / z2.size:.1f}% — unstable, treating as a failed read",
                  flush=True)
            return "read-failed"
        print(f"     ^ {pct:.1f}% of {os.path.basename(url)} carried elevation, twice — this is "
              "coastline or border, not a broken read; the rest stays unmeasured", flush=True)

    with np.errstate(all="ignore"):
        gy, gx = np.gradient(z, dy_m, dx_m)
        slope = np.degrees(np.arctan(np.hypot(gx, gy))).astype(np.float32)
    assert np.isfinite(slope).any(), "build_coarse_tile: slope came out entirely unmeasured"
    unknown = np.full(slope.shape, np.nan, np.float32)
    _write_stack(out_path, np.stack([slope, unknown, unknown, z.astype(np.float32)]), gt, wkt)
    return "built"


def _write_stack(path, stack, geotransform, wkt):
    assert stack.ndim == 3, "_write_stack: expected (bands, rows, cols)"
    nb, h, w = stack.shape
    os.makedirs(os.path.dirname(path), exist_ok=True)
    drv = gdal.GetDriverByName("GTiff")
    out = drv.Create(path, w, h, nb, gdal.GDT_Float32,
                     options=["COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"])
    out.SetGeoTransform(geotransform)
    if wkt:
        out.SetProjection(wkt)
    for i in range(nb):
        b = out.GetRasterBand(i + 1)
        b.WriteArray(stack[i])
        b.SetNoDataValue(NODATA_OUT)
    out.FlushCache()
    out = None


def cmd_build(limit, force):
    d = _tiles()
    tiles = d["tiles"][:limit] if limit else d["tiles"]
    outdir = os.path.join(C.WORK_DIR, C.CELL_ID, "tiles10m")
    os.makedirs(outdir, exist_ok=True)
    tally = {}
    for i, t in enumerate(tiles, 1):
        name = os.path.basename(t["url"])
        res = build_tile(t["url"], os.path.join(outdir, name), force=force)
        tally[res] = tally.get(res, 0) + 1
        print(f"[{i}/{len(tiles)}] {res:<12} {name[:66]}", flush=True)

    # The 1/3 arc-second fallback, for the part of the cell 1 m lidar does not reach. Kept in a
    # SEPARATE directory so the mosaic can tell the two apart — which is the whole basis of the
    # coarse cap, and cannot be recovered later by looking at the pixels.
    #
    # ⚠️ This used to be skipped entirely. `--build` iterated the 1 m list, found it empty on a
    # non-lidar cell, printed "{}" and exited 0 — a stage returning success having produced nothing —
    # and the failure surfaced one step later as "no per-tile products". Every cell outside 1 m
    # coverage died there, which is roughly a fifth of CONUS.
    fb = d.get("fallback_13") or []
    coarsedir = os.path.join(C.WORK_DIR, C.CELL_ID, "tiles10m_coarse")
    if fb:
        os.makedirs(coarsedir, exist_ok=True)
        for i, url in enumerate(fb, 1):
            name = os.path.basename(url)
            res = build_coarse_tile(url, os.path.join(coarsedir, name), force=force)
            tally[f"coarse:{res}"] = tally.get(f"coarse:{res}", 0) + 1
            print(f"[coarse {i}/{len(fb)}] {res:<12} {name[:60]}", flush=True)

    print("\n" + json.dumps(tally))
    bad = sum(v for k, v in tally.items() if k.endswith(("read-failed", "unreadable")))
    if not tiles and not fb:
        print("no 1 m tiles and no 1/3 arc-second fallback — nothing to build", file=sys.stderr)
        return 1
    return 1 if bad else 0


def _warp_to_grid(tifs, vrt, warped, g):
    """VRT + warp a set of per-tile products onto the master grid. Returns (bands, rows, cols)."""
    gdal.BuildVRT(vrt, tifs)
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(C.ANALYSIS_EPSG)
    # Nearest, not bilinear: these are already at 10 m, so the warp is a near-identity
    # reprojection, and smoothing would blunt the very extremes the metrics exist to preserve.
    gdal.Warp(warped, vrt, dstSRS=srs.ExportToWkt(), resampleAlg="near",
              outputBounds=(g["x_min"], g["y_min"], g["x_max"], g["y_max"]),
              xRes=C.CELL_SIZE_M, yRes=C.CELL_SIZE_M, dstNodata=NODATA_OUT,
              creationOptions=["COMPRESS=DEFLATE", "TILED=YES", "BIGTIFF=IF_SAFER"])
    ds = gdal.Open(warped)
    arr = ds.ReadAsArray().astype(np.float32)
    ds = None
    assert arr.shape[0] == 4, "mosaic: expected four bands (slope, rough, micro, elev)"
    return arr


def _list_products(d):
    if not os.path.isdir(d):
        return []
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".tif"))


def cmd_mosaic():
    g = C.master_grid()
    workdir = os.path.join(C.WORK_DIR, C.CELL_ID)
    tifs = _list_products(os.path.join(workdir, "tiles10m"))
    coarse_tifs = _list_products(os.path.join(workdir, "tiles10m_coarse"))
    if not tifs and not coarse_tifs:
        sys.exit("no per-tile products — run --build first")

    raw = (_warp_to_grid(tifs, os.path.join(workdir, "terrain10m.vrt"),
                         os.path.join(workdir, "terrain10m_5070.tif"), g)
           if tifs else None)

    # WHERE THE 1 m DATA ACTUALLY LANDED is the only honest basis for the source label. Deriving it
    # from "slope is finite" was correct only while every cell was 100% lidar: on a fallback cell the
    # coarse DEM also yields finite slope everywhere, so that test would have stamped the whole cell
    # FINE and quietly disabled the coarse cap — unsurveyed ground scoring as if it had been
    # measured, which is the exact failure this plane exists to prevent.
    fine_ok = np.isfinite(raw[0]) if raw is not None else None
    if coarse_tifs:
        coarse = _warp_to_grid(coarse_tifs, os.path.join(workdir, "terrain10m_coarse.vrt"),
                               os.path.join(workdir, "terrain10m_coarse_5070.tif"), g)
        if raw is None:
            raw, fine_ok = coarse, np.zeros(coarse.shape[1:], bool)
        else:
            # Fine wins wherever it exists; coarse fills the rest. Band-wise, so a coarse cell keeps
            # its NaN roughness rather than inheriting a neighbouring fine cell's.
            raw = np.where(fine_ok[None, :, :], raw, coarse)
        src = np.where(fine_ok, C.TERRAIN_SRC_FINE, C.TERRAIN_SRC_COARSE).astype(np.uint8)
    else:
        src = np.where(fine_ok, C.TERRAIN_SRC_FINE, C.TERRAIN_SRC_COARSE).astype(np.uint8)

    # The same check one level up, because a per-tile product can be fine and the MOSAIC still land
    # nowhere near the master grid (a wrong fallback tile, a bad geotransform). Either way the next
    # three stages would run happily on an empty grid and produce a pack that passes every
    # structural gate while asserting there is no measurable ground in the cell.
    measured = float(np.isfinite(raw[0]).mean())
    if measured < 0.10:
        sys.exit(f"mosaic: only {measured * 100:.2f}% of the grid has any slope at all. That is a "
                 "failed or misplaced source read, not terrain — refusing to build on it.")

    # ============================================================================================
    # THE ELEVATION ARCHIVE — kept OUTSIDE the scratch that gets deleted after packaging.
    # ============================================================================================
    # The landability planes need only the DERIVATIVES of height (slope, roughness, micro-relief),
    # so height itself was computed, used and thrown away — along with the ~45 minutes and ~30 GB of
    # streaming that produced it. Anything wanting the terrain itself, synthetic vision above all,
    # would have had to re-stream the lot.
    #
    # Written as int16 metres, DEFLATE, at the 10 m analysis posting. The app's bundled CONUS grid is
    # 1855 m per post — fine for an AGL readout, far too coarse for a horizon: a ridge is two samples
    # wide. Keeping the full 10 m here means a device-facing pack can later be derived at whatever
    # resolution that feature wants (30 m is the usual choice) WITHOUT touching the network again.
    # Coarsening is free; the reverse is not.
    arch = os.path.join(C.LZ_ROOT, "terrain_archive")
    os.makedirs(arch, exist_ok=True)
    elev = raw[3]
    ELEV_NODATA = -32768
    q = np.where(np.isfinite(elev), np.clip(np.round(elev), -32000, 32000), ELEV_NODATA)
    drv = gdal.GetDriverByName("GTiff")
    ep = os.path.join(arch, f"elev10m_{C.CELL_ID}.tif")
    out = drv.Create(ep, q.shape[1], q.shape[0], 1, gdal.GDT_Int16,
                     options=["COMPRESS=DEFLATE", "PREDICTOR=2", "ZLEVEL=9",
                              "TILED=YES", "BIGTIFF=IF_SAFER"])
    out.SetGeoTransform((g["x_min"], C.CELL_SIZE_M, 0, g["y_max"], 0, -C.CELL_SIZE_M))
    srs2 = osr.SpatialReference(); srs2.ImportFromEPSG(C.ANALYSIS_EPSG)
    out.SetProjection(srs2.ExportToWkt())
    band = out.GetRasterBand(1)
    band.WriteArray(q.astype(np.int16))
    band.SetNoDataValue(ELEV_NODATA)
    out.FlushCache(); out = None
    measured_elev = float(np.isfinite(elev).mean() * 100.0)
    print(f"elevation archive: {ep} "
          f"({os.path.getsize(ep) / 1e6:.0f} MB, {measured_elev:.1f}% measured)")

    np.save(os.path.join(workdir, "slope.npy"), raw[0])
    np.save(os.path.join(workdir, "rough.npy"), raw[1])
    np.save(os.path.join(workdir, "micro.npy"), raw[2])
    np.save(os.path.join(workdir, "terrain_src.npy"), src)
    coarse_pct = float((src == C.TERRAIN_SRC_COARSE).mean() * 100.0)
    print(f"terrain source: {100.0 - coarse_pct:.2f}% from 1 m lidar, {coarse_pct:.2f}% coarse "
          "(1/3 arc-second — roughness and micro-relief are UNKNOWN there, not zero)")

    print(f"mosaic {raw.shape[2]}x{raw.shape[1]} on the master grid; "
          f"1 m-derived coverage {fine_ok.mean()*100:.2f}% of the bbox "
          f"(the cell fills ~82% of it — see lzcommon.cone_convergence_rad)")

    def _stat(a, fmt, unit):
        """Summarise a band, saying so plainly when it holds no measurement at all.

        On a fallback-only cell `rough` and `micro` are entirely NaN by design. Printing "nan" there
        reads like a fault; it is the correct answer and the line should say which."""
        with np.errstate(all="ignore"), warnings.catch_warnings():
            warnings.filterwarnings("ignore", message="All-NaN slice encountered")
            warnings.filterwarnings("ignore", message="All-NaN axis encountered")
            if not np.isfinite(a).any():
                return "not measured anywhere (coarse DEM)"
            return (f"median {np.nanmedian(a):{fmt}} {unit}"
                    f"   p99 {np.nanpercentile(a, 99):{fmt}} {unit}")
    print(f"  slope  {_stat(raw[0], '.2f', 'deg')}")
    print(f"  rough  {_stat(raw[1], '.3f', 'm')}")
    print(f"  micro  {_stat(raw[2], '.3f', 'm')}")
    return 0


def _box(arr, box, g):
    rc0 = C.lonlat_to_grid(box[0], box[3], g)
    rc1 = C.lonlat_to_grid(box[2], box[1], g)
    if not rc0 or not rc1:
        return None
    r0, c0 = rc0
    r1, c1 = rc1
    sub = arr[min(r0, r1):max(r0, r1) + 1, min(c0, c1):max(c0, c1) + 1]
    sub = sub[np.isfinite(sub)]
    return None if sub.size == 0 else sub


def cmd_verify():
    workdir = os.path.join(C.WORK_DIR, C.CELL_ID)
    p = os.path.join(workdir, "slope.npy")
    if not os.path.exists(p):
        sys.exit("no mosaic — run --build then --mosaic")
    slope = np.load(p)
    g = C.master_grid()
    ok = True

    crest = _box(slope, ORACLE_ORGAN_CREST, g)
    floor = _box(slope, ORACLE_MESILLA_FLOOR, g)
    if crest is None or floor is None:
        print("FAIL an oracle box has no finite slope — mosaic is incomplete")
        return 1

    mc, mf = float(np.median(crest)), float(np.median(floor))
    for label, got, need, cmp_ok in (
            ("Organ crest median slope", mc, ORACLE_ORGAN_MIN_SLOPE_DEG, mc >= ORACLE_ORGAN_MIN_SLOPE_DEG),
            ("Mesilla valley median slope", mf, ORACLE_VALLEY_MAX_SLOPE_DEG, mf <= ORACLE_VALLEY_MAX_SLOPE_DEG),
            ("crest/valley separation", mc - mf, ORACLE_MIN_SEPARATION_DEG,
             (mc - mf) >= ORACLE_MIN_SEPARATION_DEG)):
        print(f"{'ok  ' if cmp_ok else 'FAIL'} {label}: {got:.2f} deg (bound {need})")
        ok &= cmp_ok

    print("\nVERIFY PASS" if ok else "\nVERIFY FAIL")
    return 0 if ok else 1


def cmd_selftest():
    """The metric maths, against surfaces whose answers are known by hand."""
    ok = True

    def chk(name, cond, detail=""):
        nonlocal ok
        print(f"{'ok  ' if cond else 'FAIL'} {name} {detail}")
        ok &= cond

    for tilt in (0.0, 3.0, 20.0):
        yy, xx = np.mgrid[0:30, 0:30]
        s, r, mi, _ = block_stats(np.tan(np.radians(tilt)) * xx.astype(float))
        chk(f"plane {tilt:>4.1f} deg", abs(np.nanmedian(s) - tilt) < 0.05 and np.nanmax(r) < 1e-6,
            f"slope={np.nanmedian(s):.3f} rough={np.nanmax(r):.1e}")

    rng = np.random.default_rng(3)
    noise = rng.normal(0, 0.25, (30, 30))
    _, r_flat, _, _ = block_stats(noise)
    yy, xx = np.mgrid[0:30, 0:30]
    _, r_tilt, _, _ = block_stats(np.tan(np.radians(20)) * xx + noise)
    chk("detrending separates tilt from texture",
        abs(np.nanmedian(r_flat) - np.nanmedian(r_tilt)) < 0.02,
        f"flat={np.nanmedian(r_flat):.4f} vs 20deg={np.nanmedian(r_tilt):.4f}")

    z = np.zeros((10, 10))
    z[:, 4] = -1.5
    s, r, mi, _ = block_stats(z)
    chk("a ditch reads in micro, not sigma", float(mi[0, 0]) > 1.3 and float(r[0, 0]) < 0.6,
        f"micro={float(mi[0,0]):.2f} m sigma={float(r[0,0]):.2f} m")

    z = np.full((10, 10), 100.0)
    z[3:6, 3:6] = np.nan
    s, r, _, _ = block_stats(z)
    chk("nodata does not fabricate flat ground", np.isfinite(s[0, 0]) and float(r[0, 0]) < 1e-6)

    z = np.full((10, 10), 100.0)
    s, r, _, _ = block_stats(z, nodata=100.0)
    chk("an all-nodata block yields nan, not zero", not np.isfinite(s[0, 0]))

    print("\nSELFTEST PASS" if ok else "\nSELFTEST FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true", help="metric maths on known surfaces")
    ap.add_argument("--build", action="store_true", help="reduce 1 m source tiles to 10 m products")
    ap.add_argument("--mosaic", action="store_true", help="warp per-tile products to the master grid")
    ap.add_argument("--verify", action="store_true", help="Organ / Mesilla oracles")
    ap.add_argument("--limit", type=int, default=0, help="only the first N tiles (smoke test)")
    ap.add_argument("--force", action="store_true", help="rebuild tiles that already exist")
    C.add_cell_argument(ap)
    a = ap.parse_args()
    C.select_cell(a.cell)          # before ANY path, window or URL is built

    rc = 0
    if a.selftest:
        rc |= cmd_selftest()
    if a.build:
        rc |= cmd_build(a.limit, a.force)
    if a.mosaic:
        rc |= cmd_mosaic()
    if a.verify:
        rc |= cmd_verify()
    if not (a.selftest or a.build or a.mosaic or a.verify):
        ap.print_help()
    return rc


if __name__ == "__main__":
    sys.exit(main())
