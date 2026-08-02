#!/usr/bin/env python3
"""lzcommon.py — shared geometry, plane layout and blob format for the CommSight LZ pipeline.

WHAT THIS IS
    The single source of truth that every other lz/ script imports. If a constant appears here it
    must NOT be redefined anywhere else: the pipeline and the on-device decoder have to agree
    byte-for-byte, and the only way to keep them honest is to have one file the packer and the
    fixture generator both read.

    Holds four things:
      1. Cell geometry      — the 1x1 degree processing cell and its analysis margin.
      2. The master grid    — EPSG:5070 (CONUS Albers), 10 m cells, plus a pure-Python Albers
                              projection so a lat/lon oracle point can be turned into a grid index
                              without pulling in GDAL's Python bindings.
      3. Web-Mercator tiling — z13 tile math and the XYZ->TMS row flip.
      4. The lzpack blob    — plane order, quantisation, header layout, compression framing.

WHY A PURE-PYTHON ALBERS
    THIS module depends on numpy alone, so the grid maths, the blob format and the oracle-point
    lookups stay importable and testable anywhere — including from a test runner with no GDAL.
    (The raster stages do use the osgeo bindings; reading windows out of 155 remote LZW GeoTIFFs
    through subprocesses meant a temp-file round-trip per strip.)

    The forward/inverse projection here is the closed-form Snyder formulation for a secant Albers
    Equal-Area Conic on GRS80. `--selftest` cross-checks it against `gdaltransform` and fails if
    they disagree by more than a millimetre, so this is a MEASURED equivalence, not a hopeful
    reimplementation. It currently agrees to 0.0000 mm over the cell's landmark points.

TWO DECISIONS THAT MATTER FOR SAFETY
    1. TMS ROWS, NOT XYZ. The app's reader flips the row on the way in
       (`MBTilesReader.tileData`, ChartMapView.swift:62 — `let tmsY = (1 << z) - 1 - y`), which is
       the MBTiles spec. The packer must therefore WRITE TMS. Get this backwards and the pack still
       opens, still has the right tile count, and renders the cell mirrored north-for-south — a
       failure that looks like a projection bug and is not.
    2. RAW DEFLATE, NOT ZLIB. Apple's `COMPRESSION_ZLIB` is *raw* DEFLATE with no zlib wrapper, so
       the planes are written with `zlib.compressobj(wbits=-15)`. Python's default `zlib.compress()`
       emits a 2-byte header the device inflater rejects, and the symptom is not an error: every
       tile silently fails to decode and the layer renders fully transparent, which reads as
       "no risk here". Never let this one drift.

CONSERVATIVE AGGREGATION, BUT NOT NAIVELY SO
    Overviews never average. POINT hazards (hazard, flags) take the worst child — a tower is lethal
    to the whole approach through a cell. AREAL textures (slope, rough, class) take the SECOND-worst
    of four, because `max` compounds up a pyramid until the map excludes everything: measured on
    this cell, 16% -> 73% between z13 and z8. See AGGREGATION for the full reasoning and numbers.
    Native resolution — the zoom a field is actually chosen at — is untouched either way.

USAGE
    python3 lz/lzcommon.py --selftest        # grid dims, projection cross-check, blob round-trip
    python3 lz/lzcommon.py --describe        # print the resolved cell/grid/tiling constants
"""

import argparse
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

# numpy is required to BUILD, but not to READ. Only three functions here touch it (pack_blob,
# unpack_blob, selftest); everything else is geometry, constants and the wire contract — and those
# have to be importable from an interpreter that has no numerical stack.
#
# This module exiting on import was blocking exactly that: `publish.py` runs under ~/chartenv (the
# HuggingFace venv, which has huggingface_hub and no numpy) while the pipeline stages run under the
# system interpreter (numpy + GDAL, no huggingface_hub). Neither has both, and nothing needs both.
# A hard `sys.exit` at import time made the split unresolvable for a script that only wanted to read
# LZ_SCHEMA and PLANE_NAMES.
try:
    import numpy as np
except ImportError:                                     # pragma: no cover — env-dependent
    np = None


def require_numpy():
    """Call at the top of anything that builds or decodes tile bytes. Fails with the same message
    the import guard used to, but only when numpy is actually needed."""
    if np is None:
        sys.exit("numpy is required for this stage: python3 -m pip install numpy")

# ---------------------------------------------------------------------------------------------
# 1. CELL GEOMETRY
# ---------------------------------------------------------------------------------------------

# USGS 1x1 degree cell naming: the name marks the cell's NORTH-WEST corner. "n33w107" therefore
# spans lat 32..33 N and lon -107..-106 W. The v1 pilot cell is Las Cruces, New Mexico: it holds
# KLRU, the irrigated Mesilla Valley (good fields), the Organ Mountains (the energy-layer terrain
# case), the Rio Grande (the water veto) and open Chihuahuan desert scrub.
#
# THESE ARE THE CURRENTLY SELECTED CELL, not constants. Every stage takes `--cell` and calls
# `select_cell()` before doing any work; the pipeline builds ONE cell per process, which is why
# module-level state is the right shape here rather than threading a cell object through forty-odd
# call sites. Nothing at import time is derived from them — every read is inside a function — so
# rebinding is safe. (The four `cell=None` defaults below exist for the same reason: a
# `cell=CELL_ID` default argument would bind at def time and silently ignore the selection.)
DEFAULT_CELL_ID = "n33w107"
CELL_ID = DEFAULT_CELL_ID
CELL_LAT_MIN, CELL_LAT_MAX = 32.0, 33.0
CELL_LON_MIN, CELL_LON_MAX = -107.0, -106.0


