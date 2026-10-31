"""Build one 1-degree cell of the avoid map.

    python3 -I lz/avoid/cell.py n33w107

Output: $AVOID_WORK/cells/<cell>.sqlite (tiles: z12 x, y, mask blob, slope blob) and <cell>.json
(the receipt: status ok | empty | failed, coverage, per-reason fractions, timing). A cell writes
its .sqlite FIRST and its receipt LAST, so a receipt that says ok always has its tiles.

Every input is read through a guard that fails the cell rather than writing a map that silently
claims there is nothing to avoid (the LZ pipeline's recurring failure: a stage that produces nothing
and reports success).
"""
import json
import math
import os
import sqlite3
import subprocess
import sys
import time

import numpy as np
from osgeo import gdal, ogr, osr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

gdal.UseExceptions()
for k, v in {"GDAL_HTTP_TIMEOUT": "60", "GDAL_HTTP_MAX_RETRY": "6", "GDAL_HTTP_RETRY_DELAY": "4",
             "GDAL_DISABLE_READDIR_ON_OPEN": "EMPTY_DIR", "VSI_CACHE": "TRUE",
             "CPL_VSIL_CURL_ALLOWED_EXTENSIONS": ".tif,.vrt", "GDAL_CACHEMAX": "512"}.items():
    gdal.SetConfigOption(k, v)

WIRE_BUFFER_GROUND_M = 75.0          # each side of an overhead line
DEM_MIN_VALID = 0.95                 # share of owned land with elevation, or the cell fails
SRS_3857 = osr.SpatialReference()
SRS_3857.ImportFromEPSG(3857)


class Grid:
    """The cell's working raster: whole z12 tiles, so cutting tiles is plain slicing."""

    def __init__(self, cell_id):
        self.cell = cell_id
        self.lat_s, self.lat_n, self.lon_w, self.lon_e = C.parse_cell(cell_id)
        self.x0, self.x1, self.y0, self.y1 = C.cell_tile_range(cell_id)
        self.xmin, self.ymin, self.xmax, self.ymax = C.tile_range_extent(self.x0, self.x1, self.y0, self.y1)
        self.W = (self.x1 - self.x0 + 1) * C.TILE
        self.H = (self.y1 - self.y0 + 1) * C.TILE
        assert self.W * self.H < 40_000_000, f"{cell_id}: grid too large ({self.W}x{self.H})"
        cx = self.xmin + (np.arange(self.W) + 0.5) * C.RES
        cy = self.ymax - (np.arange(self.H) + 0.5) * C.RES
        self.lon = cx / C.EARTH_R * 180.0 / math.pi
        self.lat = np.degrees(2.0 * np.arctan(np.exp(cy / C.EARTH_R)) - math.pi / 2.0)
        # Half-open: a pixel centre on a shared edge belongs to exactly one cell.
        self.owner = (((self.lat >= self.lat_s) & (self.lat < self.lat_n))[:, None]
                      & ((self.lon >= self.lon_w) & (self.lon < self.lon_e))[None, :])
        self.ground_res = C.RES * np.cos(np.radians(self.lat))          # metres per pixel, per row
        self.mid_ground_res = float(C.RES * math.cos(math.radians((self.lat_s + self.lat_n) / 2.0)))

    def gt(self, pad=0):
        return (self.xmin - pad * C.RES, C.RES, 0.0, self.ymax + pad * C.RES, 0.0, -C.RES)

    def mem(self, dtype=gdal.GDT_Byte, pad=0):
        ds = gdal.GetDriverByName("MEM").Create("", self.W + 2 * pad, self.H + 2 * pad, 1, dtype)
        ds.SetGeoTransform(self.gt(pad))
        ds.SetProjection(SRS_3857.ExportToWkt())
        return ds


def warp(g, src, alg, dtype, src_nodata=None, dst_nodata=None, pad=0):
    """Resample a raster onto the cell grid (optionally with a pad of pixels all round)."""
    ext = (g.xmin - pad * C.RES, g.ymin - pad * C.RES, g.xmax + pad * C.RES, g.ymax + pad * C.RES)
    opts = dict(format="MEM", outputBounds=ext, width=g.W + 2 * pad, height=g.H + 2 * pad,
                dstSRS="EPSG:3857", resampleAlg=alg, outputType=dtype, warpMemoryLimit=512 * 1024 * 1024)
    if src_nodata is not None:
        opts["srcNodata"] = src_nodata
    if dst_nodata is not None:
        opts["dstNodata"] = dst_nodata
    ds = gdal.Warp("", src, **opts)
    assert ds is not None, f"warp failed for {src}"
    arr = ds.GetRasterBand(1).ReadAsArray()
    assert arr.shape == (g.H + 2 * pad, g.W + 2 * pad), "warp: unexpected shape"
    return arr


