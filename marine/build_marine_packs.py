#!/usr/bin/env python3
"""build_marine_packs.py — NOAA ENC cells → one vector-tile MBTiles per region.

    ./build_marine_packs.py --index enc_index.json --out /tmp/marine/out [--region puget_sound]

Pipeline, per region:

    cells in region ──(GDAL API, field-filtered)──▶ one GeoPackage per usage band
                   ──(ogr2ogr -f MVT)────────────▶ one MBTiles per band, at that band's zooms
                   ──(SQLite merge)──────────────▶ <region>.mbtiles

The merge is lossless because `encspec.BAND_ZOOM` windows do not overlap: no two band packs can
ever produce the same (zoom_level, tile_column, tile_row), so the tiles tables concatenate without
a single collision or precedence decision. That property is the reason the windows are disjoint —
it is not an accident worth breaking later for slightly better generalisation.

WHY VECTOR TILES AND NOT RASTER
A raster chart is a picture of a hazard; a vector tile carries the hazard as data. The overhead
cable that kills floatplanes is only useful if the app can say "cable, 46 ft" — or, far more often,
"cable, clearance not charted" — and can answer that against the aircraft in the pilot's profile.
Vector tiles also let the client render a seaplane view instead of a mariner's chart, and MapLibre
(the app's primary engine, `useMapLibreMap` defaults true) renders them natively.

GUARDS. Every one of these is here because its absence lost real data — and four of them were
rewritten after an audit showed the first versions could not fire at all. A guard that cannot fire
is worse than no guard, because it reads as coverage.

  * ASSIGNMENT: every indexed cell must fall in at least one region (37 IFR-low packs and 1,543
    airspace features were lost to silent omission before this class of rule existed).
  * COVERAGE: and — separately — no cell at band >= 4 may have charted footprint outside every
    region. These are different questions. Assignment only asks whether a bbox touches a region,
    but data is cut per feature, so a cell could be assigned and still have its water in a hole
    between boxes. That is not hypothetical: the SE corner of Kodiak Island fell between two
    regions and 8,936 approach/harbour-scale features, including 87 charted underwater rocks, were
    in no pack while the build reported success.
  * THE SPATIAL FILTER USES THE CLIP ENVELOPE, not the tight region box. When they differed, every
    feature living only in the 0.25-degree margin ring was dropped — 13,512 features, among them
    349 UWTROC and 120 OBSTRN — from packs that still advertised bounds covering that ring.
  * RECONCILIATION IS PER CELL, against that cell's own index counts, and only for cells wholly
    inside the region. Summing into one shared counter made it vacuous: features from edge cells
    masked a contained cell losing everything.
  * HAZARDS ARE LOOKED FOR IN REAL TILES. verify_hazards_reach_the_tiles() takes features out of
    the GeoPackage, computes the tile each must occupy, and decodes it. The previous check only
    asked whether the layer NAME appeared in the merged metadata, and was gated on a count the
    builder itself produced — so a loss upstream of the tiler zeroed the expectation and switched
    the guard off, in exactly the incident it was written for.
  * THE BOUNDS CHECK READS THE PRE-CLAMP EXTENT (`data_bounds`). Checking the clamped value against
    the clamp window was arithmetically incapable of failing.
  * A PACK MUST NOT ADVERTISE AN EMPTY ZOOM WINDOW. Bands own exclusive zoom ranges, so a region
    with no cells in a middle band yields a pack whose minzoom..maxzoom spans zooms holding no
    tiles; MapLibre asks for them and draws nothing.
  * AN UNDATED ARTIFACT IS NEVER WRITTEN — the date comes from the cells' own DSID_ISDT, so a pack
    built from a stale download cannot label itself current.
  * AN INPUT FLOOR separates "this region has no coverage" from "the download failed".
  * A REJECTED PACK IS QUARANTINED as <region>.mbtiles.rejected. Printing "ABORT" and leaving a
    fully-stamped pack in the output directory is how a rejected pack reaches devices: publish.py
    globs that directory and cannot tell one from a clean build.
"""
import argparse
import gzip
import json
import math
import os
import shutil
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import encspec  # noqa: E402

os.environ["OGR_S57_OPTIONS"] = encspec.OGR_S57_OPTIONS
from osgeo import gdal, ogr, osr  # noqa: E402

gdal.UseExceptions()
gdal.PushErrorHandler("CPLQuietErrorHandler")

HERE = os.path.dirname(os.path.abspath(__file__))
# Shortfall tolerance when reconciling written features against the index's own counts.
#
# ⚠️ The reconciliation only considers cells whose footprint lies WHOLLY INSIDE the region box.
# The index counts features per whole cell, so for a cell that merely overlaps the region the
# expected number is simply unknown — a band-1 overview cell runs from Mexico to Alaska and
# legitimately contributes none of its 54 obstructions to Puget Sound. Comparing against those
# cells produced two false ABORTs on the first run, which is worse than no check: a guard that
# cries wolf on correct output is a guard people learn to pass with --force.
#
# For a wholly-contained cell there is nothing to clip, so ANY shortfall is a real defect.
SHORTFALL_ABORT = 0.02

# The 2026-10-21 set has 7,303 cells. See the input floor in main().
MIN_EXPECTED_CELLS = int(os.environ.get("MARINE_MIN_CELLS", "6000"))