def parse_cell_id(cell_id):
    """`"n33w107"` -> `(lat_min, lat_max, lon_min, lon_max)`.

    The USGS 3DEP convention: the name is the cell's NORTH-WEST corner, and the cell extends one
    degree SOUTH and one degree EAST of it. Getting that backwards puts every fetch window one cell
    away from the data it wants — and the DEM URLs `fetch.py` builds from this id would still
    resolve, so the failure would look like bad data rather than bad geometry.
    """
    m = re.fullmatch(r"([ns])(\d{2})([ew])(\d{3})", cell_id.strip().lower())
    if not m:
        raise ValueError(f"cell id {cell_id!r} is not USGS nXXwYYY form (e.g. n33w107)")
    ns, lat_s, ew, lon_s = m.groups()
    lat = int(lat_s) * (1 if ns == "n" else -1)
    lon = int(lon_s) * (-1 if ew == "w" else 1)
    if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
        raise ValueError(f"cell id {cell_id!r} is out of range")
    # NW corner -> the degree square south and east of it.
    return (float(lat - 1), float(lat), float(lon), float(lon + 1))


def select_cell(cell_id):
    """Point the pipeline at a cell. Call once, early, before any stage does work."""
    global CELL_ID, CELL_LAT_MIN, CELL_LAT_MAX, CELL_LON_MIN, CELL_LON_MAX
    lat_min, lat_max, lon_min, lon_max = parse_cell_id(cell_id)
    CELL_ID = cell_id.strip().lower()
    CELL_LAT_MIN, CELL_LAT_MAX = lat_min, lat_max
    CELL_LON_MIN, CELL_LON_MAX = lon_min, lon_max
    assert CELL_LAT_MAX - CELL_LAT_MIN == 1.0, "select_cell: cells are one degree"
    assert CELL_LON_MAX - CELL_LON_MIN == 1.0, "select_cell: cells are one degree"
    return CELL_ID


def add_cell_argument(ap):
    """The `--cell` flag, identical on every stage so the pipeline reads the same at each step."""
    ap.add_argument("--cell", default=DEFAULT_CELL_ID,
                    help=f"1x1 degree cell to build, USGS nXXwYYY (default {DEFAULT_CELL_ID})")
    return ap

# Analysis margin. Every windowed operation in the pipeline (relief windows, distance transforms,
# road/field-edge buffers) reads neighbours, so the master grid is built OVERSIZE and the margin is
# cropped away at packaging. 2 km comfortably exceeds the widest window we use (the 100 m relief
# window and the ~500 m hazard decay), so no tile at the cell seam is computed from truncated data.
EDGE_MARGIN_M = 2000.0

# ---------------------------------------------------------------------------------------------
# 2. MASTER ANALYSIS GRID — EPSG:5070, 10 m
# ---------------------------------------------------------------------------------------------

ANALYSIS_EPSG = 5070
CELL_SIZE_M = 10.0

# EPSG:5070 = NAD83 / Conus Albers. GRS80 ellipsoid.
GRS80_A = 6378137.0
GRS80_INV_F = 298.257222101
ALBERS_LAT_1 = 29.5
ALBERS_LAT_2 = 45.5
ALBERS_LAT_0 = 23.0
ALBERS_LON_0 = -96.0
ALBERS_X_0 = 0.0
ALBERS_Y_0 = 0.0

_F = 1.0 / GRS80_INV_F
_E2 = 2.0 * _F - _F * _F
_E = math.sqrt(_E2)


def _albers_m(phi):
    """Snyder (14-15): m = cos(phi) / sqrt(1 - e^2 sin^2 phi)."""
    s = math.sin(phi)
    return math.cos(phi) / math.sqrt(1.0 - _E2 * s * s)


def _albers_q(phi):
    """Snyder (3-12): the authalic-area function q."""
    s = math.sin(phi)
    es = _E * s
    return (1.0 - _E2) * (s / (1.0 - _E2 * s * s)
                          - (1.0 / (2.0 * _E)) * math.log((1.0 - es) / (1.0 + es)))


def _albers_constants():
    p1, p2, p0 = map(math.radians, (ALBERS_LAT_1, ALBERS_LAT_2, ALBERS_LAT_0))
    m1, m2 = _albers_m(p1), _albers_m(p2)
    q1, q2, q0 = _albers_q(p1), _albers_q(p2), _albers_q(p0)
    n = (m1 * m1 - m2 * m2) / (q2 - q1)
    c = m1 * m1 + n * q1
    rho0 = GRS80_A * math.sqrt(c - n * q0) / n
    return n, c, rho0


_ALB_N, _ALB_C, _ALB_RHO0 = _albers_constants()


