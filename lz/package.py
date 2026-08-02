#!/usr/bin/env python3
"""package.py — Stage 4: cut the fact planes into an .lzpack the app can mount.

WHAT IT MAKES
    lz/out/<cell>.lzpack          MBTiles (SQLite) of per-tile fact blobs, z6..z13
    lz/out/lz_fixture.lzpack      a 4-tile synthetic pack for the iOS unit tests

HOW A TILE IS STORED
    Six uint8 planes at 256x256, each RAW-DEFLATE compressed, behind a fixed header that also
    carries the tile's terrain_source. Layout and quantisation live in lzcommon so the packer and
    the on-device decoder cannot drift.

TWO FRAMING DECISIONS THAT SILENTLY DESTROY THE LAYER
    1. TMS ROWS. `MBTilesReader.tileData` flips XYZ->TMS on read (ChartMapView.swift:62), per the
       MBTiles spec, so this writes TMS. Reversed, the pack still opens with the right tile count
       and renders the cell MIRRORED north-for-south.
    2. RAW DEFLATE. Apple's COMPRESSION_ZLIB has no zlib wrapper. Python's default
       `zlib.compress()` adds two bytes the device rejects, and the failure is not an error — it
       is a fully transparent layer, which a pilot reads as "no risk here".

RESAMPLING IS PER-PLANE, AND CONSERVATIVE
    Going from the 10 m analysis grid to z13 (~19 m at this latitude) is a DOWNSAMPLE, so the
    choice of resampler is a safety decision, not a quality one:
        class  -> mode     (a code; averaging invents category 47 between 41 and 52)
        conf   -> min      (the least confident child governs)
        slope  -> max      (a cliff inside the cell is the cell)
        rough  -> max
        hazard -> max      (never average a tower away)
        flags  -> per-BIT max, then recombined = a true OR
    `flags` gets special handling because max() on a packed bitfield is meaningless: 0b0010 vs
    0b0001 would resolve to 0b0010 and drop the other flag entirely. Each bit is warped as its own
    0/1 band and the results are OR'd back together.

OVERVIEWS REDUCE BY RULE, NEVER BY AVERAGE
    z12..z6 are 2x2 reductions per lzcommon.AGGREGATION: worst-child for POINT hazards, but
    second-worst for the AREAL planes (slope/rough/class), because a lone arroyo bank must not
    condemn a 2 km parent of flat basin floor. `unknown` still outranks the good classes: "we do
    not know" must not be diluted by confident neighbours.

THE FIXTURE CARRIES A COARSE TILE ON PURPOSE
    3DEP 1 m covers 100% of n33w107, so the real pack is FINE everywhere and the coarse-DEM cap
    — the rule that stops un-vetoable 10 m terrain from outscoring lidar-covered ground — is not
    exercised by any tile in it. The fixture therefore includes a synthetic COARSE tile so the
    device test can still prove that cap fires.

USAGE
    python3 lz/package.py --build
    python3 lz/package.py --fixture
"""

import argparse
import json
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C  # noqa: E402

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: python3 -m pip install numpy")

try:
    from osgeo import gdal, osr
except ImportError:
    sys.exit("the GDAL Python bindings are required")

gdal.UseExceptions()

WEBMERC_HALF = 20037508.342789244
PACK_MAX_BYTES = 200 << 20          # hard fail: a pack this big is a bug, not a big cell

# Per-plane resampling from the 10 m analysis grid to the z13 web-mercator grid.
# How each plane resamples from the 10 m analysis grid onto Web-Mercator z13. Every rule here is
# the CONSERVATIVE direction for that plane — which for extent is `min`, because less room is the
# bad news, exactly inverting the `max` that slope, roughness and hazard use.
PLANE_RESAMPLE = {"class": "mode", "conf": "min", "slope": "max",
                  "rough": "max", "hazard": "max", "flags": "bitwise_or",
                  "extent": "min"}


def _wd():
    return os.path.join(C.WORK_DIR, C.CELL_ID)