# Both of these now live in encspec, which is free of third-party imports, so that publish.py can
# use them without pulling in GDAL — see the note beside them there.
CLIP_MARGIN_DEG = encspec.CLIP_MARGIN_DEG
load_regions = encspec.load_regions


def _box(b):
    ring = ogr.Geometry(ogr.wkbLinearRing)
    for x, y in ((b[0], b[1]), (b[2], b[1]), (b[2], b[3]), (b[0], b[3]), (b[0], b[1])):
        ring.AddPoint_2D(x, y)
    g = ogr.Geometry(ogr.wkbPolygon)
    g.AddGeometry(ring)
    return g


def assert_regions_cover_detailed_cells(cells, regions, min_band=4, tol=0.001):
    """Abort when a cell at `min_band` or finer has charted footprint outside EVERY region box.

    ⚠️ THIS IS A DIFFERENT QUESTION FROM assign_cells(), AND THE DIFFERENCE COST REAL DATA.
    assign_cells only asks whether a cell's bbox *touches* some region. But the data is cut per
    FEATURE against each region box, so a cell can be assigned to a region and still have part of
    its charted area in a hole between boxes — dropped from every pack while the build reports
    success. An audit found exactly that: the south-east corner of Kodiak Island fell between
    southcentral_alaska (which began at 57.5 N) and southwest_alaska (which ended at -152.5), so
    87 charted underwater rocks and 6 obstructions were in no pack at all. Ten band>=4 cells were
    affected, 8,936 approach/harbour-scale features in total.

    Only bands 4-6 are enforced. Bands 1-3 are overview and general cells whose footprints are
    whole oceans by nature — demanding full coverage of them would mean defining regions across the
    entire Pacific to serve open water at z4-11, which nothing asks for. Their uncovered area is
    REPORTED so the decision stays visible rather than becoming an unexamined exemption.
    """
    union = None
    for r in regions:
        g = _box(r["bbox"])
        union = g if union is None else union.Union(g)
    if union is None:
        sys.exit("no regions to cover anything with")

    bad, coarse = [], 0
    for c in cells:
        g = _box(c["bbox"])
        area = g.GetArea()
        if area <= 0:
            continue
        try:
            out = g.Difference(union)
        except Exception:
            continue
        if out is None or out.IsEmpty():
            continue
        frac = out.GetArea() / area
        if frac <= tol:
            continue
        if c["band"] >= min_band:
            bad.append((c, frac, out.GetEnvelope()))
        else:
            coarse += 1
    if coarse:
        print(f"   ·  {coarse} overview/coastal cell(s) (band < {min_band}) extend beyond every "
              f"region box; open water at those scales is intentionally not served")
    if bad:
        print(f"\n!! {len(bad)} cell(s) at band >= {min_band} have charted footprint in NO region. "
              f"Their data would be cut away by every pack while the build reported success:",
              file=sys.stderr)
        for c, frac, env in bad[:20]:
            x0, x1, y0, y1 = env
            print(f"     {c['ident']}  band {c['band']}  {frac*100:.1f}% outside  "
                  f"hole lon {x0:.2f}..{x1:.2f} lat {y0:.2f}..{y1:.2f}", file=sys.stderr)
        print("   Widen a region in marine/regions.conf to cover them.", file=sys.stderr)
        sys.exit(f"{len(bad)} cell(s) at band >= {min_band} have charted area outside every region")


def overlaps(a, b):
    """Edge-inclusive bbox overlap. Touching counts, because region boxes are meant to abut."""
    return not (a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1])


def assign_cells(cells, regions):
    """Map region name → cells overlapping it. Aborts if any cell lands in no region."""
    out = {r["name"]: [] for r in regions}
    orphans = []
    for c in cells:
        hit = [r["name"] for r in regions if overlaps(c["bbox"], r["bbox"])]
        if not hit:
            orphans.append(c)
        for name in hit:
            out[name].append(c)
    if orphans:
        print(f"\n!! {len(orphans)} ENC cell(s) fall in NO region — refusing to build a pack set "
              f"that silently omits charted water:", file=sys.stderr)
        for c in orphans[:25]:
            b = c["bbox"]
            print(f"     {c['ident']}  band {c['band']}  bbox {b[0]:.3f},{b[1]:.3f} "
                  f"{b[2]:.3f},{b[3]:.3f}", file=sys.stderr)
        if len(orphans) > 25:
            print(f"     … and {len(orphans)-25} more", file=sys.stderr)
        print("   Add or widen a region in marine/regions.conf to cover them.", file=sys.stderr)
        sys.exit(f"{len(orphans)} ENC cell(s) fall in NO region — refusing to build a pack set "
                 f"that silently omits charted water")
    return out


def clip_geom(bbox, margin=CLIP_MARGIN_DEG):
    w, s, e, n = bbox
    ring = ogr.Geometry(ogr.wkbLinearRing)
    for x, y in ((w - margin, s - margin), (e + margin, s - margin),
                 (e + margin, n + margin), (w - margin, n + margin), (w - margin, s - margin)):
        ring.AddPoint_2D(max(-180.0, min(180.0, x)), max(-90.0, min(90.0, y)))
    poly = ogr.Geometry(ogr.wkbPolygon)
    poly.AddGeometry(ring)
    return poly