def horn_slope_deg(dem, ground_res_rows):
    """Horn slope on a padded DEM (pad 1). Mercator is conformal, so one ground spacing per row
    serves both axes. Any NaN in a 3x3 window gives NaN (= unknown), never 0 (= flat)."""
    a, b, c = dem[:-2, :-2], dem[:-2, 1:-1], dem[:-2, 2:]
    d, f = dem[1:-1, :-2], dem[1:-1, 2:]
    g, h, i = dem[2:, :-2], dem[2:, 1:-1], dem[2:, 2:]
    s = (8.0 * ground_res_rows)[:, None]
    dzdx = ((c + 2.0 * f + i) - (a + 2.0 * d + g)) / s
    dzdy = ((g + 2.0 * h + i) - (a + 2.0 * b + c)) / s
    return np.degrees(np.arctan(np.hypot(dzdx, dzdy)))


DEM_URL = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1/TIFF/current/{c}/USGS_1_{c}.tif"


def fetch_dem(cell_id, dest):
    """The cell's own 3DEP 1 arc-second COG, downloaded whole (~45 MB) and deleted after use.

    Streaming it through GDAL's /vsicurl (via the national VRT) measured ~40 KB/s and died on a
    truncated tile; the same bucket serves curl at 7-15 MB/s. The tile overlaps its neighbours by
    6 pixels, which covers the 1-pixel pad slope needs at the cell's own edges."""
    url = DEM_URL.format(c=cell_id)
    for attempt in (1, 2, 3):                                       # bounded: three tries
        rc = subprocess.run(["curl", "-fsS", "--retry", "3", "--retry-delay", "3", "--connect-timeout", "30",
                             "--max-time", "600", "-o", dest, url], capture_output=True, text=True)
        if rc.returncode == 0 and os.path.getsize(dest) > 10_000:      # a sea tile is tiny; Checksum proves it
            try:
                ds = gdal.Open(dest)
                ds.GetRasterBand(1).Checksum()        # decodes every block: catches truncation, even
                return True                           # in a tile that is mostly sea (no valid pixels)
            except RuntimeError:
                pass
        if "404" in (rc.stderr or ""):
            return False
        time.sleep(5 * attempt)
    return False


def read_dem(g, land):
    """Elevation on the cell grid with a 1-pixel pad, and the share of owned land it covers."""
    tmp = os.path.join(C.CELLS, f"_dem_{g.cell}_{os.getpid()}.tif")
    try:
        if not fetch_dem(g.cell, tmp):
            return None, 0.0
        dem = warp(g, tmp, "bilinear", gdal.GDT_Float32, src_nodata=-999999, dst_nodata=float("nan"), pad=1)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)                                          # terrain is never kept locally
    frac = float(np.isfinite(dem[1:-1, 1:-1])[land].mean()) if land.any() else 1.0
    return dem, frac


def rasterize(g, gpkg, all_touched=True):
    ds_src = ogr.Open(gpkg)
    assert ds_src is not None, f"cannot open {gpkg}"
    lyr = ds_src.GetLayer(0)
    pad = 400.0
    lyr.SetSpatialFilterRect(g.xmin - pad, g.ymin - pad, g.xmax + pad, g.ymax + pad)
    out = g.mem()
    opts = ["ALL_TOUCHED=TRUE"] if all_touched else []
    gdal.RasterizeLayer(out, [1], lyr, burn_values=[1], options=opts)
    return out.GetRasterBand(1).ReadAsArray() > 0


def dilate(mask, r):
    """Disc dilation by r pixels (small r), zero-filled at the edges."""
    assert 0 <= r <= 12, "dilate: radius out of range"
    out = mask.copy()
    H, W = mask.shape
    for dy in range(-r, r + 1):                                     # bounded by r
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy > r * r or (dx == 0 and dy == 0):
                continue
            ys, yd = (slice(0, H - dy), slice(dy, H)) if dy >= 0 else (slice(-dy, H), slice(0, H + dy))
            xs, xd = (slice(0, W - dx), slice(dx, W)) if dx >= 0 else (slice(-dx, W), slice(0, W + dx))
            out[yd, xd] |= mask[ys, xs]
    return out