def tile_extent_3857(x, y, z):
    n = 1 << z
    size = 2.0 * WEBMERC_HALF / n
    return (-WEBMERC_HALF + x * size, WEBMERC_HALF - (y + 1) * size,
            -WEBMERC_HALF + (x + 1) * size, WEBMERC_HALF - y * size)


def _ensure_extent(workdir):
    """Build the extent plane if it is not there, OR if it is older than what it was derived from.

    Deliberately self-healing rather than a hard requirement. This plane arrived after the cell
    queue was already running, and an orchestration script that predates it should produce a
    CORRECT pack, not a malformed one or a failed stage 40 minutes into a cell. It costs 8 seconds
    over an already-mosaicked cell, so there is no reason to make anyone remember it.

    ⚠️ EXISTENCE IS NOT FRESHNESS. Checking only `os.path.exists` made this cache a liar the moment
    a cell was rebuilt: n35w108's terrain was rebuilt after a failed DEM stream, and the packer
    happily reused the extent plane derived from the BROKEN slope — so the corrected pack still
    said the whole cell had nowhere to land, at the right file size, with nothing in the log but a
    line saying the plane was already present. Rebuild whenever an input is newer."""
    path = os.path.join(workdir, "extent.npy")
    inputs = [os.path.join(workdir, n) for n in ("class.npy", "slope.npy")]
    if os.path.exists(path):
        mine = os.path.getmtime(path)
        stale = [p for p in inputs if os.path.exists(p) and os.path.getmtime(p) > mine]
        if not stale:
            return
        print("   extent.npy is older than "
              + ", ".join(os.path.basename(p) for p in stale) + " — rebuilding it (8s)")
    else:
        print("   extent.npy absent — building it (8s)")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import extent as _extent
    rc = _extent.build(workdir)
    assert rc == 0 and os.path.exists(path), "package: extent plane could not be built"


def load_planes():
    """Assemble the planes at analysis resolution, quantised per lzcommon."""
    wd = _wd()
    _ensure_extent(wd)
    need = ["class.npy", "conf.npy", "slope.npy", "rough.npy", "hazard.npy", "flags.npy",
            "terrain_src.npy"]
    for n in need:
        if not os.path.exists(os.path.join(wd, n)):
            sys.exit(f"missing {n} — run terrain/surface/hazard first")

    cls = np.load(os.path.join(wd, "class.npy"))
    conf = np.load(os.path.join(wd, "conf.npy"))
    hazard = np.load(os.path.join(wd, "hazard.npy"))
    flags = np.load(os.path.join(wd, "flags.npy"))
    tsrc = np.load(os.path.join(wd, "terrain_src.npy"))
    extent = np.load(os.path.join(wd, "extent.npy"))

    slope_f = np.load(os.path.join(wd, "slope.npy"))
    rough_f = np.load(os.path.join(wd, "rough.npy"))

    # Quantise. NaN (no DEM) becomes the nodata byte — never 0, which would read as "flat".
    with np.errstate(all="ignore"):
        slope = np.where(np.isfinite(slope_f),
                         np.clip(np.rint(slope_f / C.SLOPE_STEP_DEG), 0, 254),
                         C.SLOPE_NODATA).astype(np.uint8)
        rough = np.where(np.isfinite(rough_f),
                         np.clip(np.rint(rough_f * 100.0), 0, 254),
                         C.ROUGH_NODATA).astype(np.uint8)
    planes = {"class": cls, "conf": conf, "slope": slope, "rough": rough,
              "hazard": hazard, "flags": flags, "extent": extent}
    # The dict is indexed by C.PLANE_NAMES downstream, so a plane added to lzcommon and forgotten
    # here would KeyError at pack time rather than ship a pack missing a plane.
    missing = [n for n in C.PLANE_NAMES if n not in planes]
    assert not missing, f"load_planes: no data for plane(s) {missing}"
    return planes, tsrc


def _mem_raster(arr, gt, wkt, dtype=gdal.GDT_Byte):
    drv = gdal.GetDriverByName("MEM")
    ds = drv.Create("", arr.shape[1], arr.shape[0], 1, dtype)
    ds.SetGeoTransform(gt)
    ds.SetProjection(wkt)
    ds.GetRasterBand(1).WriteArray(arr)
    return ds