def build_band_gpkg(cells, band, bbox, gpkg_path):
    """Copy the spec's layers/fields out of every cell of one band into a single GeoPackage.

    Returns (counts, per_cell, unreadable) where counts is {layer: n}, per_cell is
    {cell_ident: {layer: n}} and unreadable is [(ident, reason)].

    `per_cell` exists so the shortfall reconciliation can compare a cell against ITS OWN index
    counts. The first version summed everything into one per-layer counter and compared it against
    the expectation of only the wholly-contained cells — which an audit showed to be vacuous, since
    features from every edge-overlapping cell inflate the same counter. A wholly-contained cell
    could lose 100% of its features and the check would still read a comfortable surplus.

    Fields are intersected with each cell's real schema — see the warning in encspec.LAYERS about
    -select on an absent field emitting zero features silently.
    """
    if os.path.exists(gpkg_path):
        os.remove(gpkg_path)
    drv = ogr.GetDriverByName("GPKG")
    dst = drv.CreateDataSource(gpkg_path)
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(4326)
    srs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)

    made = {}          # layer name -> (ogr layer, [field names])
    counts = {}
    per_cell = {}
    unreadable = []
    clip_failures = []
    clip = clip_geom(bbox)
    # ⚠️ THE SPATIAL FILTER MUST USE THE CLIP ENVELOPE, NOT THE TIGHT REGION BOX.
    # These were different for one release and it silently deleted data. OGR's rect filter drops
    # any feature whose geometry is disjoint from the rect, so filtering on the tight box meant a
    # feature living only in the 0.25-degree margin ring was never read at all — the margin that
    # exists to "keep edge features whole enough to meet the neighbouring region without a seam"
    # instead removed everything that lived solely in the ring. Measured across the 2026-10-21 set:
    # 13,512 features gone, among them 349 UWTROC (charted underwater rocks) and 120 OBSTRN, in a
    # pack that still advertised bounds covering the water those rocks are in.
    fx0, fx1, fy0, fy1 = clip.GetEnvelope()
    filter_rect = (fx0, fy0, fx1, fy1)
    # The clip is an AXIS-ALIGNED RECTANGLE, so a feature whose envelope sits inside that
    # rectangle is itself inside it — exactly, not approximately. That makes an O(1) envelope
    # comparison a drop-in replacement for clip.Contains(g), which calls into GEOS and costs time
    # proportional to the vertex count.
    #
    # ⚠️ This is a correctness-preserving fast path only because the clip is a rectangle. If
    # clip_geom() ever returns a non-rectangular polygon (an M_COVR cutline, say), DELETE this
    # path: bbox-inside-polygon does not imply geometry-inside-polygon for a concave shape, and
    # features would be carried through unclipped.
    #
    # Worth having, but small: measured over 15,003 real inland_rivers geometries it is 10x faster
    # than clip.Contains (192 ms -> 19 ms) and agreed with it on every single one, with a 100%
    # hit rate — not one of those features needed clipping.
    #
    # ⚠️ IT DOES NOT EXPLAIN inland_rivers. That region took 9,815 s against 7-462 s for every
    # other region in the 2026-10-21 North America build, 60% of the whole build. This fast path
    # is worth about 6 s of it. The containment test was the author's hypothesis and the
    # measurement refuted it; do not go looking here again.
    #
    # The remaining suspect is the MVT writer, whose cost scales with the number of TILES each
    # feature touches rather than the feature count. inland_rivers carries 477k features in 147k
    # tiles — both mid-range — but they are Mississippi-system river and depth polygons that run
    # for tens of kilometres, so a single one intersects hundreds of z16 tiles and is re-clipped
    # into every one. southeast_alaska has MORE tiles (199k) and built in 462 s because its
    # harbour features are compact. That is inherent to the data rather than a defect, so any fix
    # means splitting long geometries before tiling — unmeasured, and not attempted here.
    for c in cells:
        # gdal.UseExceptions() is on, so ogr.Open RAISES on a bad cell rather than returning None.
        # An `if src is None` branch here was dead code, and one truncated cell therefore aborted
        # an entire multi-region run with a traceback that did not even name the cell.
        try:
            src = ogr.Open(c["path"])
        except Exception as ex:
            unreadable.append((c["ident"], f"{type(ex).__name__}: {ex}"))
            continue
        if src is None:
            unreadable.append((c["ident"], "ogr.Open returned None"))
            continue
        per_cell.setdefault(c["ident"], {})
        for lname, wanted in encspec.LAYERS.items():
            if lname not in c["layers"]:
                continue                      # cell genuinely has none of this class
            slyr = src.GetLayerByName(lname)
            if slyr is None:
                continue
            sdefn = slyr.GetLayerDefn()
            have = {sdefn.GetFieldDefn(i).GetName() for i in range(sdefn.GetFieldCount())}

            if lname not in made:
                gtype = slyr.GetGeomType()
                dlyr = dst.CreateLayer(lname, srs, gtype, options=["SPATIAL_INDEX=NO"])
                # Stable schema: every spec field for this class exists on the destination whether
                # or not the first cell happened to carry it, so cells cannot drift the schema.
                for fname in wanted:
                    ref = None
                    for i in range(sdefn.GetFieldCount()):
                        if sdefn.GetFieldDefn(i).GetName() == fname:
                            ref = sdefn.GetFieldDefn(i)
                            break
                    fd = ogr.FieldDefn(fname, ref.GetType() if ref else ogr.OFTString)
                    if ref and ref.GetType() in (ogr.OFTStringList, ogr.OFTIntegerList,
                                                 ogr.OFTRealList, ogr.OFTInteger64List):
                        fd = ogr.FieldDefn(fname, ogr.OFTString)   # MVT has no list types
                    dlyr.CreateField(fd)
                # Provenance on every feature: which cell and which usage band it came from.
                dlyr.CreateField(ogr.FieldDefn("enc_cell", ogr.OFTString))
                dlyr.CreateField(ogr.FieldDefn("enc_band", ogr.OFTInteger))
                made[lname] = (dlyr, list(wanted))
                counts.setdefault(lname, 0)

            dlyr, fields = made[lname]
            ddefn = dlyr.GetLayerDefn()
            slyr.SetSpatialFilterRect(*filter_rect)
            slyr.ResetReading()
            dlyr.StartTransaction()
            for feat in slyr:
                g = feat.GetGeometryRef()
                if g is None or g.IsEmpty():
                    continue
                gx0, gx1, gy0, gy1 = g.GetEnvelope()
                inside_fast = (gx0 >= fx0 and gx1 <= fx1 and gy0 >= fy0 and gy1 <= fy1)
                if not inside_fast:
                    try:
                        g = g.Intersection(clip)
                    except Exception as ex:
                        # Count it rather than swallowing it. A bare `continue` here meant an
                        # arbitrary number of features could vanish while the run still printed
                        # "all requested regions built cleanly".
                        clip_failures.append((c["ident"], lname, f"{type(ex).__name__}: {ex}"))
                        continue
                    if g is None or g.IsEmpty():
                        continue
                nf = ogr.Feature(ddefn)
                for fname in fields:
                    if fname not in have:
                        continue
                    idx = feat.GetFieldIndex(fname)
                    if idx < 0 or not feat.IsFieldSet(idx):
                        continue
                    ft = feat.GetFieldDefnRef(idx).GetType()
                    if ft in (ogr.OFTStringList, ogr.OFTIntegerList, ogr.OFTRealList,
                              ogr.OFTInteger64List):
                        vals = feat.GetField(idx)
                        nf.SetField(fname, ",".join(str(v) for v in vals) if vals else None)
                    else:
                        nf.SetField(fname, feat.GetField(idx))
                nf.SetField("enc_cell", c["ident"])
                nf.SetField("enc_band", band)
                nf.SetGeometry(g.Clone())
                dlyr.CreateFeature(nf)
                counts[lname] += 1
                per_cell[c["ident"]][lname] = per_cell[c["ident"]].get(lname, 0) + 1
            dlyr.CommitTransaction()
    dst = None
    if clip_failures:
        for ident, lname, why in clip_failures[:10]:
            print(f"   ⚠ clip failed, feature dropped: {ident}/{lname}: {why}", file=sys.stderr)
        print(f"   ⚠ {len(clip_failures)} feature(s) dropped by a failed clip", file=sys.stderr)
    return counts, per_cell, unreadable