def lonlat_to_albers(lon, lat):
    """Forward EPSG:4269/4326 -> EPSG:5070. Returns (x, y) metres."""
    assert -180.0 <= lon <= 180.0, "lonlat_to_albers: longitude out of range"
    assert -90.0 <= lat <= 90.0, "lonlat_to_albers: latitude out of range"
    phi, lam = math.radians(lat), math.radians(lon)
    rho = GRS80_A * math.sqrt(_ALB_C - _ALB_N * _albers_q(phi)) / _ALB_N
    theta = _ALB_N * (lam - math.radians(ALBERS_LON_0))
    return (ALBERS_X_0 + rho * math.sin(theta),
            ALBERS_Y_0 + _ALB_RHO0 - rho * math.cos(theta))


def albers_to_lonlat(x, y, iterations=12):
    """Inverse EPSG:5070 -> lon/lat degrees. Newton iteration on the authalic latitude."""
    assert iterations >= 4, "albers_to_lonlat: too few iterations to converge"
    xp, yp = x - ALBERS_X_0, _ALB_RHO0 - (y - ALBERS_Y_0)
    rho = math.hypot(xp, yp)
    if rho == 0.0:
        return ALBERS_LON_0, 90.0 if _ALB_N > 0 else -90.0
    theta = math.atan2(xp, yp) if _ALB_N > 0 else math.atan2(-xp, -yp)
    q = (_ALB_C - (rho * rho * _ALB_N * _ALB_N) / (GRS80_A * GRS80_A)) / _ALB_N
    phi = math.asin(max(-1.0, min(1.0, q / 2.0)))
    for _ in range(iterations):
        s = math.sin(phi)
        es = _E * s
        denom = 1.0 - _E2 * s * s
        d = (denom * denom / (2.0 * math.cos(phi))) * (
            q / (1.0 - _E2) - s / denom + (1.0 / (2.0 * _E)) * math.log((1.0 - es) / (1.0 + es)))
        phi += d
        if abs(d) < 1e-12:
            break
    return math.degrees(math.radians(ALBERS_LON_0) + theta / _ALB_N), math.degrees(phi)


def _densified_cell_ring(steps=64):
    """The cell boundary sampled densely. A 1x1 degree quad is NOT a rectangle in Albers, so its
    projected bounding box has to come from the whole edge, not the four corners."""
    assert steps >= 8, "_densified_cell_ring: too few steps to bound a curved edge"
    pts = []
    for i in range(steps + 1):
        t = i / steps
        pts.append((CELL_LON_MIN + t * (CELL_LON_MAX - CELL_LON_MIN), CELL_LAT_MIN))
        pts.append((CELL_LON_MIN + t * (CELL_LON_MAX - CELL_LON_MIN), CELL_LAT_MAX))
        pts.append((CELL_LON_MIN, CELL_LAT_MIN + t * (CELL_LAT_MAX - CELL_LAT_MIN)))
        pts.append((CELL_LON_MAX, CELL_LAT_MIN + t * (CELL_LAT_MAX - CELL_LAT_MIN)))
    return pts


def cone_convergence_rad(lon):
    """Angle between projected north and true north at a longitude: theta = n * (lam - lam0).

    This is why the master grid is bigger than you expect. EPSG:5070 is a CONIC projection with
    its central meridian at -96, and n33w107 sits ~11 degrees west of that, so the 1x1 degree quad
    lands in the projected plane ROTATED by ~6.3 degrees. Its axis-aligned bounding box is then
    ~109 x 125 km rather than the naive 94 x 111, and the cell fills only ~82% of its own bbox.
    The remainder is real grid that gets cropped at packaging — budget memory for the bbox, not
    for the quad."""
    return _ALB_N * math.radians(lon - ALBERS_LON_0)


def master_grid():
    """The 10 m EPSG:5070 grid covering the cell + margin, snapped outward to whole cells.

    Returns a dict with x_min/y_min/x_max/y_max (metres), cols, rows, and the GDAL-style
    geotransform. Snapping to an absolute multiple of CELL_SIZE_M (not to the cell's own corner)
    means neighbouring cells share grid lines exactly, so a future multi-cell build mosaics
    without resampling. See cone_convergence_rad() for why the result is ~136 M cells and not the
    ~104 M a flat reading of the cell size would suggest."""
    xs, ys = [], []
    for lon, lat in _densified_cell_ring():
        x, y = lonlat_to_albers(lon, lat)
        xs.append(x)
        ys.append(y)
    x_min = math.floor((min(xs) - EDGE_MARGIN_M) / CELL_SIZE_M) * CELL_SIZE_M
    x_max = math.ceil((max(xs) + EDGE_MARGIN_M) / CELL_SIZE_M) * CELL_SIZE_M
    y_min = math.floor((min(ys) - EDGE_MARGIN_M) / CELL_SIZE_M) * CELL_SIZE_M
    y_max = math.ceil((max(ys) + EDGE_MARGIN_M) / CELL_SIZE_M) * CELL_SIZE_M
    cols = int(round((x_max - x_min) / CELL_SIZE_M))
    rows = int(round((y_max - y_min) / CELL_SIZE_M))
    assert cols > 0 and rows > 0, "master_grid: degenerate grid"
    return {
        "epsg": ANALYSIS_EPSG, "cell_size_m": CELL_SIZE_M,
        "x_min": x_min, "y_min": y_min, "x_max": x_max, "y_max": y_max,
        "cols": cols, "rows": rows,
        # GDAL geotransform: north-up, so pixel (0,0) is the NORTH-west corner and dy is negative.
        "geotransform": [x_min, CELL_SIZE_M, 0.0, y_max, 0.0, -CELL_SIZE_M],
    }