def warp_to_z13(planes, tsrc):
    """Warp every plane onto the z13 web-mercator grid, aligned to tile boundaries."""
    g = C.master_grid()
    src_srs = osr.SpatialReference()
    src_srs.ImportFromEPSG(C.ANALYSIS_EPSG)
    dst_srs = osr.SpatialReference()
    dst_srs.ImportFromEPSG(3857)
    gt = g["geotransform"]

    tiles = C.cell_tiles(C.NATIVE_ZOOM)
    xs = sorted({t[0] for t in tiles})
    ys = sorted({t[1] for t in tiles})
    x0, x1, y0, y1 = xs[0], xs[-1], ys[0], ys[-1]
    left, _, _, top = tile_extent_3857(x0, y0, C.NATIVE_ZOOM)
    _, bottom, right, _ = tile_extent_3857(x1, y1, C.NATIVE_ZOOM)
    res = (2.0 * WEBMERC_HALF / (1 << C.NATIVE_ZOOM)) / C.TILE_SIDE
    print(f"  z{C.NATIVE_ZOOM} grid: x {x0}..{x1}, y {y0}..{y1} "
          f"({len(xs)}x{len(ys)} tiles, {res:.3f} m/px)")

    out = {}
    for name, arr in planes.items():
        alg = PLANE_RESAMPLE[name]
        if alg == "bitwise_or":
            acc = None
            for bit in sorted(C.FLAG_NAMES):
                band = ((arr & bit) != 0).astype(np.uint8)
                w = gdal.Warp("", _mem_raster(band, gt, src_srs.ExportToWkt()), format="MEM",
                              dstSRS=dst_srs.ExportToWkt(), resampleAlg="max",
                              outputBounds=(left, bottom, right, top), xRes=res, yRes=res)
                b = w.ReadAsArray().astype(np.uint8)
                acc = (b * bit) if acc is None else (acc | (b * bit))
                w = None
            out[name] = acc
        else:
            w = gdal.Warp("", _mem_raster(arr, gt, src_srs.ExportToWkt()), format="MEM",
                          dstSRS=dst_srs.ExportToWkt(), resampleAlg=alg,
                          outputBounds=(left, bottom, right, top), xRes=res, yRes=res)
            out[name] = w.ReadAsArray().astype(np.uint8)
            w = None

    ts = gdal.Warp("", _mem_raster(tsrc, gt, src_srs.ExportToWkt()), format="MEM",
                   dstSRS=dst_srs.ExportToWkt(), resampleAlg="max",
                   outputBounds=(left, bottom, right, top), xRes=res, yRes=res)
    tsrc_z13 = ts.ReadAsArray().astype(np.uint8)
    ts = None
    return out, tsrc_z13, (x0, y0)


def cut_tiles(planes_z13, tsrc_z13, origin):
    """Slice the warped mosaic into 256x256 tiles keyed (z, x, y) in XYZ."""
    x0, y0 = origin
    h, w = next(iter(planes_z13.values())).shape
    nx, ny = w // C.TILE_SIDE, h // C.TILE_SIDE
    tiles = {}
    for ty in range(ny):
        for tx in range(nx):
            r0, c0 = ty * C.TILE_SIDE, tx * C.TILE_SIDE
            sl = (slice(r0, r0 + C.TILE_SIDE), slice(c0, c0 + C.TILE_SIDE))
            planes = [planes_z13[n][sl].copy() for n in C.PLANE_NAMES]
            # A tile with no land-cover information at all is not shipped: an all-unknown tile
            # costs bytes and tells the pilot nothing the absence of a tile does not.
            if not planes[C.PLANE_CLASS].any():
                continue
            sub = tsrc_z13[sl]
            ts = int(sub.max()) if sub.size else C.TERRAIN_SRC_COARSE
            tiles[(C.NATIVE_ZOOM, x0 + tx, y0 + ty)] = (planes, ts)
    return tiles