# How hard GDAL may simplify a geometry, in tile-extent units (the tile is 4096 across). 0 means
# no simplification at all.
#
# ⚠️ THIS IS A DATASET-LEVEL OPTION AND THERE IS NO PER-LAYER EQUIVALENT. An earlier version built
# a per-layer `CONF` of {"CBLOHD": {"simplification": 0}, ...} from encspec.NEVER_SIMPLIFY and
# believed it was protecting point hazards from generalisation. GDAL's MVT writer reads only
# target_name / description / minzoom / maxzoom per layer, so the key was silently ignored and the
# exemption did nothing — and the tests covering it only checked that the layer names were spelled
# correctly, which they were. Verified against the driver's own option list: SIMPLIFICATION and
# SIMPLIFICATION_MAX_ZOOM are dataset-level only.
#
# So simplification is now declared here for the whole pack rather than wished for per layer, and
# hazard survival is CHECKED instead of assumed — verify_pack() decodes real tiles and counts.
MVT_SIMPLIFICATION = 0


def band_to_mvt(gpkg, band, mbtiles, region_name, window=None):
    # `window` is the region-specific window from encspec.band_windows(), which closes the gap a
    # missing band would otherwise leave inside the pack's advertised zoom range.
    zlo, zhi = window or encspec.BAND_ZOOM[band]
    if os.path.exists(mbtiles):
        os.remove(mbtiles)
    cmd = [
        "ogr2ogr", "-f", "MVT", mbtiles, gpkg,
        "-dsco", "FORMAT=MBTILES",
        "-dsco", f"MINZOOM={zlo}",
        "-dsco", f"MAXZOOM={zhi}",
        "-dsco", f"NAME={region_name}-band{band}",
        "-dsco", f"DESCRIPTION=NOAA ENC band {band} ({encspec.BAND_NAME[band]})",
        "-dsco", "COMPRESS=YES",
        "-dsco", f"SIMPLIFICATION={MVT_SIMPLIFICATION}",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:], file=sys.stderr)
        print(r.stderr[-3000:], file=sys.stderr)
        raise SystemExit(f"ogr2ogr -f MVT failed for band {band} of {region_name}")
    return mbtiles