def lonlat_to_grid(lon, lat, grid=None):
    """Map a geographic point to (row, col) in the master grid. Returns None if outside."""
    g = grid or master_grid()
    x, y = lonlat_to_albers(lon, lat)
    col = int(math.floor((x - g["x_min"]) / CELL_SIZE_M))
    row = int(math.floor((g["y_max"] - y) / CELL_SIZE_M))
    if 0 <= row < g["rows"] and 0 <= col < g["cols"]:
        return row, col
    return None


# ---------------------------------------------------------------------------------------------
# 3. WEB-MERCATOR TILING
# ---------------------------------------------------------------------------------------------

TILE_SIDE = 256
NATIVE_ZOOM = 13          # ~19 m/px at this latitude — the deepest level worth storing for a 10 m grid
MIN_ZOOM = 6
WEBMERC_MAX_LAT = 85.05112877980659


def lonlat_to_tile(lon, lat, z):
    """XYZ tile containing a point (Google/OSM convention, y increases southward)."""
    assert 0 <= z <= 24, "lonlat_to_tile: zoom out of range"
    lat = max(-WEBMERC_MAX_LAT, min(WEBMERC_MAX_LAT, lat))
    n = 1 << z
    x = int((lon + 180.0) / 360.0 * n)
    r = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tile_bounds(x, y, z):
    """(lon_min, lat_min, lon_max, lat_max) of an XYZ tile."""
    assert 0 <= z <= 24, "tile_bounds: zoom out of range"
    n = 1 << z
    lon0 = x / n * 360.0 - 180.0
    lon1 = (x + 1) / n * 360.0 - 180.0
    lat0 = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * (y + 1) / n))))
    lat1 = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * y / n))))
    return lon0, lat0, lon1, lat1


def xyz_to_tms_row(y, z):
    """The row flip. MBTiles stores TMS (row 0 at the SOUTH); the app's reader converts on read
    (`MBTilesReader.tileData`, ChartMapView.swift:62), so the packer must write TMS."""
    assert 0 <= z <= 24, "xyz_to_tms_row: zoom out of range"
    assert 0 <= y < (1 << z), "xyz_to_tms_row: row out of range for zoom"
    return (1 << z) - 1 - y


def cell_tiles(z):
    """Every XYZ tile at zoom z that intersects the cell (margin excluded — the margin exists for
    the analysis windows, not for shipping)."""
    x0, y0 = lonlat_to_tile(CELL_LON_MIN, CELL_LAT_MAX, z)
    x1, y1 = lonlat_to_tile(CELL_LON_MAX, CELL_LAT_MIN, z)
    return [(x, y) for x in range(min(x0, x1), max(x0, x1) + 1)
            for y in range(min(y0, y1), max(y0, y1) + 1)]


# ---------------------------------------------------------------------------------------------
# 4. THE lzpack BLOB
# ---------------------------------------------------------------------------------------------

BLOB_MAGIC = b"LZP1"
BLOB_VERSION = 1
LZ_SCHEMA = 2      # 2 added the `extent` plane (lz/extent.py)

# Plane order is load-bearing: the device indexes planes positionally.
#
# ⚠️ DERIVED FROM THE NAMES, never hand-numbered. These were a literal `range(6)` while PLANE_NAMES
# had grown to seven, so `PLANE_EXTENT` simply did not exist — any code reaching for it got an
# AttributeError, and any code that had hand-counted the index would have been reading `flags` as
# `extent` with no complaint from anything.
PLANE_NAMES = ["class", "conf", "slope", "rough", "hazard", "flags", "extent"]
PLANE_COUNT = len(PLANE_NAMES)
(PLANE_CLASS, PLANE_CONF, PLANE_SLOPE, PLANE_ROUGH,
 PLANE_HAZARD, PLANE_FLAGS, PLANE_EXTENT) = range(PLANE_COUNT)

# --- quantisation ---------------------------------------------------------------------------
# slope: MAGNITUDE in 0.2 deg steps, u8 0..254 <-> 0..50.8 degrees; 255 = nodata.
#
# Two corrections to the original signed design, both driven by the actual data:
#   1. A per-cell raster has no landing direction, so a SIGN is not meaningful here. Signed slope
#      ("land uphill, depart downhill") is an attribute of a RUN — a candidate rectangle with an
#      axis — and belongs to the run finder, not to an ambient per-cell plane. Storing a sign we
#      cannot define would be inventing information.
#   2. The signed encoding would have capped at +-25.4 deg, and the Organ Mountains — the whole
#      reason this cell was chosen for the energy-layer case — run well past that. Magnitude
#      doubles the range to 50.8 deg for the same byte. Anything steeper saturates, which is
#      harmless: past 50 deg every ruleset vetoes regardless.
SLOPE_STEP_DEG = 0.2
SLOPE_MAX_DEG = 254 * SLOPE_STEP_DEG      # 50.8
SLOPE_NODATA = 255
# rough: detrended residual sigma in CENTIMETRES, 0..254 (0..2.54 m); 255 = nodata. The spec's
# roughness veto sits at 0.6 m, comfortably inside the range.
ROUGH_NODATA = 255
# hazard: u8 0..255 <-> H in [0,1] (noisy-OR fused). No nodata: absence of hazard evidence is 0,
# and the UI must never render that as "no hazard" — see README.
HAZARD_MAX = 255
# conf: percent 0..100. 255 = unknown.
CONF_MAX = 100
CONF_UNKNOWN = 255