def stamp(target, g, xs, ys, rs, value, mode="or"):
    """Discs at Mercator points (radius in Mercator metres): OR `value` into target, or clear it."""
    H, W = target.shape
    cols, rows, rad = (xs - g.xmin) / C.RES - 0.5, (g.ymax - ys) / C.RES - 0.5, rs / C.RES
    for cx, cy, r in zip(cols, rows, rad):                          # bounded by the points given
        r0, r1 = int(max(0, math.floor(cy - r))), int(min(H - 1, math.ceil(cy + r)))
        c0, c1 = int(max(0, math.floor(cx - r))), int(min(W - 1, math.ceil(cx + r)))
        if r0 > r1 or c0 > c1:
            continue
        yy, xx = np.ogrid[r0:r1 + 1, c0:c1 + 1]
        disc = (yy - cy) ** 2 + (xx - cx) ** 2 <= r * r
        if mode == "or":
            target[r0:r1 + 1, c0:c1 + 1][disc] |= value
        else:
            target[r0:r1 + 1, c0:c1 + 1][disc] &= np.uint8(~value & 0xFF)


T = {}


def reasons(g, inputs):
    """The mask (uint8 bits) and slope (u8, 0.5-degree steps, 255 unknown) for the cell grid."""
    nlcd = warp(g, inputs["nlcd"], "near", gdal.GDT_Byte, dst_nodata=C.NLCD_NODATA)
    T["nlcd"] = time.time()
    land = g.owner & (nlcd != C.NLCD_NODATA) & (nlcd != 0)
    if not land.any():
        return None, None, {"status": "empty", "reason": "no land cover here (outside CONUS)"}
    mask = np.zeros((g.H, g.W), np.uint8)
    mask[np.isin(nlcd, C.NLCD_WATER)] |= C.WATER
    mask[np.isin(nlcd, C.NLCD_DEVELOPED)] |= C.DEVELOPED
    mask[np.isin(nlcd, C.NLCD_TREES)] |= C.TREES
    cdl = warp(g, inputs["cdl"], "near", gdal.GDT_Byte, dst_nodata=0)
    crops = float((nlcd[land] == 82).mean())
    cdl_seen = float((cdl[land] != 0).mean())
    if crops > 0.01 and cdl_seen == 0.0:
        return None, None, {"status": "failed", "reason": f"CDL read nothing over {crops:.1%} cropland"}
    mask[np.isin(cdl, C.CDL_ORCHARD)] |= C.ORCHARD
    T["cdl"] = time.time()
    # Coverage is measured over DRY land: 3DEP has no elevation over open water, and counting the
    # water pixels failed every coastal cell (n29w090: 91% "coverage" of mostly marsh and Gulf).
    dem, dem_valid = read_dem(g, land & (nlcd != 11))
    T["dem"] = time.time()
    if dem is None or dem_valid < DEM_MIN_VALID:
        return None, None, {"status": "failed", "reason": f"elevation covers only {dem_valid:.1%} of land"}
    slope = horn_slope_deg(dem, g.ground_res)
    slope_u8 = np.where(np.isfinite(slope), np.clip(np.rint(slope / C.SLOPE_STEP_DEG), 0, 254),
                        C.SLOPE_UNKNOWN).astype(np.uint8)
    T["slope"] = time.time()
    hazards(g, mask)
    T["hazards"] = time.time()
    exempt_runways(g, mask, slope_u8)
    mask[~g.owner] = 0
    slope_u8[~g.owner] = 0
    T["runways"] = time.time()
    stats = {"land_px": int(land.sum()), "dem_valid": round(dem_valid, 4),
             "cdl_seen": round(cdl_seen, 4), "fractions": fractions(mask, slope, land)}
    return mask, slope_u8, stats