def merge_band_packs(band_packs, out_path, meta, region_bbox):
    """Concatenate band MBTiles into one. Safe only because band zoom windows are disjoint."""
    if os.path.exists(out_path):
        os.remove(out_path)
    con = sqlite3.connect(out_path)
    con.executescript("""
        CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER,
                            tile_data BLOB,
                            PRIMARY KEY (zoom_level, tile_column, tile_row));
    """)
    layers = {}
    bounds = None
    zmin = zmax = None
    for band, p in sorted(band_packs.items()):
        src = sqlite3.connect(p)
        rows = src.execute("SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles").fetchall()
        # INSERT (not OR REPLACE): a collision here would mean the disjoint-window invariant broke,
        # and we want that to raise rather than silently drop one band's tiles.
        con.executemany("INSERT INTO tiles VALUES (?,?,?,?)", rows)
        m = dict(src.execute("SELECT name,value FROM metadata").fetchall())
        if m.get("json"):
            for L in json.loads(m["json"]).get("vector_layers", []):
                prev = layers.get(L["id"])
                if prev is None:
                    layers[L["id"]] = dict(L)
                else:
                    prev["minzoom"] = min(prev.get("minzoom", 99), L.get("minzoom", 99))
                    prev["maxzoom"] = max(prev.get("maxzoom", 0), L.get("maxzoom", 0))
                    prev.setdefault("fields", {}).update(L.get("fields", {}))
        if m.get("bounds"):
            b = [float(x) for x in m["bounds"].split(",")]
            bounds = b if bounds is None else [min(bounds[0], b[0]), min(bounds[1], b[1]),
                                               max(bounds[2], b[2]), max(bounds[3], b[3])]
        if m.get("minzoom"):
            zmin = int(m["minzoom"]) if zmin is None else min(zmin, int(m["minzoom"]))
        if m.get("maxzoom"):
            zmax = int(m["maxzoom"]) if zmax is None else max(zmax, int(m["maxzoom"]))
        src.close()
    md = {
        "name": meta["name"], "format": "pbf", "type": "overlay", "version": "1.0",
        "description": meta["label"],
        "json": json.dumps({"vector_layers": list(layers.values())}),
        "minzoom": str(zmin if zmin is not None else encspec.MIN_ZOOM),
        "maxzoom": str(zmax if zmax is not None else encspec.MAX_ZOOM),
        # Provenance the artifact carries itself, mirroring `faa_cycle` in the FAA chart packs.
        "enc_vintage": meta["enc_vintage"],
        "enc_cell_count": str(meta["cell_count"]),
        "enc_bands": ",".join(str(b) for b in sorted(band_packs)),
        "attribution": "Chart data © NOAA / NOS Office of Coast Survey (public domain). "
                       "Not for navigation.",
        "commsight_built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    # Clamp the published bounds to the region box, and ALSO record what the data actually spanned
    # before clamping.
    #
    # ⚠️ THE GUARD MUST TEST `data_bounds`, NOT `bounds`. An earlier version clamped bounds to
    # region_bbox ± CLIP_MARGIN_DEG here and then had verify_pack test those same clamped bounds
    # against region_bbox ± (CLIP_MARGIN_DEG + 1e-6) — arithmetically incapable of failing. The
    # clamp was the thing being checked. Publishing the pre-clamp extent separately means the check
    # has an independent quantity to look at, so a clip that stops working is still caught.
    w, s_, e, n = region_bbox
    if bounds:
        md["data_bounds"] = ",".join(f"{v:.6f}" for v in bounds)
        bounds = [max(bounds[0], w - CLIP_MARGIN_DEG), max(bounds[1], s_ - CLIP_MARGIN_DEG),
                  min(bounds[2], e + CLIP_MARGIN_DEG), min(bounds[3], n + CLIP_MARGIN_DEG)]
    else:
        bounds = [w, s_, e, n]
    md["bounds"] = ",".join(f"{v:.6f}" for v in bounds)
    md["region_bbox"] = ",".join(f"{v:.6f}" for v in region_bbox)
    con.executemany("INSERT INTO metadata VALUES (?,?)", sorted(md.items()))
    con.commit()
    con.execute("ANALYZE")
    con.commit()
    con.close()
    return out_path


def _tile_xyz(lat, lon, z):
    """Web Mercator tile containing a point, and the MBTiles (TMS) row for it."""
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)
    x = max(0, min(n - 1, x))
    y = max(0, min(n - 1, y))
    return x, y, n - 1 - y


def _decode_tile(blob, scratch):
    """A tile's layers, by name. MVT in these packs is gzipped; GDAL reads a plain .pbf."""
    data = gzip.decompress(blob) if blob[:2] == b"\x1f\x8b" else blob
    with open(scratch, "wb") as fh:
        fh.write(data)
    try:
        ds = ogr.Open(scratch)
    except Exception:
        return None
    return ds