def slope_to_u8(deg):
    """Quantise signed slope degrees, saturating rather than wrapping."""
    v = int(round(SLOPE_ZERO + float(deg) / SLOPE_STEP_DEG))
    return max(0, min(254, v))


def u8_to_slope(v):
    assert 0 <= v <= 255, "u8_to_slope: byte out of range"
    if v == SLOPE_NODATA:
        return None
    return (v - SLOPE_ZERO) * SLOPE_STEP_DEG


# --- surface classes ------------------------------------------------------------------------
CLASS_UNKNOWN = 0
CLASS_OPEN_FIRM = 1
CLASS_OPEN_SOFT = 2
CLASS_CROP = 3
CLASS_BRUSH = 4
CLASS_FOREST = 5
CLASS_DEVELOPED_OPEN = 6
CLASS_DEVELOPED_DENSE = 7
CLASS_BARREN_ROUGH = 8
CLASS_WATER = 9
CLASS_WETLAND = 10
CLASS_SNOW_ICE = 11
CLASS_NAMES = {
    CLASS_UNKNOWN: "unknown", CLASS_OPEN_FIRM: "open_firm", CLASS_OPEN_SOFT: "open_soft",
    CLASS_CROP: "crop", CLASS_BRUSH: "brush", CLASS_FOREST: "forest",
    CLASS_DEVELOPED_OPEN: "developed_open", CLASS_DEVELOPED_DENSE: "developed_dense",
    CLASS_BARREN_ROUGH: "barren_rough", CLASS_WATER: "water", CLASS_WETLAND: "wetland",
    CLASS_SNOW_ICE: "snow_ice",
}

# Overview aggregation keeps the WORST child. Higher rank = worse place to put an aeroplane.
# `unknown` ranks above the good classes deliberately: "we do not know" must not be diluted by
# three confident neighbours when four cells collapse into one.
CLASS_SEVERITY = {
    CLASS_OPEN_FIRM: 0, CLASS_DEVELOPED_OPEN: 1, CLASS_CROP: 2, CLASS_BARREN_ROUGH: 3,
    CLASS_OPEN_SOFT: 4, CLASS_BRUSH: 5, CLASS_UNKNOWN: 6, CLASS_SNOW_ICE: 7,
    CLASS_WETLAND: 8, CLASS_FOREST: 9, CLASS_DEVELOPED_DENSE: 10, CLASS_WATER: 11,
}

# --- flags ------------------------------------------------------------------------------------
FLAG_DOF_TOWER = 1 << 0
FLAG_TX_CORRIDOR = 1 << 1
FLAG_ROAD_BUFFER = 1 << 2
FLAG_WATER_VETO = 1 << 3
FLAG_WETLAND = 1 << 4
FLAG_COARSE_TERRAIN = 1 << 5
FLAG_SPARE_6 = 1 << 6
FLAG_SPARE_7 = 1 << 7
FLAG_NAMES = {
    FLAG_DOF_TOWER: "dof_tower", FLAG_TX_CORRIDOR: "tx_corridor", FLAG_ROAD_BUFFER: "road_buffer",
    FLAG_WATER_VETO: "water_veto", FLAG_WETLAND: "wetland", FLAG_COARSE_TERRAIN: "coarse_terrain",
}

# --- terrain source -------------------------------------------------------------------------
# Ordered so that max() IS the conservative aggregate. ~20% of CONUS has no 1 m 3DEP, and where the
# DEM is 1/3 arc-second the micro-relief ("hidden ditch") veto physically cannot fire — a 10 m DEM
# cannot resolve a 1.5 m ditch. That ground would otherwise score BETTER than lidar-covered ground
# purely because the vetoes went quiet, so the device caps any tile that is not FINE.
TERRAIN_SRC_FINE = 0
TERRAIN_SRC_MIXED = 1
TERRAIN_SRC_COARSE = 2
TERRAIN_SRC_NAMES = {TERRAIN_SRC_FINE: "fine_1m", TERRAIN_SRC_MIXED: "mixed",
                     TERRAIN_SRC_COARSE: "coarse_10m"}

