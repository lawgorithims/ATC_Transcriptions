#!/usr/bin/env python3
"""build_terrain_relief.py — bake CommSight's bundled dark terrain-relief base ("Dark (minimal)").

WHAT IT MAKES
    Resources/basemap/terrain_base.mbtiles — WebP shaded-relief tiles, z0-z8, CONUS, served by the
    loopback tile server at /base/terrain/{z}/{x}/{y} under the decluttered night map mode.

WHY PRE-BAKED, NOT A LIVE HILLSHADE LAYER
    MapLibre ships MLNHillshadeStyleLayer / MLNRasterDEMSource / MLNColorReliefStyleLayer, and they
    are compiled into our xcframework — but CommSight renders on a GLOBE, and the fork's globe port
    never reached those render paths (hillshade_layer_tweaker.cpp still emits a plain Mercator tile
    matrix). A hillshade layer would draw as unsubdivided flat quads on the sphere. The RASTER path
    IS globe-correct, so relief ships as ordinary pixels — no fork work, offline by construction, and
    zero runtime DEM cost on a battery-constrained EFB.

WHY NOT REUSE THE SHIPPED terrain_conus.bin
    That grid is a SAFETY artifact for the AGL readout: max-aggregated (ridges fat, valleys shallow)
    and sea-clamped, deliberately biased so AGL errs low. Shading it would render plateaus with cliff
    edges, and reshaping it risks disturbing the bytes the AGL reader mmaps. So this tool goes back to
    the same AWS source tiles and keeps its own artifact. See build_terrain_grid.py for that side.

DESIGN NOTES THAT MATTER IF YOU RETUNE IT
    * ONE WHOLE-CONUS MOSAIC, shaded once, then cut. Hillshading tile-by-tile leaves visible gradient
      discontinuities at every tile border (the gradient at an edge needs the neighbour's pixels).
      Mosaic-then-cut makes seams impossible rather than merely unlikely.
    * MULTIDIRECTIONAL shade (Mark 1992, as GDAL does it): four azimuths combined with sin^2 weights.
      A single sun azimuth throws hard black shadows that fight the route overlay; this stays soft.
    * TRANSPARENT OCEAN (alpha 0 at or below sea level). An opaque sea would print the bbox as a
      visible rectangle against the themed background, and the water inside coverage would not match
      the water outside it. Transparent lets the app's background + Natural Earth land silhouette read
      through, so the mode looks the same everywhere and only the RELIEF is regional.
    * ALPHA FEATHER at the bbox land edges, so relief fades out across the Canada/Mexico border
      instead of ending on a ruler-straight line.
    * PREMULTIPLIED downsampling for the pyramid: averaging unpremultiplied RGBA halos the coastline
      with bright fringes where transparent pixels contribute color.

USAGE
    python3 Tools/build_terrain_relief.py --fetch          # cache source tiles (resumable, ~1075 tiles)
    python3 Tools/build_terrain_relief.py --preview p.png  # eyeball the palette before a full bake
    python3 Tools/build_terrain_relief.py --bake           # write the mbtiles
    python3 Tools/build_terrain_relief.py --verify         # inspect an existing pack
    ... --fetch --bake --verify                            # or all three in one run

Deterministic: with the tile cache populated the bake is a pure function of it. Resumable: --fetch
skips tiles already cached, so an interrupted run is re-runnable and never re-downloads.
"""

import argparse
import concurrent.futures as futures
import math
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zlib

try:
    import numpy as np
except ImportError:                                          # pragma: no cover - dev environment
    sys.exit("numpy is required: python3 -m pip install numpy")

# ---------------------------------------------------------------- configuration

# CONUS plus the border margin a US EFB actually flies in — matches build_terrain_grid.py.
LAT_MIN, LAT_MAX = 24.0, 50.0
LON_MIN, LON_MAX = -125.0, -66.0

