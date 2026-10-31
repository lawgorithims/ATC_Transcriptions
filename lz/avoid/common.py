"""Shared definitions for the CONUS "where not to go" map (avoid map, v1).

WHAT IT IS. One byte per pixel on the Web Mercator z12 grid (~30 m at mid-latitudes), each bit a
reason NOT to put an aeroplane down there. It paints only avoid reasons. Unpainted ground is not
endorsed: distribution wires, fences, ditches, crops and surface condition are not mapped
anywhere public. It is built from national sources once per night, and is lean: one byte where the
landability packs carried seven planes.

THE GRID. Each 1-degree cell (id = NW corner, e.g. n33w107 covers 32-33 N, 107-106 W) is built on
the z12 tiles that intersect it, but paints only the pixels whose CENTRES fall inside it
(half-open: west/south edges in, east/north edges out). So neighbouring cells never paint the same
pixel, and merging is a plain OR of their tiles.
"""
import math
import os
import struct
import zlib

ZOOM = 12
MIN_ZOOM = 8
TILE = 256
ORIGIN = 20037508.342789244                     # EPSG:3857 half-extent, metres
EARTH_R = 6378137.0
TILE_M = 2 * ORIGIN / (1 << ZOOM)               # 9783.94 m at z12
RES = TILE_M / TILE                             # 38.2185 Mercator metres per pixel

# Reasons, one bit each. COVER is broad ground cover (drawn muted on device); HAZARD is the narrow,
# hidden things that kill in an otherwise good-looking field (drawn strong).
WATER, DEVELOPED, TREES, STEEP = 1, 2, 4, 8
ORCHARD, SOLAR, WIRES, OBSTACLE = 16, 32, 64, 128
COVER = WATER | DEVELOPED | TREES | STEEP
HAZARD = ORCHARD | SOLAR | WIRES | OBSTACLE
BIT_NAMES = {WATER: "water", DEVELOPED: "developed", TREES: "trees", STEEP: "steep",
             ORCHARD: "orchard", SOLAR: "solar", WIRES: "wires", OBSTACLE: "obstacle"}

# Annual NLCD Collection 1.2 classes. 21 (developed, open space: parks, golf courses, verges) is
# deliberately NOT developed here; 95 (emergent wetland: marsh) counts as water.
NLCD_WATER = (11, 95)
NLCD_DEVELOPED = (22, 23, 24)
NLCD_TREES = (41, 42, 43, 90)
NLCD_NODATA = 250

# USDA CDL 2025: tree crops, vines, hops (poles and wire trellis), Christmas trees.
CDL_ORCHARD = (55, 56, 66, 67, 68, 69, 70, 71, 72, 74, 75, 76, 77,
               204, 210, 211, 212, 215, 217, 218, 220, 223)

# Slope is stored per pixel in the cell output (half-degree steps) and thresholded at MERGE, so
# calibrating it never needs the overnight build again. 255 = unknown (no elevation).
SLOPE_STEP_DEG = 0.5
SLOPE_UNKNOWN = 255

# Where the national inputs and the per-cell outputs live. Outside the repo, transient.
WORK = os.environ.get("AVOID_WORK", os.path.expanduser("~/avoid-work"))
SHARED = os.path.join(WORK, "shared")
CELLS = os.path.join(WORK, "cells")
LOGS = os.path.join(WORK, "logs")

CONUS_BBOX = (-125.0, 24.0, -66.0, 50.0)       # lon_w, lat_s, lon_e, lat_n


def parse_cell(cell_id):
    """'n33w107' -> (lat_s, lat_n, lon_w, lon_e) = (32, 33, -107, -106)."""
    assert len(cell_id) == 7 and cell_id[0] in "ns" and cell_id[3] in "ew", f"bad cell id {cell_id}"
    lat_n = int(cell_id[1:3]) * (1 if cell_id[0] == "n" else -1)
    lon_w = int(cell_id[4:7]) * (-1 if cell_id[3] == "w" else 1)
    assert -90 < lat_n <= 90 and -180 <= lon_w < 180, f"cell out of range {cell_id}"
    return lat_n - 1, lat_n, lon_w, lon_w + 1


def tile_x(lon):
    return int(math.floor((lon + 180.0) / 360.0 * (1 << ZOOM)))


def tile_y(lat):
    r = math.radians(lat)
    return int(math.floor((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * (1 << ZOOM)))


def cell_tile_range(cell_id):
    """Inclusive z12 tile ranges (x0, x1, y0, y1) touching the cell."""
    lat_s, lat_n, lon_w, lon_e = parse_cell(cell_id)
    x0, x1 = tile_x(lon_w), tile_x(lon_e - 1e-9)
    y0, y1 = tile_y(lat_n - 1e-9), tile_y(lat_s)
    assert x0 <= x1 and y0 <= y1, "cell_tile_range: empty range"
    return x0, x1, y0, y1


def tile_range_extent(x0, x1, y0, y1):
    """EPSG:3857 (xmin, ymin, xmax, ymax) of an inclusive z12 tile range."""
    xmin = -ORIGIN + x0 * TILE_M
    xmax = -ORIGIN + (x1 + 1) * TILE_M
    ymax = ORIGIN - y0 * TILE_M
    ymin = ORIGIN - (y1 + 1) * TILE_M
    return xmin, ymin, xmax, ymax


def merc_y_to_lat(y):
    return math.degrees(2.0 * math.atan(math.exp(y / EARTH_R)) - math.pi / 2.0)


def merc_x_to_lon(x):
    return x / EARTH_R * 180.0 / math.pi


def lonlat_to_merc(lon, lat):
    lat = max(-85.05112877980659, min(85.05112877980659, lat))
    return (math.radians(lon) * EARTH_R,
            math.log(math.tan(math.pi / 4.0 + math.radians(lat) / 2.0)) * EARTH_R)


# Tile blob: b"AVD1" + raw DEFLATE (wbits -15, as Apple's COMPRESSION_ZLIB expects) of 65,536 bytes.
BLOB_MAGIC = b"AVD1"


def pack_tile(arr):
    assert arr.shape == (TILE, TILE) and arr.dtype.name == "uint8", "pack_tile: wrong tile"
    # Z_RLE, not level 9: on these run-heavy masks level 9 took 118 ms a tile (its match search
    # degenerates on long runs) for 5% less than RLE's 1 ms. Still plain raw DEFLATE to any inflater.
    co = zlib.compressobj(6, zlib.DEFLATED, -15, 8, zlib.Z_RLE)
    return BLOB_MAGIC + co.compress(arr.tobytes()) + co.flush()


def unpack_tile(data):
    """Inverse of pack_tile; None for anything malformed (never raises)."""
    import numpy as np
    if len(data) < 5 or data[:4] != BLOB_MAGIC:
        return None
    try:
        raw = zlib.decompress(data[4:], -15)
    except zlib.error:
        return None
    if len(raw) != TILE * TILE:
        return None
    return np.frombuffer(raw, dtype=np.uint8).reshape(TILE, TILE)


def tms_row(y, z):
    assert 0 <= y < (1 << z), "tms_row: row out of range"
    return (1 << z) - 1 - y


__all__ = [n for n in dir() if not n.startswith("_")] + ["struct"]