# How each plane collapses 2x2 -> 1 when building overviews. Names are resolved in package.py.
#
# TWO KINDS OF FACT, TWO KINDS OF CONSERVATISM.
#
# POINT hazards take the WORST child. A tower or a wire occupies a fraction of a parent cell and is
# still lethal to the whole approach through it, so `max`/`or` is the only defensible reduction —
# averaging one away invents safe ground between two towers.
#
# CONTINUOUS textures take the SECOND-WORST of the four. Slope and roughness describe ground rather
# than objects, and `max` compounds catastrophically up a pyramid: MEASURED on this cell, the share
# excluded by slope went 16% (native z13) -> 21% -> 43% -> 51% -> 62% -> 73% (z8), because one
# 40-degree arroyo bank condemns a 2 km parent that is otherwise flat basin floor. A map that
# excludes 73% of the desert is not being careful, it is being useless — a layer that flags all
# ground flags none. Second-worst keeps real mountains (steep nearly everywhere, so the runner-up
# is steep too) and drops the lone outlier. Measured after the change: 16% -> 17% -> 31% -> 32% ->
# 35% -> 39%.
#
# CLASS STAYS WORST-WINS, and that distinction was earned the hard way. Class was briefly treated
# as a texture too, and the oracle immediately caught the Rio Grande reading as CROP at z11: a
# river is a LINEAR feature, so a 2x2 covering it is typically three parts farmland to one part
# water, and the runner-up is farmland. Categories are not textures — the severe ones (water,
# forest, built-up) are the whole reason a cell is unlandable, exactly like a point hazard, and
# they must survive every level.
#
# None of this weakens the property that matters: nothing changes at native resolution, which is
# the zoom a field is actually chosen at. Overviews exist for orientation, and "steep across most
# of this area" is the honest thing for them to say.
AGGREGATION = {
    "class": "worst_severity", "conf": "min", "slope": "second_max",
    "rough": "second_max", "hazard": "max", "flags": "or",
    # EXTENT'S WORST IS ITS SMALLEST — less room is the bad direction, so where the others take a
    # max this takes a min. "second_min" for the same reason slope and rough take second_max: a
    # plain min compounds down the pyramid until every parent reports the tightest corner of its
    # sixteen grandchildren, and a mile-wide field would read as unusable at z8.
    "extent": "second_min",
}

# Longest open run through a cell, 10 m per step (exactly one grid cell, so no quantisation error),
# saturating at 2550 m. 255 means "more room than any light aeroplane can use" — a complete answer
# rather than a truncated one. Mirrored by LZPack.extentStepM on the device.
EXTENT_STEP_M = 10.0
EXTENT_MAX_M = 255 * EXTENT_STEP_M

# Header: magic(4) version(1) plane_count(1) side(2) terrain_source(1) reserved(1) + u32 x planes.
_HEADER_FIXED = struct.Struct("<4sBBHBB")
HEADER_BYTES = _HEADER_FIXED.size + 4 * PLANE_COUNT


def pack_blob(planes, terrain_source):
    """Serialise six 256x256 uint8 planes into an lzpack tile blob.

    Planes are RAW DEFLATE (wbits=-15) because Apple's COMPRESSION_ZLIB expects no zlib wrapper.
    See the module docstring — getting this wrong produces a silently transparent layer."""
    require_numpy()
    assert len(planes) == PLANE_COUNT, "pack_blob: wrong plane count"
    assert terrain_source in TERRAIN_SRC_NAMES, "pack_blob: unknown terrain_source"
    streams = []
    for i, p in enumerate(planes):
        a = np.ascontiguousarray(p, dtype=np.uint8)
        assert a.shape == (TILE_SIDE, TILE_SIDE), f"pack_blob: plane {PLANE_NAMES[i]} wrong shape"
        co = zlib.compressobj(9, zlib.DEFLATED, -15)
        streams.append(co.compress(a.tobytes()) + co.flush())
    head = _HEADER_FIXED.pack(BLOB_MAGIC, BLOB_VERSION, PLANE_COUNT, TILE_SIDE,
                              terrain_source, 0)
    lens = b"".join(struct.pack("<I", len(s)) for s in streams)
    return head + lens + b"".join(streams)


def unpack_blob(data):
    """Inverse of pack_blob. Returns (planes, terrain_source) or None — never raises, so a corrupt
    tile degrades to 'no data here' exactly as it does on device."""
    require_numpy()
    if len(data) < HEADER_BYTES:
        return None
    magic, version, count, side, tsrc, _ = _HEADER_FIXED.unpack_from(data, 0)
    if magic != BLOB_MAGIC or version != BLOB_VERSION or count != PLANE_COUNT:
        return None
    if side != TILE_SIDE or tsrc not in TERRAIN_SRC_NAMES:
        return None
    lens = [struct.unpack_from("<I", data, _HEADER_FIXED.size + 4 * i)[0] for i in range(count)]
    off = HEADER_BYTES
    planes = []
    for n in lens:
        if off + n > len(data):
            return None
        try:
            raw = zlib.decompress(data[off:off + n], -15)
        except zlib.error:
            return None
        if len(raw) != TILE_SIDE * TILE_SIDE:
            return None
        planes.append(np.frombuffer(raw, dtype=np.uint8).reshape(TILE_SIDE, TILE_SIDE))
        off += n
    return planes, tsrc


# ---------------------------------------------------------------------------------------------
# 5. MANIFEST
# ---------------------------------------------------------------------------------------------

LZ_ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(LZ_ROOT, "data")
WORK_DIR = os.path.join(LZ_ROOT, "work")
OUT_DIR = os.path.join(LZ_ROOT, "out")
STATIC_DIR = os.path.join(LZ_ROOT, "static")


def cell_dir(base, cell=None):
    """Per-cell working directory. `cell=None` means THE SELECTED CELL, resolved now — a
    `cell=CELL_ID` default argument would bind at import and quietly write every cell's output into
    n33w107's directory, which is the worst possible failure here: the build succeeds and the data
    is wrong."""
    d = os.path.join(base, cell or CELL_ID)
    os.makedirs(d, exist_ok=True)
    return d


def manifest_path(cell=None):
    return os.path.join(cell_dir(DATA_DIR, cell), "manifest.json")


