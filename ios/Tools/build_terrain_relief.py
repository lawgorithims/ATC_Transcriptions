#!/usr/bin/env python3
"""build_terrain_relief.py — bake CommSight's bundled dark terrain-relief base ("Dark (minimal)").

WHAT IT MAKES
    Resources/basemap/terrain_base.mbtiles — WebP shaded-relief tiles, z0-z10, CONUS, served by the
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
    * BLOCKS WITH A HALO, not tile-by-tile. Hillshading a tile in isolation leaves a visible gradient
      discontinuity at every border, because the gradient at an edge needs the neighbour's pixels — so
      each block is computed with a halo wider than every filter that reads neighbours, and its edge
      pixels come out identical to a whole-CONUS pass. (It WAS one whole-CONUS mosaic; at z10 that array
      is 4.5 GB, which is what forced the blocking.)
    * A SPARSE DEEP LEVEL. z9 and z10 are carried only where a tile holds at least SPARSE_RELIEF_M of
      relief; flat country is left to be magnified from its parent, which for flat country is
      indistinguishable. The loopback server fills the gap (MBTilesHTTPServer.ancestorPNG).
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

SRC_ZOOM = 10             # ~117 m/px at 40N — fine enough for a small hill beside a runway
# Matches SRC_ZOOM: every output level is real source data, never upsampled invention.
MAX_ZOOM = 10
TILE = 256
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
MAX_TILE_RETRIES = 3
MIN_COVERAGE = 0.99       # refuse to bake a pack with visible holes
FEATHER_PX = 64           # mosaic-edge alpha ramp, in source pixels
# The local-relief tint has far more contrast than the old absolute ramp, and q75 put visible 8x8
# blocking on ridge lines — which a pilot sees MAGNIFIED, because MapLibre blows the deepest level up at
# approach zooms. That magnification is 16x when the pack stops at z8 but only 4x when it reaches z10,
# so the deeper pack does not need to carry as much quality to survive the same viewing.
WEBP_QUALITY = "88"
WEBP_ALPHA_QUALITY = "95"

CACHE_DIR = os.path.expanduser("~/CommSight/terrain-relief-build/raw")
OUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "ATCTranscribe", "Resources", "basemap", "terrain_base.mbtiles")

PALETTE_ID = "smartdark-v4"
# TWO THINGS WERE WRONG, AND THEY WERE FOUND IN THAT ORDER.
#
# First, AMPLITUDE. v1 was measured against the surfaces it sits beside: sea #0A0C10 has relative
# luminance 11.9 and the land silhouette #12161C has 21.6, while v1 rendered sea-level CONUS at 12.6 —
# darker than the land around it and all but identical to the ocean. Over the Rockies it measured 23-40
# against that background, a contrast ratio of 1.16:1. "A black void" was a literal description.
#
# Second, and this is the one that matters more, THE WRONG QUESTION. Fixing the amplitude was verified
# against a whole-CONUS preview, which answers "is Colorado brighter than Kansas" — a question no
# approach depends on. Measured properly, at the airports a pilot actually flies into, an ABSOLUTE
# hypsometric ramp gave the entire local relief within 15 NM almost no tone at all: 18 luminance levels
# at Las Cruces for the 852 m of the Organ Mountains, 5 at Boston for 346 m, and about 3 for the 200 ft
# hill beside a runway. The palette was spending its whole range on which part of the country you were
# in. See `colorize` for what replaced it.
# Metres of LOCAL RELIEF (height above the smoothed regional baseline) -> colour. Negative is a valley
# floor, positive is ground standing above its surroundings. The span is chosen from what actually
# occurs within a terminal area rather than from CONUS: 300 m below to 900 m above covers the Organ
# Mountains at Las Cruces, the ridges around Butte, and the walls of the Roaring Fork valley at Aspen,
# and it gives the first 200 ft of a hill real tone instead of three luminance levels.
# (metres of local relief, (r, g, b), approximate luminance)
RAMP = [
    (-300, (0x10, 0x13, 0x18)),   # 18.0 — valley floors recede below the land silhouette
    (0,    (0x1E, 0x21, 0x26)),   # 32.0 — the local datum: level ground reads as level ground
    (150,  (0x33, 0x31, 0x2C)),   # 48.5 — a 500 ft rise is already unmistakable
    (400,  (0x50, 0x49, 0x3C)),   # 72.6
    (900,  (0x7C, 0x6E, 0x56)),   # 111.0 — sunlit tops reach ~147, the route still owns the map
]
# Radius of the smoothing that defines "its own surroundings". Expressed in KILOMETRES, not pixels, so
# it means the same thing at any SRC_ZOOM — roughly a terminal area. Wide enough that a mountain range
# is local relief rather than being averaged into its own baseline; narrow enough that the Great Plains
# stay flat.
BASELINE_RADIUS_KM = 45.0

# A tile is only carried at the DEEP levels when it SHOWS SOMETHING ITS PARENT DOES NOT.
#
# The obvious test — "does this tile hold at least N metres of relief" — turns out to be useless: a z10
# tile spans about 30 km, and almost nowhere in CONUS is flat to within 60 m over 30 km. The High
# Plains failed it too, so nothing was ever skipped. The question that matters is not how much terrain
# is in the tile but how much of it SURVIVES being halved: a long smooth slope looks identical at z9
# and z10, while a 200 ft hill does not. So the tile is rendered, reduced, magnified back, and kept
# only if the round trip loses more than a just-noticeable amount of luminance.
SPARSE_BELOW_ZOOM = 9          # z0..8 are dense; 9 and deeper are carried only where they add detail
SPARSE_JND_LUMA = 7.0          # a shade above the WebP q93 error floor, so this never chases noise

# MEASURED AND REJECTED: gating the deep level on proximity to an airport. It is the obvious idea —
# this resolution only matters on approach — but the US is so dense with airfields that even a 15 NM
# radius around PUBLIC aerodromes alone covers 61 % of CONUS, and a 30 NM radius covers 69 %. A filter
# that removes a third of the tiles is not worth a dependency on the airport table.

# Source tiles per side of one bake block. The whole-CONUS array does not fit in memory past z8, so the
# bake runs in blocks with a HALO wide enough for every filter that reads neighbours — which preserves
# the mosaic-then-cut guarantee (no seams) because each block's edge pixels are computed from real
# neighbouring data rather than from nothing.
BLOCK_TILES = 8
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

def metres_per_pixel(zoom, lat):
    """Ground resolution of one source pixel at this zoom and latitude."""
    assert zoom >= 0, "metres_per_pixel: negative zoom"
    return (2 * math.pi * 6378137.0 / (2 ** zoom * TILE)) * math.cos(math.radians(lat))


def baseline_radius_px():
    """The smoothing radius in SOURCE pixels at the middle of the bbox."""
    mid = (LAT_MIN + LAT_MAX) / 2.0
    r = int(round(BASELINE_RADIUS_KM * 1000.0 / metres_per_pixel(SRC_ZOOM, mid)))
    return max(4, r)


def block_halo_px():
    """Halo each block carries so every neighbour-reading filter sees real data at its edges."""
    return baseline_radius_px() + 8      # +8 covers the gradient and any rounding

def tile_range(zoom, lat_min=None, lat_max=None, lon_min=None, lon_max=None):
    """Inclusive Web-Mercator tile index bounds covering the bbox: (x0, x1, y0, y1)."""
    # Read the module globals at CALL time, not as default arguments — defaults are bound at import, so
    # a caller that narrows the bbox (a test bake over one airport) would silently get the whole of CONUS.
    lat_min = LAT_MIN if lat_min is None else lat_min
    lat_max = LAT_MAX if lat_max is None else lat_max
    lon_min = LON_MIN if lon_min is None else lon_min
    lon_max = LON_MAX if lon_max is None else lon_max
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


def regional_baseline(elev, radius_px):
    """The terrain with its LOCAL detail removed — a heavy box blur, NaN-aware.

    Two passes of a separable box filter via cumulative sums, which is O(n) and exact. Ocean is NaN and
    must not drag coastal land down, so the sums carry a validity mask and divide by the count of REAL
    samples rather than by the window size.
    """
    assert radius_px >= 1, "regional_baseline: degenerate radius"
    valid = np.isfinite(elev)
    filled = np.where(valid, elev, 0.0).astype(np.float64)
    weight = valid.astype(np.float64)

    def box(a, r):
        # Cumulative-sum box filter along both axes, edges clamped.
        pad = np.pad(a, ((r + 1, r), (0, 0)), mode="edge")
        cs = np.cumsum(pad, axis=0)
        a = cs[2 * r + 1:] - cs[:-(2 * r + 1)]
        pad = np.pad(a, ((0, 0), (r + 1, r)), mode="edge")
        cs = np.cumsum(pad, axis=1)
        return cs[:, 2 * r + 1:] - cs[:, :-(2 * r + 1)]

    s = box(filled, radius_px)
    n = box(weight, radius_px)
    out = np.where(n > 0.5, s / np.maximum(n, 1e-6), 0.0)
    assert out.shape == elev.shape, "regional_baseline: shape changed"
    return out.astype(np.float32)


def colorize(elev, shade, abs_origin=None, full_shape=None):
    """LOCAL relief ramp times relief shading, with a transparent ocean. Returns (h, w, 4) uint8 RGBA.

    WHY THE TINT IS LOCAL AND NOT ABSOLUTE HEIGHT. An absolute hypsometric ramp answers "how high above
    the sea is this?", which is a question about Colorado versus Kansas. A pilot is asking a different
    one: is there a hill beside this runway, is there a peak in the circling area. Measured on the
    shipped absolute ramp, the whole local relief within 15 NM of a field mapped to almost no tone at
    all — 18 luminance levels at Las Cruces (852 m of relief, the Organ Mountains), 5 at Boston (346 m),
    and about 3 for the 200 ft hill next to a runway that started this. The palette was spending its
    entire range on the difference between one part of the country and another, which is a difference no
    approach depends on.

    So the ramp is driven by the RESIDUAL — the terrain minus a heavily smoothed version of itself.
    What is left is exactly "how far does this stand above its own surroundings", which is the same
    question at Aspen and at Boston, and it means every airport gets the full palette instead of
    whichever slice of it its region happens to occupy. High country still reads as high country because
    the hillshade and the coastline do that work; what changes is that the LOCAL shape now carries the
    tone.
    """
    h, w = elev.shape
    land = np.isfinite(elev) & (elev > 0.0)
    hgt = np.where(land, elev, 0.0).astype(np.float32)

    baseline = regional_baseline(np.where(land, elev, np.nan), baseline_radius_px())
    relief = np.where(land, hgt - baseline, 0.0)

    # Interpolate in sqrt(relief) above the baseline so the first couple of hundred feet — the hill by
    # the runway — earns tone quickly, while a 3,000 ft ridge still has somewhere left to go.
    stops = np.array([s[0] for s in RAMP], dtype=np.float32)
    keys = np.sign(stops) * np.sqrt(np.abs(stops))
    x = np.clip(relief, stops[0], stops[-1])
    x = np.sign(x) * np.sqrt(np.abs(x))
    rgb = np.empty((h, w, 3), dtype=np.float32)
    for ch in range(3):                                         # bounded (3 channels)
        vals = np.array([s[1][ch] for s in RAMP], dtype=np.float32)
        rgb[:, :, ch] = np.interp(x, keys, vals)
    rgb *= shade[:, :, None]

    out = np.zeros((h, w, 4), dtype=np.uint8)
    out[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    alpha = np.where(land, 255, 0).astype(np.float32)

    # Feather the bbox EDGES so relief dissolves into the vector land silhouette at the borders
    # instead of ending on a straight line (most visible along the Canada/Mexico frontier). Computed
    # from ABSOLUTE position, because the bake runs in blocks and a block edge in the middle of CONUS
    # must not be feathered — that would print the block grid onto the map.
    if FEATHER_PX > 0 and abs_origin is not None and full_shape is not None:
        r0, c0 = abs_origin
        H, W = full_shape
        for axis in (0, 1):                                     # bounded (2 axes)
            n = alpha.shape[axis]
            start = r0 if axis == 0 else c0
            total = H if axis == 0 else W
            idx = np.arange(n, dtype=np.float32) + float(start)
            d = np.minimum(idx, (total - 1) - idx)              # distance to the nearest bbox edge
            prof = np.clip(d / float(FEATHER_PX), 0.0, 1.0).astype(np.float32)
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


def load_dem_window(tx0, ty0, tx1, ty1):
    """Cached source tiles for the inclusive tile rect, as one float32 array in metres.

    Tiles outside the cached bbox are simply absent and stay NaN — which is correct for a halo that
    runs off the edge of coverage: the filters below count only real samples.
    """
    assert tx1 >= tx0 and ty1 >= ty0, "load_dem_window: inverted rect"
    w, h = (tx1 - tx0 + 1) * TILE, (ty1 - ty0 + 1) * TILE
    out = np.full((h, w), np.nan, dtype=np.float32)
    present = 0
    for ty in range(ty0, ty1 + 1):                              # bounded by the rect (rule 2)
        for tx in range(tx0, tx1 + 1):
            path = cache_path(SRC_ZOOM, tx, ty)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as f:
                rgb = decode_png_rgb(f.read()).astype(np.float32)
            # Terrarium: h = R*256 + G + B/256 - 32768
            out[(ty - ty0) * TILE:(ty - ty0 + 1) * TILE, (tx - tx0) * TILE:(tx - tx0 + 1) * TILE] = (
                rgb[:, :, 0] * 256.0 + rgb[:, :, 1] + rgb[:, :, 2] / 256.0 - 32768.0)
            present += 1
    return out, present


def tile_is_worth_carrying(tile_rgba):
    """Does this tile show anything its half-resolution parent would not?

    Reduce it 2x and magnify it straight back — that is exactly what the loopback server will serve if
    this tile is absent. Whatever the round trip destroys is the detail this level is adding.
    """
    assert tile_rgba.shape[0] == TILE and tile_rgba.shape[1] == TILE, "worth-carrying: not a tile"
    half = box_downsample(tile_rgba)
    back = np.repeat(np.repeat(half, 2, axis=0), 2, axis=1)
    a = tile_rgba[:, :, 3].astype(np.float32) / 255.0
    def luma(t):
        return 0.2126 * t[:, :, 0] + 0.7152 * t[:, :, 1] + 0.0722 * t[:, :, 2]
    d = np.abs(luma(tile_rgba.astype(np.float32)) - luma(back.astype(np.float32))) * a
    if d.size == 0:
        return False
    # p99.5 rather than max: one stray pixel is not a terrain feature, but a ridge line is thousands.
    return float(np.percentile(d, 99.5)) >= SPARSE_JND_LUMA


def bake_deep_level(workers=8):
    """Render the deepest level in blocks, returning {(x, y): webp bytes} and the coverage fraction.

    BLOCKS WITH A HALO, not one mosaic. The original design shaded the whole of CONUS at once
    specifically so that no tile boundary could show — the gradient at a tile edge needs the
    neighbour's pixels, and shading tile-by-tile leaves a visible discontinuity at every border. That
    guarantee is preserved here rather than abandoned: each block is computed with a halo wider than
    every filter that reads neighbours, so its edge pixels see real data and come out identical to what
    the whole-CONUS pass would have produced. What changes is only that the array fits in memory.
    """
    x0, x1, y0, y1 = tile_range(SRC_ZOOM)
    halo = block_halo_px()
    radius = baseline_radius_px()
    assert halo > radius, "block halo must exceed every filter radius or blocks will show their seams"
    full_h, full_w = (y1 - y0 + 1) * TILE, (x1 - x0 + 1) * TILE
    total_tiles = (x1 - x0 + 1) * (y1 - y0 + 1)
    print(f"deep level z{MAX_ZOOM}: {total_tiles} source tiles, "
          f"blocks of {BLOCK_TILES}x{BLOCK_TILES} with a {halo}px halo (baseline radius {radius}px)")

    out, present, skipped = {}, 0, 0
    blocks = [(bx, by)
              for by in range(y0, y1 + 1, BLOCK_TILES)
              for bx in range(x0, x1 + 1, BLOCK_TILES)]
    for i, (bx, by) in enumerate(blocks):                       # bounded by the tile range (rule 2)
        cx1, cy1 = min(bx + BLOCK_TILES - 1, x1), min(by + BLOCK_TILES - 1, y1)
        pad_t = (halo + TILE - 1) // TILE                       # halo in whole tiles
        wx0, wy0 = bx - pad_t, by - pad_t
        wx1, wy1 = cx1 + pad_t, cy1 + pad_t
        elev, got = load_dem_window(wx0, wy0, wx1, wy1)
        core_r0, core_c0 = (by - wy0) * TILE, (bx - wx0) * TILE
        core_h, core_w = (cy1 - by + 1) * TILE, (cx1 - bx + 1) * TILE
        core_elev = elev[core_r0:core_r0 + core_h, core_c0:core_c0 + core_w]
        if not np.isfinite(core_elev).any():
            continue                                            # all ocean / uncovered
        shade = multidirectional_shade(elev, wy0, wy1)
        # The WINDOW's absolute origin, not the core's — colorize runs on the whole window including
        # the halo, so a core-relative origin walks the feather profile off the end of the bbox and
        # zeroes the alpha of everything past the first tile row.
        rgba = colorize(elev, shade,
                        abs_origin=((wy0 - y0) * TILE, (wx0 - x0) * TILE),
                        full_shape=(full_h, full_w))
        rgba = rgba[core_r0:core_r0 + core_h, core_c0:core_c0 + core_w]
        del elev, shade

        jobs = []
        for ty in range(by, cy1 + 1):
            for tx in range(bx, cx1 + 1):
                r0, c0 = (ty - by) * TILE, (tx - bx) * TILE
                tile = rgba[r0:r0 + TILE, c0:c0 + TILE]
                if tile.shape[:2] != (TILE, TILE) or not tile[:, :, 3].any():
                    continue
                if MAX_ZOOM >= SPARSE_BELOW_ZOOM and not tile_is_worth_carrying(tile):
                    skipped += 1
                    continue
                jobs.append(((tx, ty), tile.copy()))
                present += 1
        with futures.ThreadPoolExecutor(max_workers=workers) as ex:
            for key, blob in zip([k for k, _ in jobs], ex.map(encode_webp, [t for _, t in jobs])):
                out[key] = blob
        del rgba, core_elev
        print(f"  block {i + 1}/{len(blocks)}: {len(out)} tiles kept, {skipped} flat skipped", end="\r")
    print()
    # Coverage = how much of the bbox the SOURCE actually covered. A tile deliberately skipped for
    # being flat is covered, just not carried, so it counts toward coverage and not against it.
    coverage = (present + skipped) / float(max(total_tiles, 1))
    print(f"deep level: {present} tiles carried, {skipped} flat tiles left to the parent "
          f"({100.0 * skipped / max(total_tiles, 1):.0f}% saved)")
    return out, coverage


def reduce_level(children, z):
    """Build level z by box-reducing the four children of each tile at z+1."""
    assert z >= 0, "reduce_level: negative zoom"
    parents = {}
    for (cx, cy) in children:                                   # bounded by the level below (rule 2)
        parents.setdefault((cx >> 1, cy >> 1), True)
    out = {}
    for (px, py) in parents:                                    # bounded (rule 2)
        canvas = np.zeros((TILE * 2, TILE * 2, 4), dtype=np.uint8)
        any_child = False
        for dy in (0, 1):
            for dx in (0, 1):
                blob = children.get((px * 2 + dx, py * 2 + dy))
                if blob is None:
                    continue
                canvas[dy * TILE:(dy + 1) * TILE, dx * TILE:(dx + 1) * TILE] = decode_webp_rgba(blob)
                any_child = True
        if not any_child:
            continue
        out[(px, py)] = encode_webp(box_downsample(canvas))
    return out


def decode_webp_rgba(blob):
    """WebP bytes -> premultiplied RGBA, the form the pyramid averages in."""
    with tempfile.TemporaryDirectory() as td:
        src, dst = os.path.join(td, "t.webp"), os.path.join(td, "t.pam")
        with open(src, "wb") as f:
            f.write(blob)
        subprocess.run(["dwebp", "-quiet", src, "-pam", "-o", dst], check=True)
        with open(dst, "rb") as f:
            d = f.read()
    i = d.index(b"ENDHDR\n") + 7
    hdr = d[:i].decode()
    g = lambda k: int([l for l in hdr.split("\n") if l.startswith(k)][0].split()[1])
    w, h, dep = g("WIDTH"), g("HEIGHT"), g("DEPTH")
    a = np.frombuffer(d[i:i + w * h * dep], dtype=np.uint8).reshape(h, w, dep).copy()
    if dep == 3:
        a = np.dstack([a, np.full((h, w, 1), 255, np.uint8)])
    # Premultiply so the 2x2 average below cannot bleed colour out of transparent pixels.
    al = a[:, :, 3:4].astype(np.float32) / 255.0
    a[:, :, :3] = (a[:, :, :3].astype(np.float32) * al).astype(np.uint8)
    return a


def bake(preview=None, workers=8):
    assert SRC_ZOOM >= MAX_ZOOM, "MAX_ZOOM cannot exceed the source resolution — that would be invention"
    deep, coverage = bake_deep_level(workers=workers)
    if coverage < MIN_COVERAGE:
        sys.exit(f"coverage {coverage * 100:.1f}% below {MIN_COVERAGE * 100:.0f}% — run --fetch first")
    levels = {MAX_ZOOM: deep}
    print(f"  built z{MAX_ZOOM}: {len(deep)} tiles")
    cur = deep
    for z in range(MAX_ZOOM - 1, -1, -1):                       # bounded (rule 2)
        cur = reduce_level(cur, z)
        levels[z] = cur
        print(f"  built z{z}: {len(cur)} tiles")
        if not cur:
            break
    if preview:
        _write_preview(levels, preview)
    return write_mbtiles(levels, os.path.abspath(OUT_PATH))


def _write_preview(levels, path):
    """Stitch the shallowest useful level into one PNG for eyeballing the palette."""
    z = min(6, MAX_ZOOM)
    tiles = levels.get(z) or {}
    if not tiles:
        return
    xs = [x for x, _ in tiles]; ys = [y for _, y in tiles]
    w = (max(xs) - min(xs) + 1) * TILE; h = (max(ys) - min(ys) + 1) * TILE
    canvas = np.zeros((h, w, 4), dtype=np.uint8)
    for (x, y), blob in tiles.items():                          # bounded by the level (rule 2)
        canvas[(y - min(ys)) * TILE:(y - min(ys) + 1) * TILE,
               (x - min(xs)) * TILE:(x - min(xs) + 1) * TILE] = decode_webp_rgba(blob)
    with open(path, "wb") as f:
        f.write(encode_png_rgba(unpremultiply(canvas)))
    print(f"preview -> {path} ({w} px wide, z{z})")


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

    # ALIGNMENT is checked at the deepest DENSE level, not at MAX_ZOOM. Past SPARSE_BELOW_ZOOM an
    # absent tile means "flat, take the parent" rather than "water", so "no tile == ocean" — the
    # inference this check rests on — is only sound where every land tile is guaranteed present.
    dense_z = min(SPARSE_BELOW_ZOOM - 1, MAX_ZOOM) if MAX_ZOOM >= SPARSE_BELOW_ZOOM else MAX_ZOOM
    # (name, lat, lon, expect_land)
    checks = [("Denver CO", 39.74, -104.99, True), ("Pikes Peak", 38.84, -105.04, True),
              ("Wichita KS", 37.69, -97.34, True), ("Miami FL", 25.78, -80.20, True),
              ("Atlantic off NC", 35.00, -74.00, False), ("Gulf of Mexico", 26.00, -90.00, False),
              ("Pacific off CA", 34.00, -124.50, False)]
    bad = []
    for name, lat, lon, want_land in checks:                    # bounded (rule 2)
        alpha, _, where = sample(lat, lon, z=dense_z)
        is_land = alpha is not None and alpha > 32               # at a dense level, absent == water
        if is_land != want_land:
            bad.append(f"{name} ({where}): alpha={alpha}, expected {'land' if want_land else 'water'}")
    if bad:
        sys.exit("ALIGNMENT FAILED:\n  " + "\n  ".join(bad))
    _, high, _ = sample(38.84, -105.04, z=dense_z)
    _, low, _ = sample(37.69, -97.34, z=dense_z)
    if not (high and low and high > low):
        sys.exit(f"relief inverted or flat: high-terrain luma {high} vs plains {low}")
    print(f"  alignment: {len(checks)}/{len(checks)} land/water samples correct at z{dense_z}")
    print(f"  relief: high-terrain luma {high:.1f} > plains {low:.1f}")

    # And the DEEP level separately: it must be present over real terrain, and aligned there. This is
    # the check that catches a pyramid-origin error at MAX_ZOOM — the failure that puts perfectly good
    # relief in the wrong place, which on a moving map is shaded terrain where there is none.
    if MAX_ZOOM > dense_z:
        deep_bad = []
        for name, lat, lon in [("Pikes Peak", 38.84, -105.04), ("Aspen CO", 39.2232, -106.8687),
                               ("Butte MT", 45.9548, -112.4975)]:
            alpha, _, where = sample(lat, lon, z=MAX_ZOOM)
            if alpha is None or alpha <= 32:
                deep_bad.append(f"{name} ({where}): mountain terrain missing from z{MAX_ZOOM}")
        if deep_bad:
            sys.exit("DEEP LEVEL FAILED:\n  " + "\n  ".join(deep_bad))
        carried = db.execute("SELECT count(*) FROM tiles WHERE zoom_level=?", (MAX_ZOOM,)).fetchone()[0]
        print(f"  deep level: z{MAX_ZOOM} present over all 3 mountain samples ({carried} tiles carried)")
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
        bake(preview=args.preview, workers=args.workers)
    if args.verify:
        verify(OUT_PATH)


if __name__ == "__main__":
    main()