SRC_ZOOM = 8              # ~600 m/px — the finest the AWS terrarium cache is fetched at
# z8 is the finest level the cached source supports honestly (SRC_ZOOM is 8), and it is where the
# relief stops softening under the enroute zooms a pilot actually flies at. Going deeper would be
# invention, not detail.
MAX_ZOOM = 8
TILE = 256
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
MAX_TILE_RETRIES = 3
MIN_COVERAGE = 0.99       # refuse to bake a pack with visible holes
FEATHER_PX = 64           # mosaic-edge alpha ramp, in source pixels
WEBP_QUALITY = "75"
WEBP_ALPHA_QUALITY = "90"

CACHE_DIR = os.path.expanduser("~/CommSight/terrain-relief-build/raw")
OUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "ATCTranscribe", "Resources", "basemap", "terrain_base.mbtiles")

PALETTE_ID = "smartdark-v3"
# Elevation -> color ramp for the night base. Interpolated in sqrt(height) so the lowlands stay
# recessive while the ranges keep separation all the way up.
#
# WHY v2 IS BRIGHTER THAN v1, AND BY HOW MUCH. v1 was measured against the surfaces it sits beside and
# was wrong in a way that is arithmetic rather than taste. Relative luminance (Rec. 709) of what the
# pilot actually saw: sea #0A0C10 = 11.9, the Natural Earth land silhouette #12161C = 21.6, and v1's
# sea-level land 13.9 x 0.91 shade = 12.6. So CONUS lowlands rendered DARKER than the land silhouette
# around them and all but identical to the OCEAN — the coastline stopped reading, and "everything is a
# black void" was a literal description. Over the Colorado Rockies a shipped z6 tile measured luminance
# 23-40 (median 28) against that 11.9 background: a contrast ratio of about 1.16:1, which is nothing.
#
# v2 pins sea-level land just ABOVE the land silhouette so CONUS is continuous with its neighbours, and
# opens the range upward so mountains carry roughly 2.6:1 against the background — visible, but still
# well under the amber route (#FF9F1C, luminance 170), which must stay the brightest thing on the map.
# (metres, (r, g, b), approximate luminance)
RAMP = [
    (0,    (0x16, 0x19, 0x1E)),   # 24.6 — sits just above the land silhouette, not below it
    (500,  (0x20, 0x22, 0x25)),   # 33.7 — neutral; a blue cast here would read as water, not plains
    (1500, (0x3A, 0x35, 0x2D)),   # 53.4 — the umber starts where there is real terrain to show
    (3000, (0x5E, 0x55, 0x44)),   # 85.6
    (4400, (0x7C, 0x6E, 0x56)),   # 111.0 — sunlit peaks reach ~147, the route still owns the map
]
# Hillshade is a MULTIPLIER on the ramp. v1 compressed it into 0.75-1.06 — a 1.41x ratio between deepest
# shadow and brightest sun — which is why the relief read as a soft STAIN rather than as terrain: the
# ramp carried the elevation but the shading carried almost no shape. 0.55-1.32 is a 2.4x ratio, so
# ridges and valleys separate, and the recentring below still keeps flat ground off the highlight.
SHADE_LO, SHADE_HI = 0.55, 1.32
# The raw multidirectional shade this DEM actually produces, measured over all 1075 cached source
# tiles: it never reaches 1.0, so the mapping has to be pivoted against what occurs rather than
# against the theoretical range. See multidirectional_shade().
SHADE_S_MIN = 0.25
SHADE_S_MAX = 0.89
SHADE_AZIMUTHS_DEG = (225.0, 270.0, 315.0, 360.0)   # Mark 1992 multidirectional set
SHADE_ALTITUDE_DEG = 45.0
# Vertical exaggeration. 1.6 was chosen when the shade range was so compressed that more exaggeration
# had nowhere to go; with the pivot above it buys real separation in low country (the Appalachians and
# the Ouachitas both read now) at the cost of a fraction of a per cent of pixels clipping to full shadow
# in the steepest Rockies terrain.
Z_FACTOR = 2.4


# ---------------------------------------------------------------- PNG decode (dependency-free)