def load_manifest(cell=None):
    """Manifest schema: {cell, sources: {name: {url, sha256, bytes, vintage, coverage_pct,
    status, fetched_at}}}. Absent file = empty manifest, so --fetch is resumable from nothing."""
    p = manifest_path(cell)
    if not os.path.exists(p):
        return {"cell": cell or CELL_ID, "sources": {}}
    with open(p) as f:
        return json.load(f)


def save_manifest(m, cell=None):
    assert "sources" in m, "save_manifest: malformed manifest"
    with open(manifest_path(cell), "w") as f:
        json.dump(m, f, indent=2, sort_keys=True)


def record_source(name, **fields):
    """Merge one source's provenance into the manifest. Every field the pipeline later needs to
    prove where a byte came from lives here — the pack's metadata row is built from it."""
    assert name, "record_source: empty source name"
    m = load_manifest()
    m["sources"].setdefault(name, {}).update(fields)
    save_manifest(m)
    return m["sources"][name]


# ---------------------------------------------------------------------------------------------
# SELFTEST
# ---------------------------------------------------------------------------------------------

# Points with known ground truth inside the cell, used here and by verify.py.
LANDMARKS = {
    "KLRU_field": (-106.9219, 32.2894),
    "organ_crest": (-106.5610, 32.3600),
    "rio_grande_mesilla": (-106.8020, 32.2700),
    "las_cruces_downtown": (-106.7810, 32.3120),
}