def verify_hazards_reach_the_tiles(pack_path, band_gpkgs, work, sample=40, windows=None):
    """Confirm that clearance-bearing features written to the GeoPackages are findable in the
    FINISHED pack's tiles.

    ⚠️ THIS REPLACES A GUARD THAT COULD NOT FIRE. The module docstring used to claim that
    "clearance-bearing classes are counted before and after tiling", and verify_pack only checked
    whether the layer NAME appeared in the merged metadata `json`. A name in metadata is not a
    feature in a tile, and worse, the check was gated on `expect_counts[layer] > 0` where
    expect_counts was the count of features the builder itself had written — so a loss upstream of
    the tiler drove the expectation to zero and switched the guard off. The exact incident it was
    written for would have disabled it.

    So: take real features out of the GeoPackage, compute the tile each one must occupy at its
    band's top zoom, and decode that tile. Bounded to `sample` features per (band, layer) because
    decoding is the expensive part; the cap is reported, never silent.
    """
    problems, checked, found, capped = [], 0, 0, []
    con = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    scratch = os.path.join(work, "_verify.pbf")
    for band, gpkg in sorted(band_gpkgs.items()):
        if not os.path.exists(gpkg):
            continue
        zhi = (windows or encspec.BAND_ZOOM)[band][1]
        try:
            src = ogr.Open(gpkg)
        except Exception as ex:
            problems.append(f"band {band}: GeoPackage unreadable for verification ({ex})")
            continue
        if src is None:
            continue
        for lname in encspec.CLEARANCE_BEARING_LAYERS:
            lyr = src.GetLayerByName(lname)
            if lyr is None:
                continue
            total = lyr.GetFeatureCount()
            if not total:
                continue
            if total > sample:
                capped.append(f"band {band}/{lname}: sampled {sample} of {total}")
            step = max(1, total // sample)
            lyr.ResetReading()
            misses = []
            for i, feat in enumerate(lyr):
                if i % step:
                    continue
                g = feat.GetGeometryRef()
                if g is None or g.IsEmpty():
                    continue
                c = g.Centroid()
                x, _y, row = _tile_xyz(c.GetY(), c.GetX(), zhi)
                r = con.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? "
                                "AND tile_row=?", (zhi, x, row)).fetchone()
                checked += 1
                if not r:
                    misses.append(f"no tile at z{zhi}/{x}/{_y}")
                    continue
                ds = _decode_tile(r[0], scratch)
                if ds is None or ds.GetLayerByName(lname) is None:
                    misses.append(f"z{zhi}/{x}/{_y} has no {lname} layer")
                else:
                    found += 1
            if misses:
                problems.append(
                    f"band {band} {lname}: {len(misses)} of {min(total, sample)} sampled features "
                    f"are not in the pack's tiles (e.g. {misses[0]}) — the GeoPackage holds "
                    f"{total}, so they were lost during tiling")
    con.close()
    return problems, checked, found, capped