def decode_png_rgb(blob):
    """Decode an 8-bit non-interlaced RGB/RGBA PNG to a (h, w, 3) uint8 array.

    Pillow is not installed in the repo venvs, and this only needs the subset the AWS terrarium tiles
    actually use — anything else raises rather than guessing. (Same decoder as build_terrain_grid.py;
    duplicated deliberately so that safety-critical tool has no new dependency on this cosmetic one.)
    """
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    width = height = None
    bitdepth = colortype = interlace = None
    idat = bytearray()
    pos = 8
    while pos < len(blob):
        (length,) = struct.unpack(">I", blob[pos:pos + 4])
        ctype = blob[pos + 4:pos + 8]
        data = blob[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bitdepth, colortype, _, _, interlace = struct.unpack(">IIBBBBB", data)
        elif ctype == b"IDAT":
            idat += data
        elif ctype == b"IEND":
            break
    if bitdepth != 8 or colortype not in (2, 6) or interlace != 0:
        raise ValueError(f"unsupported PNG (depth={bitdepth} color={colortype} interlace={interlace})")

    channels = 3 if colortype == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = np.empty((height, stride), dtype=np.uint8)
    prev = np.zeros(stride, dtype=np.uint8)
    src = 0
    for row in range(height):                                   # bounded by the image height
        ftype = raw[src]
        src += 1
        line = np.frombuffer(raw[src:src + stride], dtype=np.uint8).copy()
        src += stride
        if ftype == 0:
            cur = line
        elif ftype == 1:                                        # Sub
            cur = line
            for i in range(channels, stride):
                cur[i] = (int(cur[i]) + int(cur[i - channels])) & 0xFF
        elif ftype == 2:                                        # Up
            cur = (line.astype(np.uint16) + prev.astype(np.uint16)).astype(np.uint8)
        elif ftype == 3:                                        # Average
            cur = line
            for i in range(stride):
                left = int(cur[i - channels]) if i >= channels else 0
                cur[i] = (int(cur[i]) + ((left + int(prev[i])) >> 1)) & 0xFF
        elif ftype == 4:                                        # Paeth
            cur = line
            for i in range(stride):
                a = int(cur[i - channels]) if i >= channels else 0
                b = int(prev[i])
                c = int(prev[i - channels]) if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (int(cur[i]) + pred) & 0xFF
        else:
            raise ValueError(f"bad PNG filter {ftype}")
        out[row] = cur
        prev = cur
    return out.reshape(height, width, channels)[:, :, :3]


def encode_png_rgba(arr):
    """Minimal RGBA PNG encoder (filter 0), for handing tiles to cwebp and for --preview."""
    h, w = arr.shape[:2]
    raw = bytearray()
    for row in range(h):                                        # bounded by the image height
        raw.append(0)
        raw += arr[row].tobytes()

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


# ---------------------------------------------------------------- tiles / geo

def tile_range(zoom, lat_min=LAT_MIN, lat_max=LAT_MAX, lon_min=LON_MIN, lon_max=LON_MAX):
    """Inclusive Web-Mercator tile index bounds covering the bbox: (x0, x1, y0, y1)."""
    n = 2 ** zoom

    def xtile(lon):
        return min(n - 1, max(0, int((lon + 180.0) / 360.0 * n)))

    def ytile(lat):
        r = math.radians(lat)
        return min(n - 1, max(0, int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * n)))

    return xtile(lon_min), xtile(lon_max), ytile(lat_max), ytile(lat_min)


def tile_lat_edges(zoom, y):
    """(north, south) latitude of tile row `y` — the mosaic's per-row ground scale needs it."""
    n = 2.0 ** zoom

    def lat(ty):
        return math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * ty / n))))

    return lat(y), lat(y + 1)


def fetch(url):
    last = None
    for _ in range(MAX_TILE_RETRIES):                           # bounded retries
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = e
    raise RuntimeError(f"failed after {MAX_TILE_RETRIES} tries: {url} ({last})")


def cache_path(z, x, y):
    return os.path.join(CACHE_DIR, str(z), str(x), f"{y}.png")