def aggregate(children):
    """2x2 -> 1 reduction. Worst child wins, per lzcommon.AGGREGATION."""
    assert len(children) == 4, "aggregate: expected four child quadrants"
    out = []
    for i, name in enumerate(C.PLANE_NAMES):
        quad = [c[i] for c in children]
        big = np.zeros((C.TILE_SIDE * 2, C.TILE_SIDE * 2), np.uint8)
        big[:C.TILE_SIDE, :C.TILE_SIDE] = quad[0]
        big[:C.TILE_SIDE, C.TILE_SIDE:] = quad[1]
        big[C.TILE_SIDE:, :C.TILE_SIDE] = quad[2]
        big[C.TILE_SIDE:, C.TILE_SIDE:] = quad[3]
        b = big.reshape(C.TILE_SIDE, 2, C.TILE_SIDE, 2).transpose(0, 2, 1, 3) \
               .reshape(C.TILE_SIDE, C.TILE_SIDE, 4)
        rule = C.AGGREGATION[name]
        if rule == "max":
            out.append(b.max(axis=2))
        elif rule == "min":
            out.append(b.min(axis=2))
        elif rule == "or":
            out.append(np.bitwise_or.reduce(b, axis=2))
        elif rule == "second_min":
            # EXTENT's bad direction is DOWN — less room. Runner-up from the bottom, for the same
            # reason second_max exists above: a plain min compounds down the pyramid until every
            # parent reports the tightest corner of its sixteen grandchildren and a mile-wide field
            # reads as unusable at z8.
            out.append(np.sort(b, axis=2)[:, :, 1])
        elif rule == "second_max":
            # Runner-up of the four: keeps ground that is bad across most of the parent, drops the
            # single outlier. See the AGGREGATION note in lzcommon for the measurements.
            out.append(np.sort(b, axis=2)[:, :, -2])
        elif rule == "worst_severity" or rule == "second_worst_severity":
            sev = np.zeros(256, np.uint8)
            for k, v in C.CLASS_SEVERITY.items():
                sev[k] = v
            order = np.argsort(sev[b], axis=2)
            pick = -1 if rule == "worst_severity" else -2
            idx = order[:, :, pick]
            out.append(np.take_along_axis(b, idx[..., None], axis=2)[..., 0])
        else:
            raise AssertionError(f"unknown aggregation rule {rule}")
    return out