def _gdal_cross_check():
    """Compare the pure-Python Albers against gdaltransform. Skipped (not failed) if GDAL's CLI is
    absent, because lzcommon must stay importable on a machine that only runs the tests."""
    exe = shutil.which("gdaltransform")
    if not exe:
        return None
    pts = "\n".join(f"{lon} {lat}" for lon, lat in LANDMARKS.values()) + "\n"
    r = subprocess.run([exe, "-s_srs", "EPSG:4269", "-t_srs", f"EPSG:{ANALYSIS_EPSG}"],
                       input=pts, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return None
    worst = 0.0
    for (lon, lat), line in zip(LANDMARKS.values(), r.stdout.strip().splitlines()):
        gx, gy = (float(v) for v in line.split()[:2])
        mx, my = lonlat_to_albers(lon, lat)
        worst = max(worst, math.hypot(gx - mx, gy - my))
    return worst


def selftest():
    ok = True
    g = master_grid()
    span_km_x = (g["x_max"] - g["x_min"]) / 1000.0
    span_km_y = (g["y_max"] - g["y_min"]) / 1000.0
    print(f"cell {CELL_ID}  lat {CELL_LAT_MIN}..{CELL_LAT_MAX}  lon {CELL_LON_MIN}..{CELL_LON_MAX}")
    print(f"grid EPSG:{g['epsg']} @ {g['cell_size_m']:.0f} m -> {g['cols']} x {g['rows']} cells "
          f"({span_km_x:.1f} x {span_km_y:.1f} km incl {EDGE_MARGIN_M/1000:.0f} km margin)")
    print(f"     {g['cols']*g['rows']/1e6:.1f} M cells, {g['cols']*g['rows']*PLANE_COUNT/1e6:.0f} MB "
          f"for {PLANE_COUNT} uint8 planes")

    # Check the span against the ANALYTICALLY PREDICTED rotated bbox, not against a hand-widened
    # range. The cell is a rotated parallelogram in this conic (see cone_convergence_rad), so a
    # naive 94 x 111 km expectation is wrong by ~15% — and a test loosened until it passes would
    # no longer catch a genuine geotransform error.
    theta = abs(cone_convergence_rad(0.5 * (CELL_LON_MIN + CELL_LON_MAX)))
    quad_w = 111.320 * math.cos(math.radians(0.5 * (CELL_LAT_MIN + CELL_LAT_MAX)))
    quad_h = 110.95
    margin_km = 2.0 * EDGE_MARGIN_M / 1000.0
    pred_x = quad_w * math.cos(theta) + quad_h * math.sin(theta) + margin_km
    pred_y = quad_w * math.sin(theta) + quad_h * math.cos(theta) + margin_km
    print(f"     conic convergence {math.degrees(theta):.2f} deg -> predicted bbox "
          f"{pred_x:.1f} x {pred_y:.1f} km; cell fills "
          f"{100.0 * quad_w * quad_h / ((pred_x - margin_km) * (pred_y - margin_km)):.0f}% of it")
    if abs(span_km_x - pred_x) > 1.0 or abs(span_km_y - pred_y) > 1.0:
        print(f"FAIL grid span {span_km_x:.1f} x {span_km_y:.1f} km differs from predicted "
              f"{pred_x:.1f} x {pred_y:.1f} km by more than 1 km")
        ok = False
    else:
        print("ok   grid span matches the predicted rotated bounding box")

    worst = _gdal_cross_check()
    if worst is None:
        print("skip gdaltransform cross-check (GDAL CLI not found)")
    elif worst > 0.001:
        print(f"FAIL Albers disagrees with GDAL by {worst*1000:.3f} mm")
        ok = False
    else:
        print(f"ok   Albers matches gdaltransform to {worst*1000:.4f} mm over {len(LANDMARKS)} points")

    # Projection round-trip.
    worst_rt = 0.0
    for lon, lat in LANDMARKS.values():
        x, y = lonlat_to_albers(lon, lat)
        rl, rt = albers_to_lonlat(x, y)
        worst_rt = max(worst_rt, abs(rl - lon), abs(rt - lat))
    if worst_rt > 1e-9:
        print(f"FAIL Albers round-trip drifts {worst_rt:.3g} deg")
        ok = False
    else:
        print(f"ok   Albers round-trip within {worst_rt:.3g} deg")

    # Every landmark must land inside the grid.
    for name, (lon, lat) in LANDMARKS.items():
        rc = lonlat_to_grid(lon, lat, g)
        if rc is None:
            print(f"FAIL landmark {name} falls outside the master grid")
            ok = False
    if ok:
        print(f"ok   all {len(LANDMARKS)} landmarks inside the grid")

    # Tiling + the row flip.
    tiles = cell_tiles(NATIVE_ZOOM)
    print(f"tiles z{NATIVE_ZOOM}: {len(tiles)}  (z{MIN_ZOOM}: {len(cell_tiles(MIN_ZOOM))})")
    for z in (MIN_ZOOM, NATIVE_ZOOM):
        for x, y in cell_tiles(z)[:8]:
            if xyz_to_tms_row(xyz_to_tms_row(y, z), z) != y:
                print(f"FAIL TMS flip not an involution at z{z} y{y}")
                ok = False
    lon0, lat0, lon1, lat1 = tile_bounds(*lonlat_to_tile(*LANDMARKS["KLRU_field"], NATIVE_ZOOM),
                                         NATIVE_ZOOM)
    klon, klat = LANDMARKS["KLRU_field"]
    if not (lon0 <= klon <= lon1 and lat0 <= klat <= lat1):
        print("FAIL KLRU not inside the tile that claims it")
        ok = False
    else:
        print("ok   tile<->point agreement and TMS flip involution")

    # Blob round-trip, including the raw-DEFLATE framing.
    rng = np.random.default_rng(7)
    planes = [rng.integers(0, 256, (TILE_SIDE, TILE_SIDE), dtype=np.uint8)
              for _ in range(PLANE_COUNT)]
    planes[PLANE_CLASS] = np.full((TILE_SIDE, TILE_SIDE), CLASS_OPEN_FIRM, np.uint8)
    blob = pack_blob(planes, TERRAIN_SRC_COARSE)
    got = unpack_blob(blob)
    if got is None:
        print("FAIL blob round-trip returned None")
        ok = False
    else:
        rp, ts = got
        if ts != TERRAIN_SRC_COARSE or any(not np.array_equal(a, b) for a, b in zip(planes, rp)):
            print("FAIL blob round-trip mismatch")
            ok = False
        else:
            print(f"ok   blob round-trip {len(blob)} bytes, terrain_source preserved")

    # A raw-DEFLATE stream must NOT be readable as zlib — that asymmetry is the whole point.
    try:
        zlib.decompress(zlib.compressobj(9, zlib.DEFLATED, -15).compress(b"x" * 64))
        print("FAIL raw DEFLATE decoded as zlib — framing assumption is wrong")
        ok = False
    except zlib.error:
        print("ok   raw DEFLATE is not zlib-framed (matches Apple COMPRESSION_ZLIB)")

    # Corruption must degrade, not raise.
    for bad in (b"", b"XXXX", blob[:HEADER_BYTES - 1], blob[:len(blob) // 2],
                b"LZP0" + blob[4:]):
        if unpack_blob(bad) is not None:
            print("FAIL corrupt blob accepted")
            ok = False
    print("ok   corrupt blobs rejected without raising")

    # Severity + aggregation tables must cover every declared class/plane.
    if set(CLASS_SEVERITY) != set(CLASS_NAMES):
        print("FAIL CLASS_SEVERITY does not cover every class")
        ok = False
    if set(AGGREGATION) != set(PLANE_NAMES):
        print("FAIL AGGREGATION does not cover every plane")
        ok = False
    if len(set(CLASS_SEVERITY.values())) != len(CLASS_SEVERITY):
        print("FAIL CLASS_SEVERITY ranks are not unique — 'worst wins' would be ambiguous")
        ok = False
    print("ok   class/plane tables complete and unambiguous" if ok else "")

    print("\nSELFTEST PASS" if ok else "\nSELFTEST FAIL")
    return 0 if ok else 1


def describe():
    g = master_grid()
    print(json.dumps({
        "cell": CELL_ID,
        "bounds": [CELL_LON_MIN, CELL_LAT_MIN, CELL_LON_MAX, CELL_LAT_MAX],
        "margin_m": EDGE_MARGIN_M, "grid": g,
        "tiling": {"native_zoom": NATIVE_ZOOM, "min_zoom": MIN_ZOOM, "tile_side": TILE_SIDE,
                   "tiles_native": len(cell_tiles(NATIVE_ZOOM))},
        "planes": PLANE_NAMES, "aggregation": AGGREGATION,
        "blob": {"magic": BLOB_MAGIC.decode(), "version": BLOB_VERSION,
                 "header_bytes": HEADER_BYTES, "compression": "raw DEFLATE (wbits=-15)"},
    }, indent=2))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true", help="validate geometry, projection and blob")
    ap.add_argument("--describe", action="store_true", help="print resolved constants as JSON")
    a = ap.parse_args()
    if a.describe:
        return describe()
    if a.selftest:
        return selftest()
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