def fetch_all(workers=8):
    """Populate the source-tile cache. Skips what is already there, so re-runs are cheap."""
    x0, x1, y0, y1 = tile_range(SRC_ZOOM)
    want = [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    todo = [(x, y) for (x, y) in want if not os.path.exists(cache_path(SRC_ZOOM, x, y))]
    print(f"source z{SRC_ZOOM}: {len(want)} tiles in bbox, {len(todo)} to download")
    if not todo:
        return
    failed = []

    def one(xy):
        x, y = xy
        path = cache_path(SRC_ZOOM, x, y)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            blob = fetch(TILE_URL.format(z=SRC_ZOOM, x=x, y=y))
        except RuntimeError as e:
            return xy, e
        tmp = path + ".part"
        with open(tmp, "wb") as f:
            f.write(blob)
        os.replace(tmp, path)                                   # atomic: a killed run leaves no half tile
        return xy, None

    done = 0
    with futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for xy, err in ex.map(one, todo):
            done += 1
            if err:
                failed.append(xy)
            if done % 100 == 0 or done == len(todo):
                print(f"  {done}/{len(todo)}")
    if failed:
        print(f"  WARNING: {len(failed)} tiles failed permanently (they will render as holes)")


# ---------------------------------------------------------------- mosaic + shade

def build_mosaic():
    """Assemble the cached source tiles into one float32 elevation mosaic in metres.

    Returns (elev, y0, y1, coverage) where the mosaic spans source tile rows y0..y1 inclusive.
    Missing tiles are left as NaN and become transparent output.
    """
    x0, x1, y0, y1 = tile_range(SRC_ZOOM)
    w, h = (x1 - x0 + 1) * TILE, (y1 - y0 + 1) * TILE
    print(f"mosaic: {w} x {h} px ({w * h / 1e6:.1f} Mpx)")
    elev = np.full((h, w), np.nan, dtype=np.float32)
    present = 0
    total = (x1 - x0 + 1) * (y1 - y0 + 1)
    for ty in range(y0, y1 + 1):                                # bounded by the bbox tile range
        for tx in range(x0, x1 + 1):
            path = cache_path(SRC_ZOOM, tx, ty)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as f:
                rgb = decode_png_rgb(f.read()).astype(np.float32)
            # Terrarium: h = R*256 + G + B/256 - 32768
            tile = rgb[:, :, 0] * 256.0 + rgb[:, :, 1] + rgb[:, :, 2] / 256.0 - 32768.0
            r0, c0 = (ty - y0) * TILE, (tx - x0) * TILE
            elev[r0:r0 + TILE, c0:c0 + TILE] = tile
            present += 1
        print(f"  row {ty - y0 + 1}/{y1 - y0 + 1}", end="\r")
    coverage = present / float(total)
    print(f"\nmosaic coverage: {present}/{total} tiles ({coverage * 100:.1f}%)")
    return elev, y0, y1, coverage


def multidirectional_shade(elev, y0, y1):
    """Soft relief shading in [SHADE_LO, SHADE_HI], NaN-safe.

    Mercator is conformal, so one ground-resolution scalar per ROW is exact (no per-pixel Jacobian).
    """
    h, w = elev.shape
    filled = np.where(np.isnan(elev), 0.0, elev).astype(np.float32)

    # Per-row metres-per-pixel: the equatorial value times cos(latitude of that row).
    north, south = tile_lat_edges(SRC_ZOOM, y0)[0], tile_lat_edges(SRC_ZOOM, y1)[1]
    # Mercator y is linear in the projected coordinate, not in latitude — recover latitude per row.
    n = 2.0 ** SRC_ZOOM
    ty = (y0 * TILE + np.arange(h) + 0.5) / (n * TILE)
    lat = np.degrees(np.arctan(np.sinh(np.pi * (1.0 - 2.0 * ty)))).astype(np.float32)
    res = (2 * math.pi * 6378137.0 / (n * TILE)) * np.cos(np.radians(lat))
    res = np.maximum(res, 1e-3)[:, None]                        # metres per pixel, per row
    assert north > south, "mosaic latitude bounds inverted"

    dzdy, dzdx = np.gradient(filled)                            # per-pixel differences
    dzdx = (dzdx / res) * Z_FACTOR
    dzdy = (dzdy / res) * Z_FACTOR
    slope = np.arctan(np.hypot(dzdx, dzdy))
    # Screen aspect: y grows southward in image space, hence the sign on dzdy.
    aspect = np.arctan2(dzdy, -dzdx)

    zen = math.radians(90.0 - SHADE_ALTITUDE_DEG)
    acc = np.zeros_like(filled)
    wsum = 0.0
    for az_deg in SHADE_AZIMUTHS_DEG:                           # bounded (4 azimuths)
        az = math.radians(360.0 - az_deg + 90.0)                # compass -> math convention
        weight = math.sin(math.radians(az_deg)) ** 2 + 0.25     # Mark 1992, floored so none vanishes
        cosine = (math.cos(zen) * np.cos(slope)
                  + math.sin(zen) * np.sin(slope) * np.cos(az - aspect))
        acc += weight * np.clip(cosine, 0.0, 1.0)
        wsum += weight
    shade = acc / wsum                                          # 0..1; cos(zenith) on flat ground
    # Map raw shade onto the multiplier with an EXPLICIT PIVOT ON FLAT GROUND.
    #
    # The old mapping was `t = clip((shade - flat*0.64) / 0.5)`, which needed a raw shade of 0.9525 to
    # reach t = 1. Measured over the whole cached DEM the multidirectional shade never exceeds ~0.889,
    # so the top of the declared range was UNREACHABLE: a nominal SHADE_HI of 1.32 actually topped out
    # at 1.222, and the brightest twelve per cent of the range painted nothing at all. Flat ground also
    # landed wherever the arithmetic happened to put it (t = 0.509) rather than anywhere chosen.
    #
    # Pivoting instead: flat ground is pinned to a multiplier of exactly 1.0 (the ramp colour is then
    # what the ramp says it is), slopes falling away from the light interpolate down to SHADE_LO, and
    # slopes facing it interpolate up to SHADE_HI across the range that actually occurs. The endpoints
    # are measurements of this DEM, not guesses.
    flat = math.cos(math.radians(90.0 - SHADE_ALTITUDE_DEG))     # shade value on level ground
    assert SHADE_S_MIN < flat < SHADE_S_MAX, "shade pivot outside the observed range"
    below = SHADE_LO + (1.0 - SHADE_LO) * np.clip((shade - SHADE_S_MIN) / (flat - SHADE_S_MIN), 0.0, 1.0)
    above = 1.0 + (SHADE_HI - 1.0) * np.clip((shade - flat) / (SHADE_S_MAX - flat), 0.0, 1.0)
    out = np.where(shade <= flat, below, above)
    assert np.all(np.isfinite(out)), "shade produced non-finite values"
    assert float(out.min()) >= SHADE_LO - 1e-3, "shade fell below its floor"
    return out.astype(np.float32)


def colorize(elev, shade):
    """Elevation ramp times relief shading, with a transparent ocean. Returns (h, w, 4) uint8 RGBA."""
    h, w = elev.shape
    land = np.isfinite(elev) & (elev > 0.0)
    hgt = np.where(land, elev, 0.0).astype(np.float32)

    # Interpolate the ramp in sqrt(height): lowlands fade fast, ranges keep separation up high.
    stops = np.array([s[0] for s in RAMP], dtype=np.float32)
    keys = np.sqrt(np.maximum(stops, 0.0))
    x = np.sqrt(np.clip(hgt, 0.0, stops[-1]))
    rgb = np.empty((h, w, 3), dtype=np.float32)
    for ch in range(3):                                         # bounded (3 channels)
        vals = np.array([s[1][ch] for s in RAMP], dtype=np.float32)
        rgb[:, :, ch] = np.interp(x, keys, vals)
    rgb *= shade[:, :, None]

    out = np.zeros((h, w, 4), dtype=np.uint8)
    out[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    alpha = np.where(land, 255, 0).astype(np.float32)

    # Feather the bbox EDGES so relief dissolves into the vector land silhouette at the borders
    # instead of ending on a straight line (most visible along the Canada/Mexico frontier).
    if FEATHER_PX > 0:
        ramp = np.clip(np.arange(FEATHER_PX, dtype=np.float32) / float(FEATHER_PX), 0.0, 1.0)
        for axis in (0, 1):                                     # bounded (2 axes)
            n = alpha.shape[axis]
            prof = np.ones(n, dtype=np.float32)
            k = min(FEATHER_PX, n // 2)
            prof[:k] = ramp[:k]
            prof[n - k:] = ramp[:k][::-1]
            alpha *= prof[:, None] if axis == 0 else prof[None, :]

    out[:, :, 3] = np.clip(alpha, 0, 255).astype(np.uint8)
    # Premultiply now: every downsample below averages these, and averaging unpremultiplied RGBA
    # fringes the coastline with color bled in from fully transparent pixels.
    a = out[:, :, 3:4].astype(np.float32) / 255.0
    out[:, :, :3] = (out[:, :, :3].astype(np.float32) * a).astype(np.uint8)
    return out


def unpremultiply(tile):
    """Back to straight alpha for encoding (cwebp expects non-premultiplied RGBA)."""
    out = tile.copy()
    a = out[:, :, 3].astype(np.float32) / 255.0
    safe = np.maximum(a, 1e-6)[:, :, None]
    out[:, :, :3] = np.clip(out[:, :, :3].astype(np.float32) / safe, 0, 255).astype(np.uint8)
    out[:, :, :3][a <= 0.0] = 0
    return out


# ---------------------------------------------------------------- pyramid + mbtiles

def box_downsample(arr):
    """2x2 box reduce of an RGBA array (premultiplied), trimming an odd trailing row/column."""
    h, w = arr.shape[:2]
    h2, w2 = h - (h % 2), w - (w % 2)
    a = arr[:h2, :w2].astype(np.uint16)
    return ((a[0::2, 0::2] + a[0::2, 1::2] + a[1::2, 0::2] + a[1::2, 1::2] + 2) // 4).astype(np.uint8)


def encode_webp(tile_rgba):
    """PNG -> cwebp -> WebP bytes. WebP because every shipped base pack is `format=webp` and the
    loopback server passes those through to MapLibre byte-verbatim (no decode, no re-encode)."""
    with tempfile.TemporaryDirectory() as td:
        src, dst = os.path.join(td, "t.png"), os.path.join(td, "t.webp")
        with open(src, "wb") as f:
            f.write(encode_png_rgba(unpremultiply(tile_rgba)))
        subprocess.run(["cwebp", "-quiet", "-q", WEBP_QUALITY, "-alpha_q", WEBP_ALPHA_QUALITY,
                        "-m", "6", src, "-o", dst], check=True)
        with open(dst, "rb") as f:
            return f.read()


def write_mbtiles(levels, path):
    """Write the tile pyramid with the metadata rows the shipped bases use (MBTilesReader reads
    `format`/`minzoom`/`maxzoom`; the rest is provenance a human will want later)."""
    if os.path.exists(path):
        os.remove(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE tiles (zoom_level INTEGER NOT NULL,tile_column INTEGER NOT NULL,"
               "tile_row INTEGER NOT NULL,tile_data BLOB NOT NULL,"
               "UNIQUE (zoom_level, tile_column, tile_row) )")
    db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    total = 0
    for z in sorted(levels):                                    # bounded (z0..z7)
        for (x, y), blob in sorted(levels[z].items()):
            tms_y = (1 << z) - 1 - y                            # MBTiles rows count from the south
            db.execute("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)",
                       (z, x, tms_y, sqlite3.Binary(blob)))
            total += 1
        print(f"  z{z}: {len(levels[z])} tiles")
    meta = [
        ("format", "webp"),
        ("minzoom", "0"),
        ("maxzoom", str(MAX_ZOOM)),
        ("type", "baselayer"),
        ("version", "1"),
        ("bounds", f"{LON_MIN},{LAT_MIN},{LON_MAX},{LAT_MAX}"),
        ("name", "Dark terrain relief (CONUS)"),
        ("attribution", "AWS Open Data terrain-tiles (SRTM/NASADEM/3DEP/GMTED2010), public domain"),
        ("source_zoom", str(SRC_ZOOM)),
        ("palette", PALETTE_ID),
        ("builder", "Tools/build_terrain_relief.py"),
    ]
    db.executemany("INSERT INTO metadata VALUES (?,?)", meta)
    db.commit()
    db.close()
    size = os.path.getsize(path)
    print(f"wrote {total} tiles, {size / 1e6:.1f} MB -> {path}")
    return total, size


def bake(preview=None):
    elev, y0, y1, coverage = build_mosaic()
    if coverage < MIN_COVERAGE:
        sys.exit(f"coverage {coverage * 100:.1f}% below {MIN_COVERAGE * 100:.0f}% — run --fetch first")
    print("shading…")
    shade = multidirectional_shade(elev, y0, y1)
    print("colorizing…")
    rgba = colorize(elev, shade)
    del elev, shade

    if preview:
        step = max(1, rgba.shape[1] // 1600)
        with open(preview, "wb") as f:
            f.write(encode_png_rgba(unpremultiply(rgba[::step, ::step])))
        print(f"preview -> {preview} ({rgba.shape[1] // step} px wide)")

    x0, _, _, _ = tile_range(SRC_ZOOM)
    levels = {}
    # Reduce the source-resolution mosaic down to the finest OUTPUT level. At MAX_ZOOM == SRC_ZOOM that
    # is no reduction at all (the mosaic is already the right scale); each level below it costs one 2x
    # box reduce. Writing this as a bounded loop rather than a single hardcoded call is what lets
    # MAX_ZOOM move without silently shifting the whole pyramid by a factor of two.
    assert SRC_ZOOM >= MAX_ZOOM, "MAX_ZOOM cannot exceed the source resolution — that would be invention"
    cur = rgba
    for _ in range(SRC_ZOOM - MAX_ZOOM):                        # bounded by SRC_ZOOM (rule 2)
        cur = box_downsample(cur)
    del rgba

    for z in range(MAX_ZOOM, -1, -1):                           # bounded (MAX_ZOOM..z0)
        tiles = {}
        h, w = cur.shape[:2]
        n = 1 << z
        # Where the mosaic's top-left corner sits in this zoom's GLOBAL pixel grid. The mosaic starts on
        # a z8 tile boundary, so at zoom z its origin is (x0, y0) * 256 / 2^(8-z) = (x0, y0) * 2^z —
        # always an integer, and generally NOT tile-aligned (a half-tile offset is normal). Deriving it
        # in closed form beats carrying an offset down the pyramid, which is easy to get subtly wrong and
        # would silently shift the relief away from the terrain it depicts.
        org_c, org_r = x0 * n, y0 * n
        assert org_c >= 0 and org_r >= 0, "mosaic origin must be non-negative"
        for ty in range(max(0, org_r // TILE), min(n, (org_r + h + TILE - 1) // TILE)):
            for tx in range(max(0, org_c // TILE), min(n, (org_c + w + TILE - 1) // TILE)):
                r0, c0 = ty * TILE - org_r, tx * TILE - org_c   # tile's top-left within the mosaic
                sr0, sc0 = max(0, r0), max(0, c0)
                sr1, sc1 = min(h, r0 + TILE), min(w, c0 + TILE)
                if sr1 <= sr0 or sc1 <= sc0:
                    continue
                tile = np.zeros((TILE, TILE, 4), dtype=np.uint8)
                tile[sr0 - r0:sr1 - r0, sc0 - c0:sc1 - c0] = cur[sr0:sr1, sc0:sc1]
                if not tile[:, :, 3].any():
                    continue                                    # fully transparent → don't ship it
                tiles[(tx, ty)] = encode_webp(tile)
        levels[z] = tiles
        print(f"  built z{z}: {len(tiles)} tiles")
        if z == 0:
            break
        cur = box_downsample(cur)

    return write_mbtiles(levels, os.path.abspath(OUT_PATH))


def verify(path):
    path = os.path.abspath(path)
    if not os.path.exists(path):
        sys.exit(f"no pack at {path}")
    db = sqlite3.connect(path)
    meta = dict(db.execute("SELECT name, value FROM metadata").fetchall())
    print(f"pack: {path} ({os.path.getsize(path) / 1e6:.1f} MB)")
    for k in ("format", "minzoom", "maxzoom", "bounds", "palette", "source_zoom"):
        print(f"  {k} = {meta.get(k)}")
    rows = db.execute("SELECT zoom_level, count(*) FROM tiles GROUP BY 1 ORDER BY 1").fetchall()
    for z, c in rows:
        print(f"  z{z}: {c} tiles")
    if meta.get("format") != "webp":
        sys.exit("format is not webp — the server's passthrough expects webp")
    # GEOGRAPHIC ALIGNMENT. The failure this catches is the nasty one: a pyramid offset error puts
    # perfectly good relief in the wrong place, which on a moving map means shaded terrain where there
    # is none. Sample known land and known ocean points and demand the alpha channel agree, then demand
    # high terrain actually renders brighter than the plains.
    def sample(lat, lon, z=MAX_ZOOM):
        n = 1 << z
        fx = (lon + 180.0) / 360.0 * n
        fy = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
        tx, ty = int(fx), int(fy)
        row = db.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? "
                         "AND tile_row=?", (z, tx, n - 1 - ty)).fetchone()
        if not row:
            return None, None, f"z{z}/{tx}/{ty} absent"
        if row[0][:4] != b"RIFF":
            sys.exit(f"tile z{z}/{tx}/{ty} is not WebP")
        with tempfile.TemporaryDirectory() as td:
            src, dst = os.path.join(td, "t.webp"), os.path.join(td, "t.pam")
            with open(src, "wb") as f:
                f.write(row[0])
            subprocess.run(["dwebp", "-quiet", "-pam", src, "-o", dst], check=True)
            with open(dst, "rb") as f:
                blob = f.read()
        end = blob.index(b"ENDHDR\n") + 7
        hdr = blob[:end].decode()

        def field(k):
            return int([l for l in hdr.split("\n") if l.startswith(k)][0].split()[1])

        w, h, d = field("WIDTH"), field("HEIGHT"), field("DEPTH")
        arr = np.frombuffer(blob[end:], dtype=np.uint8).reshape(h, w, d)
        ox, oy = int((fx - tx) * w), int((fy - ty) * h)
        alpha = int(arr[oy, ox, 3]) if d == 4 else 255
        luma = float(arr[oy, ox, :3].mean())
        return alpha, luma, f"z{z}/{tx}/{ty} px({ox},{oy})"

    # (name, lat, lon, expect_land)
    checks = [("Denver CO", 39.74, -104.99, True), ("Pikes Peak", 38.84, -105.04, True),
              ("Wichita KS", 37.69, -97.34, True), ("Miami FL", 25.78, -80.20, True),
              ("Atlantic off NC", 35.00, -74.00, False), ("Gulf of Mexico", 26.00, -90.00, False),
              ("Pacific off CA", 34.00, -124.50, False)]
    bad = []
    for name, lat, lon, want_land in checks:                    # bounded (rule 2)
        alpha, _, where = sample(lat, lon)
        is_land = alpha is not None and alpha > 32               # absent tile == transparent == water
        if is_land != want_land:
            bad.append(f"{name} ({where}): alpha={alpha}, expected {'land' if want_land else 'water'}")
    if bad:
        sys.exit("ALIGNMENT FAILED:\n  " + "\n  ".join(bad))
    _, high, _ = sample(38.84, -105.04)
    _, low, _ = sample(37.69, -97.34)
    if not (high and low and high > low):
        sys.exit(f"relief inverted or flat: high-terrain luma {high} vs plains {low}")
    print(f"  alignment: {len(checks)}/{len(checks)} land/water samples correct")
    print(f"  relief: high-terrain luma {high:.1f} > plains {low:.1f}")
    db.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch", action="store_true", help="download/refresh the source tile cache")
    ap.add_argument("--bake", action="store_true", help="build the mbtiles from the cache")
    ap.add_argument("--verify", action="store_true", help="inspect the built pack")
    ap.add_argument("--preview", metavar="PNG", help="also write a downsampled full-CONUS preview")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    if not (args.fetch or args.bake or args.verify or args.preview):
        ap.error("nothing to do: pass --fetch, --bake, --verify and/or --preview")

    if not shutil.which("cwebp") and (args.bake or args.preview):
        sys.exit("cwebp not found (brew install webp)")
    if args.fetch:
        fetch_all(workers=args.workers)
    if args.bake or args.preview:
        bake(preview=args.preview)
    if args.verify:
        verify(OUT_PATH)


if __name__ == "__main__":
    main()