def verify_pack(path, written_counts, label, band_gpkgs=None, work=None, windows=None):
    """Read the finished pack back and assert the hazards are still in it."""
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    m = dict(con.execute("SELECT name,value FROM metadata").fetchall())
    n, zlo, zhi = con.execute(
        "SELECT count(*),min(zoom_level),max(zoom_level) FROM tiles").fetchone()
    per_zoom = dict(con.execute(
        "SELECT zoom_level, count(*) FROM tiles GROUP BY zoom_level").fetchall())
    con.close()

    problems = []
    if m.get("format") != "pbf":
        problems.append(f"format is {m.get('format')!r}, expected 'pbf'")
    if not m.get("enc_vintage"):
        problems.append("no enc_vintage stamp — refusing an undated artifact")
    if not n:
        problems.append("pack contains zero tiles")

    # The bounds claim is tested against the PRE-CLAMP data extent — see merge_band_packs.
    if m.get("data_bounds") and m.get("region_bbox"):
        b = [float(x) for x in m["data_bounds"].split(",")]
        rb = [float(x) for x in m["region_bbox"].split(",")]
        slack = CLIP_MARGIN_DEG + 1e-6
        if (b[0] < rb[0] - slack or b[1] < rb[1] - slack
                or b[2] > rb[2] + slack or b[3] > rb[3] + slack):
            problems.append(f"data reaches {m['data_bounds']}, outside region_bbox "
                            f"{m['region_bbox']} ± {CLIP_MARGIN_DEG} — the clip is not working, "
                            f"and the pack would be chosen for water it does not chart")

    # A pack must not advertise a zoom range it has holes in. Each usage band owns an exclusive
    # window, and a region with no cells in some middle band produces a pack whose minzoom..maxzoom
    # spans zooms that contain no tiles at all. MapLibre asks for those zooms and draws nothing, so
    # the layer silently disappears over part of its own range.
    if zlo is not None:
        empty = [z for z in range(zlo, zhi + 1) if not per_zoom.get(z)]
        if empty:
            bands = sorted({b for b in encspec.BAND_ZOOM
                            if any(encspec.BAND_ZOOM[b][0] <= z <= encspec.BAND_ZOOM[b][1]
                                   for z in empty)})
            problems.append(
                f"advertises z{zlo}-{zhi} but zoom(s) {empty} hold no tiles "
                f"(usage band(s) {bands} have no cells in this region) — the layer would vanish "
                f"over that part of its own range")

    layers = {}
    try:
        layers = {L["id"]: L for L in json.loads(m.get("json", "{}")).get("vector_layers", [])}
    except json.JSONDecodeError:
        problems.append("metadata 'json' is not valid JSON — no client can build a style from it")

    # Written-but-absent is still worth saying, but it is now the weak check, not the only one.
    for lname, k in sorted((written_counts or {}).items()):
        if k > 0 and lname not in layers:
            problems.append(f"{lname}: {k} features written, layer absent from the finished pack")

    hz = ""
    if band_gpkgs and work:
        hp, checked, found, capped = verify_hazards_reach_the_tiles(
            path, band_gpkgs, work, windows=windows)
        problems.extend(hp)
        hz = f"  hazards {found}/{checked} sampled features located in tiles"
        if capped:
            hz += f" ({'; '.join(capped)})"

    size = os.path.getsize(path)
    print(f"   {label}: {n:,} tiles  z{zlo}-{zhi}  {size/1e6:.1f} MB  "
          f"{len(layers)} layers  vintage {m.get('enc_vintage')}")
    if hz:
        print(f"  {hz}")
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--index", required=True, help="enc_index.json from enc_index.py")
    ap.add_argument("--out", required=True, help="output directory for <region>.mbtiles")
    ap.add_argument("--regions", default=os.path.join(HERE, "regions.conf"))
    ap.add_argument("--region", action="append", help="build only this region (repeatable)")
    ap.add_argument("--work", default="/tmp/marine/work")
    ap.add_argument("--keep-work", action="store_true", help="keep band GeoPackages for inspection")
    args = ap.parse_args(argv)

    with open(args.index) as fh:
        index = json.load(fh)
    if not index.get("enc_vintage"):
        sys.exit("index carries no enc_vintage — rerun enc_index.py")
    regions = load_regions(args.regions)
    # Both checks run over ALL regions even when building one, so a missing or too-narrow region
    # definition is caught on every run rather than only on a full build.
    assigned = assign_cells(index["cells"], regions)
    assert_regions_cover_detailed_cells(index["cells"], regions)

    # ── INPUT FLOOR ─────────────────────────────────────────────────────────────────────────────
    # Nothing else here distinguishes "this region has no coverage" from "the download failed".
    # An empty or half-extracted ENC_ROOT produced a clean, successful, empty build — the same
    # failure that silently cut airspace from 2,829 features to 1,286 and shipped (ios/Tools/
    # build_sua.py). The 2026-10-21 set has 7,303 cells; a set that has lost a third of them is
    # not a smaller world, it is a broken download.
    if index["cell_count"] < MIN_EXPECTED_CELLS:
        sys.exit(f"index has only {index['cell_count']} cells, expected at least "
                 f"{MIN_EXPECTED_CELLS}. That is a truncated download or a partial extraction, "
                 f"not a smaller chart world — refusing to build packs from it. Re-fetch "
                 f"All_ENCs.zip, check `unzip -tqq`, and re-run enc_index.py.")

    todo = regions if not args.region else [r for r in regions if r["name"] in set(args.region)]
    if args.region:
        missing = set(args.region) - {r["name"] for r in regions}
        if missing:
            sys.exit(f"unknown region(s): {sorted(missing)}")

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    print(f"ENC vintage {index['enc_vintage']}  ·  {index['cell_count']} cells  ·  "
          f"{len(regions)} regions defined  ·  building {len(todo)}")

    failures = []
    for r in todo:
        cells = assigned[r["name"]]
        if not cells:
            print(f"\n▸ {r['name']}: no ENC cells in bbox — skipped (region defines no coverage)")
            continue
        t0 = time.time()
        bands = sorted({c["band"] for c in cells})
        print(f"\n▸ {r['name']} — {r['label']}")
        print(f"   {len(cells)} cells, bands {bands}")

        work = os.path.join(args.work, r["name"])
        os.makedirs(work, exist_ok=True)
        band_packs, total_counts, band_gpkgs = {}, {}, {}
        pending = {}      # band -> (gpkg, counts, n_cells); tiled in pass 2, see below
        for band in bands:
            bcells = [c for c in cells if c["band"] == band]
            gpkg = os.path.join(work, f"band{band}.gpkg")
            counts, per_cell, unreadable = build_band_gpkg(bcells, band, r["bbox"], gpkg)
            if unreadable:
                for ident, why in unreadable[:10]:
                    print(f"   !! unreadable cell {ident}: {why}", file=sys.stderr)
                failures.append(f"{r['name']}: band {band}: {len(unreadable)} cell(s) could not be "
                                f"read, so their charted water is in no pack")
            # ⚠️ TEST THE FEATURE TOTAL, NOT THE DICT. build_band_gpkg creates a destination
            # layer (and so a counts key) for every class the INDEX says the cell holds, before it
            # knows whether any feature survives the spatial filter. So a band that contributes
            # nothing still returns a dict of 14-odd zero counts, which is truthy — guam_marianas
            # went through this branch with "3 cells, 0 features, 14 layers", claimed the z10-11
            # window, emitted an empty MVT, and was quarantined for advertising a zoom range with
            # a hole in it. Twice: the first fix moved the window calculation but left this test.
            counts = {ln: k for ln, k in counts.items() if k}
            if not counts:
                print(f"   band {band}: no features in region bbox — skipped")
                continue
            # ── RECONCILE PER CELL, against that cell's own index counts. ───────────────────────
            # The previous version summed every cell into one per-layer counter and compared it
            # against the expectation of only the wholly-contained cells. An audit showed that to
            # be vacuous: features from every edge-overlapping cell inflate the same counter, so a
            # wholly-contained cell could lose 100% of its features and the check would still read
            # a comfortable surplus. Attribution is what makes the check mean anything, and
            # build_band_gpkg now returns it.
            def inside(cb, rb):
                return (cb[0] >= rb[0] and cb[1] >= rb[1]
                        and cb[2] <= rb[2] and cb[3] <= rb[3])
            whole = [c for c in bcells if inside(c["bbox"], r["bbox"])]
            partial = len(bcells) - len(whole)
            for c in whole:
                got_layers = per_cell.get(c["ident"], {})
                for ln, exp in sorted(c["layers"].items()):
                    if exp < 20:
                        continue            # too few to distinguish loss from rounding
                    got = got_layers.get(ln, 0)
                    if got < exp * (1 - SHORTFALL_ABORT):
                        msg = (f"band {band} cell {c['ident']} layer {ln}: index says {exp} "
                               f"features, pack wrote {got} ({got/exp*100:.0f}%) — this cell is "
                               f"wholly inside the region, so nothing was clipped away")
                        failures.append(f"{r['name']}: {msg}")
                        print(f"   !! {msg}", file=sys.stderr)
            if partial:
                print(f"   ·  band {band}: {len(whole)} cell(s) reconciled per-cell; {partial} "
                      f"overlap the region edge and are clipped, so are not comparable")
            for ln, k in counts.items():
                total_counts[ln] = total_counts.get(ln, 0) + k
            band_gpkgs[band] = gpkg
            pending[band] = (gpkg, counts, len(bcells))

        # ── Windows are derived from the bands that PRODUCED FEATURES, not the bands whose cells
        # exist. Those are different sets, and the difference shipped a holed pack.
        #
        # guam_marianas HAS three band-3 cells, so deriving windows from `bands` gave band 3 the
        # z10-11 slot — but all three yielded zero features inside the region box, the band was
        # skipped, and z10-11 came out empty inside a pack advertising z4-16. The guard caught it
        # and quarantined the pack, which is the right outcome but a wasted build. Deciding the
        # windows here, once the GeoPackages are in hand, closes the gap instead: band 4 stretches
        # down to z10 exactly as it does for the Great Lakes.
        windows = encspec.band_windows(sorted(pending))
        stretched = [b for b in sorted(pending) if windows[b] != encspec.BAND_ZOOM[b]]
        if stretched:
            print("   ·  " + ", ".join(
                f"band {b} covers z{windows[b][0]}-{windows[b][1]} instead of "
                f"z{encspec.BAND_ZOOM[b][0]}-{encspec.BAND_ZOOM[b][1]}" for b in stretched)
                + " (no band below it produced features here, so the finer band fills the gap)")

        for band in sorted(pending):
            gpkg, counts, ncells = pending[band]
            zlo, zhi = windows[band]
            mb = os.path.join(work, f"band{band}.mbtiles")
            band_to_mvt(gpkg, band, mb, r["name"], windows[band])
            band_packs[band] = mb
            nf = sum(counts.values())
            print(f"   band {band} {encspec.BAND_NAME[band]:9s} z{zlo}-{zhi}  "
                  f"{ncells:4d} cells  {nf:8,} features  {len(counts)} layers")

        out = os.path.join(args.out, f"{r['name']}.mbtiles")
        if not band_packs:
            # ⚠️ REMOVE ANY PREVIOUS PACK. Falling through with `continue` left an arbitrarily old
            # <region>.mbtiles sitting in the publish directory while the run still reported
            # success — presented as this run's output and fully enc_vintage-stamped with LAST
            # week's date. charts/build_all_packs.sh resumes on "does the output file exist" and
            # the house comments already call that out as dangerous across a cycle roll; ENC rolls
            # weekly, so the same hazard is 8x more frequent here.
            print(f"   nothing to pack for {r['name']}")
            if os.path.exists(out):
                os.remove(out)
                print(f"   removed stale {out} — this run produced nothing to replace it with")
            failures.append(f"{r['name']}: region has cells but produced no band packs")
            continue

        vintage = max(c["issued"] for c in cells)
        merge_band_packs(band_packs, out, {
            "name": r["name"], "label": r["label"],
            "enc_vintage": vintage, "cell_count": len(cells),
        }, r["bbox"])
        probs = verify_pack(out, total_counts, r["name"], band_gpkgs, work, windows)
        region_failed = bool(probs) or any(f.startswith(r["name"] + ":") for f in failures)
        if probs:
            for p in probs:
                print(f"   !! {p}", file=sys.stderr)
                failures.append(f"{r['name']}: {p}")
        if region_failed:
            # ⚠️ A REJECTED PACK MUST NOT BE PUBLISHABLE. Printing "ABORT" and then leaving a
            # fully-stamped .mbtiles in --out is how a pack the guards rejected reaches devices:
            # publish.py globs the output directory, and a rejected pack is byte-for-byte
            # indistinguishable from a clean one. Quarantine it instead, so the bytes survive for
            # diagnosis but nothing can mistake them for output.
            bad = out + ".rejected"
            os.replace(out, bad)
            print(f"   !! quarantined → {bad} (NOT published; see the problems above)",
                  file=sys.stderr)
        else:
            print(f"   built in {time.time()-t0:.0f}s → {out}")
        if not args.keep_work:
            shutil.rmtree(work, ignore_errors=True)

    if failures:
        print(f"\n{len(failures)} problem(s) — any affected pack was quarantined as "
              f"<region>.mbtiles.rejected and is NOT publishable:", file=sys.stderr)
        for f in failures:
            print(f"  !! {f}", file=sys.stderr)
        return 1
    print("\nall requested regions built cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