def build_pyramid(tiles):
    """Fold z13 upward to MIN_ZOOM. A missing child contributes 'unknown', not 'good'."""
    # DERIVED from PLANE_NAMES, not hand-listed. This was a positional literal of six arrays, so
    # adding a seventh plane to lzcommon left it one short and the pyramid died with an IndexError
    # deep in aggregate(). A missing child must contribute the WORST value each plane can hold:
    # unknown cover, unknown confidence, no slope or roughness reading, no flags — and, for extent,
    # ZERO room, because "we have no data here" must never fold upward as "there is space".
    blank_fill = {
        "class": C.CLASS_UNKNOWN, "conf": C.CONF_UNKNOWN,
        "slope": C.SLOPE_NODATA, "rough": C.ROUGH_NODATA,
        "hazard": 0, "flags": 0, "extent": 0,
    }
    missing_fill = [n for n in C.PLANE_NAMES if n not in blank_fill]
    assert not missing_fill, f"build_pyramid: no blank value for plane(s) {missing_fill}"
    blank = [np.full((C.TILE_SIDE, C.TILE_SIDE), blank_fill[n], np.uint8) for n in C.PLANE_NAMES]
    for z in range(C.NATIVE_ZOOM, C.MIN_ZOOM, -1):
        parents = {}
        for (tz, tx, ty) in [k for k in tiles if k[0] == z]:
            parents.setdefault((z - 1, tx // 2, ty // 2), True)
        for (pz, px, py) in parents:
            kids, tss = [], []
            for dy in (0, 1):
                for dx in (0, 1):
                    k = (pz + 1, px * 2 + dx, py * 2 + dy)
                    if k in tiles:
                        kids.append(tiles[k][0])
                        tss.append(tiles[k][1])
                    else:
                        kids.append(blank)
            # order must be NW, NE, SW, SE to match aggregate()'s quadrant placement
            kids = [kids[0], kids[1], kids[2], kids[3]]
            tiles[(pz, px, py)] = (aggregate(kids),
                                   max(tss) if tss else C.TERRAIN_SRC_COARSE)
    return tiles


def write_mbtiles(path, tiles, meta):
    if os.path.exists(path):
        os.remove(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("create table metadata (name text, value text)")
    db.execute("create table tiles (zoom_level integer, tile_column integer, "
               "tile_row integer, tile_data blob)")
    db.execute("create unique index tile_index on tiles "
               "(zoom_level, tile_column, tile_row)")
    for k, v in meta.items():
        db.execute("insert into metadata values (?,?)", (k, str(v)))
    n = 0
    for (z, x, y), (planes, ts) in sorted(tiles.items()):
        blob = C.pack_blob(planes, ts)
        # TMS row — see the framing note in the module docstring.
        db.execute("insert into tiles values (?,?,?,?)",
                   (z, x, C.xyz_to_tms_row(y, z), sqlite3.Binary(blob)))
        n += 1
    db.commit()
    db.close()
    return n


def _vintages():
    m = C.load_manifest()["sources"]
    return {k: {"vintage": v.get("vintage"), "status": v.get("status"),
                "licence": v.get("licence")} for k, v in sorted(m.items())}


def cmd_build():
    planes, tsrc = load_planes()
    print("  planes loaded at analysis resolution")
    z13, tsrc_z13, origin = warp_to_z13(planes, tsrc)
    tiles = cut_tiles(z13, tsrc_z13, origin)
    print(f"  z{C.NATIVE_ZOOM}: {len(tiles)} tiles with data")
    tiles = build_pyramid(tiles)
    by_z = {}
    for (z, _, _) in tiles:
        by_z[z] = by_z.get(z, 0) + 1
    print("  pyramid: " + ", ".join(f"z{z}={by_z[z]}" for z in sorted(by_z)))

    coarse = sum(1 for v in tiles.values() if v[1] != C.TERRAIN_SRC_FINE)
    meta = {
        "name": f"CommSight LZ {C.CELL_ID}", "format": "bin", "type": "overlay", "version": "1",
        "minzoom": C.MIN_ZOOM, "maxzoom": C.NATIVE_ZOOM,
        "bounds": f"{C.CELL_LON_MIN},{C.CELL_LAT_MIN},{C.CELL_LON_MAX},{C.CELL_LAT_MAX}",
        "lz_schema": C.LZ_SCHEMA, "lz_planes": ",".join(C.PLANE_NAMES),
        "lz_cell": C.CELL_ID, "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "lz_vintages": json.dumps(_vintages()),
        "lz_terrain_source_coarse_tiles": coarse,
        "attribution": "Terrain/land cover: USGS, USDA, USFWS (public domain). "
                       "Canopy height: Meta/WRI (CC-BY-4.0). Advisory only — not for navigation.",
    }
    out = os.path.join(C.OUT_DIR, f"{C.CELL_ID}.lzpack")
    n = write_mbtiles(out, tiles, meta)
    size = os.path.getsize(out)
    print(f"\nwrote {out}\n  {n} tiles, {size/1e6:.1f} MB, "
          f"{coarse} coarse-terrain tiles")
    if size > PACK_MAX_BYTES:
        print(f"FAIL pack exceeds {PACK_MAX_BYTES/1e6:.0f} MB")
        return 1
    return 0


def cmd_fixture():
    """A tiny deterministic pack for the iOS unit tests.

    Deliberately includes a COARSE tile: the real cell is 100% 1 m lidar, so nothing in the
    shipping pack exercises the coarse-DEM cap, and an untested safety rule is a broken one."""
    side = C.TILE_SIDE
    tiles = {}
    base_z, base_x, base_y = 13, 1000, 2000

    def plane_set(cls_val, conf_val, slope_val, rough_val, hz_val, flag_val, extent_val=255):
        """Built from PLANE_NAMES so a plane added to lzcommon cannot be silently omitted here —
        the fixture is the CROSS-LANGUAGE contract, and one short of a full set makes every Swift
        decode test fail with a plane-count error rather than saying what is actually missing.

        `extent_val` defaults to saturated ("more room than anything can use"), so the existing
        fixtures keep testing what they were written to test: adding a dimension must not silently
        re-verdict tiles that were about surface, hazard or terrain source."""
        values = {"class": cls_val, "conf": conf_val, "slope": slope_val, "rough": rough_val,
                  "hazard": hz_val, "flags": flag_val, "extent": extent_val}
        missing = [n for n in C.PLANE_NAMES if n not in values]
        assert not missing, f"fixture plane_set: no value for {missing}"
        return [np.full((side, side), values[n], np.uint8) for n in C.PLANE_NAMES]

    # 1. clean open field, fine terrain — should score well
    tiles[(base_z, base_x, base_y)] = (plane_set(C.CLASS_OPEN_FIRM, 80, 10, 5, 0, 0),
                                       C.TERRAIN_SRC_FINE)
    # 2. water — a veto class
    tiles[(base_z, base_x + 1, base_y)] = (plane_set(C.CLASS_WATER, 90, 0, 0, 0,
                                                     C.FLAG_WATER_VETO), C.TERRAIN_SRC_FINE)
    # 3. identical to (1) but COARSE terrain — must be capped below it on device
    tiles[(base_z, base_x, base_y + 1)] = (plane_set(C.CLASS_OPEN_FIRM, 80, 10, 5, 0,
                                                     C.FLAG_COARSE_TERRAIN),
                                           C.TERRAIN_SRC_COARSE)
    # 4. good ground with a charted wire beside it — hazard must dominate surface
    tiles[(base_z, base_x + 1, base_y + 1)] = (plane_set(C.CLASS_OPEN_FIRM, 80, 10, 5, 220,
                                                         C.FLAG_TX_CORRIDOR), C.TERRAIN_SRC_FINE)
    # 5. THE EXTENT CASE: ground identical to (1) in every other plane, but only 80 m of open run.
    #    Same class, same slope, same roughness, same hazard — so before the extent plane existed
    #    this was indistinguishable from the middle of a mile-wide field. It must now score lower
    #    for any aeroplane that needs more than 80 m, and identically for one that does not.
    tiles[(base_z, base_x + 2, base_y)] = (plane_set(C.CLASS_OPEN_FIRM, 80, 10, 5, 0, 0,
                                                     extent_val=8),      # 8 * 10 m = 80 m
                                           C.TERRAIN_SRC_FINE)

    # a distinctive corner pixel so a decode test can prove orientation survived the TMS flip
    tiles[(base_z, base_x, base_y)][0][C.PLANE_CLASS][0, 0] = C.CLASS_DEVELOPED_OPEN
    tiles[(base_z, base_x, base_y)][0][C.PLANE_CLASS][side - 1, side - 1] = C.CLASS_BRUSH

    meta = {"name": "CommSight LZ fixture", "format": "bin", "type": "overlay", "version": "1",
            "minzoom": base_z, "maxzoom": base_z, "bounds": "-107,32,-106,33",
            "lz_schema": C.LZ_SCHEMA, "lz_planes": ",".join(C.PLANE_NAMES),
            "lz_cell": "fixture", "built_at": "2026-01-01T00:00:00Z",
            "lz_fixture_corner_nw": C.CLASS_DEVELOPED_OPEN,
            "lz_fixture_corner_se": C.CLASS_BRUSH,
            "attribution": "synthetic test fixture"}
    out = os.path.join(C.OUT_DIR, "lz_fixture.lzpack")
    n = write_mbtiles(out, tiles, meta)
    print(f"wrote {out}: {n} tiles ({os.path.getsize(out)} bytes)")
    print("  includes 1 COARSE tile — the shipping cell is 100% fine, so the cap needs this")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--fixture", action="store_true")
    C.add_cell_argument(ap)
    a = ap.parse_args()
    C.select_cell(a.cell)          # before ANY path, window or URL is built

    rc = 0
    if a.build:
        rc |= cmd_build()
    if a.fixture:
        rc |= cmd_fixture()
    if not (a.build or a.fixture):
        ap.print_help()
    return rc


if __name__ == "__main__":
    sys.exit(main())