def hazards(g, mask):
    lines = rasterize(g, os.path.join(C.SHARED, "lines_3857.gpkg"))
    r_px = int(math.ceil(WIRE_BUFFER_GROUND_M / g.mid_ground_res))
    mask[dilate(lines, r_px)] |= C.WIRES
    mask[rasterize(g, os.path.join(C.SHARED, "solar_3857.gpkg"))] |= C.SOLAR
    pts = _points()
    pad = 2000.0
    sel = ((pts["x"] >= g.xmin - pad) & (pts["x"] <= g.xmax + pad)
           & (pts["y"] >= g.ymin - pad) & (pts["y"] <= g.ymax + pad))
    for bit in (C.WIRES, C.OBSTACLE, C.SOLAR):                       # bounded: three reasons
        k = sel & (pts["bit"] == bit)
        stamp(mask, g, pts["x"][k], pts["y"][k], pts["r"][k], np.uint8(bit))


def exempt_runways(g, mask, slope_u8):
    rect = rasterize(g, os.path.join(C.SHARED, "runways_3857.gpkg"))
    mask[rect] = 0
    slope_u8[rect] = 0
    pts = _points()
    pad = 3000.0
    k = ((pts["disc_x"] >= g.xmin - pad) & (pts["disc_x"] <= g.xmax + pad)
         & (pts["disc_y"] >= g.ymin - pad) & (pts["disc_y"] <= g.ymax + pad))
    stamp(mask, g, pts["disc_x"][k], pts["disc_y"][k], pts["disc_r"][k], np.uint8(C.DEVELOPED), mode="clear")


_PTS = {}


def _points():
    if not _PTS:
        with np.load(os.path.join(C.SHARED, "points.npz")) as z:
            _PTS.update({k: z[k] for k in z.files})
    return _PTS


def fractions(mask, slope, land):
    n = max(1, int(land.sum()))
    out = {name: round(float(((mask & bit) != 0)[land].sum()) / n, 4) for bit, name in C.BIT_NAMES.items()
           if bit != C.STEEP}
    for t in (8, 10, 12):
        out[f"slope_gt_{t}"] = round(float((np.nan_to_num(slope, nan=0.0) > t)[land].sum()) / n, 4)
    return out


def write_tiles(g, mask, slope_u8, path):
    """Every z12 tile that holds an owned pixel: mask + slope blobs. Returns the tile count."""
    tmp = path + ".part"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.execute("CREATE TABLE tiles (x INTEGER, y INTEGER, mask BLOB, slope BLOB, PRIMARY KEY (x, y))")
    n = 0
    for ty in range(g.y0, g.y1 + 1):                                # bounded by the cell's tiles
        for tx in range(g.x0, g.x1 + 1):
            r, c = (ty - g.y0) * C.TILE, (tx - g.x0) * C.TILE
            if not g.owner[r:r + C.TILE, c:c + C.TILE].any():
                continue
            m = np.ascontiguousarray(mask[r:r + C.TILE, c:c + C.TILE])
            sl = np.ascontiguousarray(slope_u8[r:r + C.TILE, c:c + C.TILE])
            mb, sb = C.pack_tile(m), C.pack_tile(sl)
            assert np.array_equal(C.unpack_tile(mb), m), "tile round-trip failed"
            db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (tx, ty, mb, sb))
            n += 1
    db.commit()
    db.close()
    os.replace(tmp, path)
    return n


def build(cell_id):
    t0 = time.time()
    os.makedirs(C.CELLS, exist_ok=True)
    with open(os.path.join(C.SHARED, "inputs.json")) as f:
        inputs = json.load(f)
    g = Grid(cell_id)
    mask, slope_u8, stats = reasons(g, inputs)
    receipt = {"cell": cell_id, "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if mask is None:
        receipt.update(stats)
    else:
        receipt.update(stats)
        receipt["tiles"] = write_tiles(g, mask, slope_u8, os.path.join(C.CELLS, f"{cell_id}.sqlite"))
        receipt["status"] = "ok"
    receipt["seconds"] = round(time.time() - t0, 1)
    marks, prev = {}, t0
    for k in ("nlcd", "cdl", "dem", "slope", "hazards", "runways"):         # bounded: six stages
        if k in T:
            marks[k], prev = round(T[k] - prev, 1), T[k]
    receipt["stage_seconds"] = marks
    with open(os.path.join(C.CELLS, f"{cell_id}.json"), "w") as f:
        json.dump(receipt, f)
    return receipt


if __name__ == "__main__":
    assert len(sys.argv) == 2, "usage: cell.py <cell id>"
    r = build(sys.argv[1])
    print(json.dumps(r))
    sys.exit(0 if r["status"] in ("ok", "empty") else 2)
