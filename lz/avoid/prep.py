"""One-time national prep for the avoid map: every input becomes something a cell can query fast.

    python3 -I lz/avoid/prep.py            # after the national zips are fetched and unzipped

Writes into $AVOID_WORK/shared:
  lines_3857.gpkg     overhead transmission lines (HIFLD/ORNL, frozen 2024-09), CONUS, EPSG:3857
  solar_3857.gpkg     USPVDB v4 solar facility polygons, EPSG:3857
  runways_3857.gpkg   runway rectangles where both ends are surveyed (apt.sqlite)
  points.npz          DOF obstacles + USWTDB turbines + airport discs: x, y, radius (Mercator m), bit
  dem_1as.vrt         the 3DEP 1 arc-second seamless VRT (its sources stay remote /vsicurl COGs)
  inputs.json         paths, vintages, counts: the provenance written into the map's metadata
"""
import csv
import glob
import io
import json
import math
import os
import sqlite3
import sys
import time
import urllib.request
import zipfile

import numpy as np
from osgeo import gdal, ogr, osr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

gdal.UseExceptions()
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APT_DB = os.path.join(REPO, "ios/ATCTranscribe/Resources/nav/apt.sqlite")
DEM_VRT_URL = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1/TIFF/USGS_Seamless_DEM_1.vrt"
MARGIN_DEG = 1.0                       # keep features just outside CONUS: they paint border cells


def _srs(epsg):
    s = osr.SpatialReference()
    s.ImportFromEPSG(epsg)
    s.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)   # lon, lat — never lat, lon
    return s


def _in_conus(lon, lat):
    w, s, e, n = C.CONUS_BBOX
    return (w - MARGIN_DEG) <= lon <= (e + MARGIN_DEG) and (s - MARGIN_DEG) <= lat <= (n + MARGIN_DEG)


def _new_gpkg(path, name, gtype):
    if os.path.exists(path):
        os.remove(path)
    ds = ogr.GetDriverByName("GPKG").CreateDataSource(path)
    assert ds is not None, f"cannot create {path}"
    lyr = ds.CreateLayer(name, _srs(3857), gtype, options=["SPATIAL_INDEX=YES"])
    return ds, lyr


def prep_lines():
    """Overhead lines only (underground ones cannot snag an aeroplane), clipped near CONUS."""
    src = ogr.Open(os.path.join(C.SHARED, "hifld_lines.parquet"))
    lyr = src.GetLayer(0)
    tx = osr.CoordinateTransformation(_srs(4326), _srs(3857))
    out_ds, out = _new_gpkg(os.path.join(C.SHARED, "lines_3857.gpkg"), "lines", ogr.wkbMultiLineString)
    kept = dropped_ug = dropped_far = 0
    out_ds.StartTransaction()
    for f in lyr:                                                  # bounded by the layer (94,619)
        if "UNDERGROUND" in (f.GetField("TYPE") or "").upper():
            dropped_ug += 1
            continue
        g = f.GetGeometryRef()
        if g is None:
            continue
        minx, maxx, miny, maxy = g.GetEnvelope()
        if not (_in_conus(minx, miny) or _in_conus(maxx, maxy)):
            dropped_far += 1
            continue
        g = g.Clone()
        g.Transform(tx)
        nf = ogr.Feature(out.GetLayerDefn())
        nf.SetGeometry(ogr.ForceToMultiLineString(g))
        out.CreateFeature(nf)
        kept += 1
    out_ds.CommitTransaction()
    assert kept > 50000, f"prep_lines: only {kept} overhead CONUS lines — the source is not what we expect"
    return {"kept": kept, "dropped_underground": dropped_ug, "dropped_outside": dropped_far}


def prep_solar():
    path = glob.glob(os.path.join(C.SHARED, "uspvdb", "*.geojson"))[0]
    src = ogr.Open(path)
    lyr = src.GetLayer(0)
    tx = osr.CoordinateTransformation(_srs(4326), _srs(3857))
    out_ds, out = _new_gpkg(os.path.join(C.SHARED, "solar_3857.gpkg"), "solar", ogr.wkbMultiPolygon)
    n = 0
    out_ds.StartTransaction()
    for f in lyr:                                                  # bounded by the layer (6,611)
        g = f.GetGeometryRef()
        if g is None:
            continue
        g = g.Clone()
        g.Transform(tx)
        nf = ogr.Feature(out.GetLayerDefn())
        nf.SetGeometry(ogr.ForceToMultiPolygon(g))
        out.CreateFeature(nf)
        n += 1
    out_ds.CommitTransaction()
    assert n > 5000, f"prep_solar: only {n} solar polygons"
    return {"polygons": n, "source": os.path.basename(path)}


# DOF type → (bit, radius rule). Radii are GROUND metres around the point; tall guyed structures
# get a radius from their height because their guy wires reach out ~60% of it.
DOF_WIRE_TYPES = {"T-L TWR": 60, "POLE": 30, "UTILITY POLE": 30, "CATENARY": 100, "ELEC SYS": 40}
DOF_GUYED = ("TOWER", "ANTENNA", "MET", "BLDG-TWR", "SPIRE", "VERTICAL STRUCTURE")


def _dof_rule(kind, agl_m):
    if kind in DOF_WIRE_TYPES:
        return C.WIRES, DOF_WIRE_TYPES[kind]
    if kind == "SOLAR PANELS":
        return C.SOLAR, 60
    if kind == "WINDMILL":
        return C.OBSTACLE, 100
    if kind == "FENCE":
        return C.OBSTACLE, 30
    if kind in DOF_GUYED:
        return C.OBSTACLE, min(300.0, max(60.0, 0.6 * agl_m))
    return C.OBSTACLE, min(150.0, max(40.0, 0.3 * agl_m))


def _merc_r(radius_ground_m, lat):
    """Ground metres → Mercator metres at this latitude (Mercator stretches by 1/cos(lat))."""
    return radius_ground_m / max(0.2, math.cos(math.radians(lat)))


def prep_points():
    xs, ys, rs, bits = [], [], [], []
    counts = {"dof": 0, "dof_dismantled": 0, "turbines": 0, "airport_discs": 0}
    with zipfile.ZipFile(os.path.join(C.SHARED, "dof.zip")) as z:
        name = [n for n in z.namelist() if n.upper().endswith(".CSV")][0]
        with z.open(name) as fh:
            rd = csv.DictReader(io.TextIOWrapper(fh, encoding="latin-1"))
            for row in rd:                                          # bounded by the file (~657k)
                if (row.get("ACTION") or "").strip().upper() == "D":
                    counts["dof_dismantled"] += 1
                    continue
                try:
                    lat, lon = float(row["LATDEC"]), float(row["LONDEC"])
                    agl_m = float(row.get("AGL") or 0) * 0.3048
                except (TypeError, ValueError):
                    continue
                if not _in_conus(lon, lat):
                    continue
                bit, r = _dof_rule((row.get("TYPE") or "").strip().upper(), agl_m)
                x, y = C.lonlat_to_merc(lon, lat)
                xs.append(x); ys.append(y); rs.append(_merc_r(r, lat)); bits.append(bit)
                counts["dof"] += 1
    tw_ds = ogr.Open(glob.glob(os.path.join(C.SHARED, "uswtdb", "*.geojson"))[0])  # keep: the layer dies with it
    tw = tw_ds.GetLayer(0)
    for f in tw:                                                    # bounded by the layer (77,839)
        g = f.GetGeometryRef()
        if g is None:
            continue
        lon, lat = g.GetX(), g.GetY()
        if not _in_conus(lon, lat):
            continue
        rd_m = f.GetField("t_rd") or 0
        r = max(60.0, (rd_m / 2.0 if rd_m and rd_m > 0 else 50.0) + 30.0)
        x, y = C.lonlat_to_merc(lon, lat)
        xs.append(x); ys.append(y); rs.append(_merc_r(r, lat)); bits.append(C.OBSTACLE)
        counts["turbines"] += 1
    assert counts["dof"] > 400000 and counts["turbines"] > 60000, f"prep_points: thin inputs {counts}"
    return xs, ys, rs, bits, counts


EXEMPT_SITE_TYPES = ("A", "G", "U")        # airports, gliderports, ultralight fields — never paint them


def prep_runways():
    """Exact runway rectangles where both ends are surveyed; a disc at the field otherwise.

    NLCD calls runways "developed", so without this the map would tell a pilot to avoid an airport.
    Rectangles clear EVERY reason (nothing hides on a runway); the fallback disc clears only
    "developed", because a crude circle around a field can contain real wires or water."""
    db = sqlite3.connect(f"file:{APT_DB}?mode=ro", uri=True)
    sites = {r[0]: r[1:] for r in db.execute(
        "SELECT ident, site_type, lat, lon FROM airport WHERE lat IS NOT NULL")}
    rwy = {(r[0], r[1]): (r[2] or 0.0, r[3] or 0.0) for r in db.execute(
        "SELECT ident, designator, length_ft, width_ft FROM runway")}
    ends = {}
    for ident, des, end_id, lat, lon in db.execute(
            "SELECT ident, designator, end_id, lat, lon FROM runway_end WHERE lat IS NOT NULL"):
        ends.setdefault((ident, des), []).append((lat, lon))
    out_ds, out = _new_gpkg(os.path.join(C.SHARED, "runways_3857.gpkg"), "runways", ogr.wkbPolygon)
    exact_idents, n_rect = set(), 0
    out_ds.StartTransaction()
    for key, pts in ends.items():                                  # bounded by runway ends (~24k)
        if len(pts) != 2 or sites.get(key[0], ("?",))[0] not in EXEMPT_SITE_TYPES:
            continue
        (la1, lo1), (la2, lo2) = pts
        width_ft = rwy.get(key, (0.0, 0.0))[1] or 75.0
        out.CreateFeature(_rect_feature(out, la1, lo1, la2, lo2, width_ft))
        exact_idents.add(key[0])
        n_rect += 1
    out_ds.CommitTransaction()
    longest = {}
    for (ident, _), (length_ft, _) in rwy.items():
        longest[ident] = max(longest.get(ident, 0.0), length_ft)
    discs = []
    for ident, (stype, lat, lon) in sites.items():                 # bounded by airports (~19k)
        if stype not in EXEMPT_SITE_TYPES or ident in exact_idents or not _in_conus(lon, lat):
            continue
        r = (longest.get(ident, 0.0) * 0.3048 / 2.0 + 100.0) if longest.get(ident) else 400.0
        x, y = C.lonlat_to_merc(lon, lat)
        discs.append((x, y, _merc_r(r, lat)))
    assert n_rect > 5000, f"prep_runways: only {n_rect} runway rectangles"
    return discs, {"runway_rectangles": n_rect, "airport_discs": len(discs)}


APPROX_HEADING_SLACK_DEG = 6.0   # a designator is rounded to 10° (±5°), plus a degree of variation
APPROX_ARP_SLACK_M = 40.0        # a private strip's reference point can sit ~100 m off its centreline (7NC3)


def _designator_heading(des):
    """Magnetic heading of a runway's first end, from its designator ("09/27", "13L/31R", "N/S").
    None for anything that is not one runway on land (helipads, water lanes, three-way names)."""
    first = des.split("/")[0].strip().upper()
    if first.endswith("W") and first[:-1].isdigit():
        return None                                                # a seaplane lane, not land
    letters = {"N": 0.0, "S": 0.0, "E": 90.0, "W": 90.0, "NE": 45.0, "SW": 45.0, "NW": 135.0, "SE": 135.0}
    if first in letters:
        return letters[first]
    digits = first.rstrip("LRC")
    if digits.isdigit() and 1 <= int(digits) <= 36:
        return int(digits) * 10.0
    return None


def _variation_deg(mag_var, lon):
    """NASR stores the size of the variation without its hemisphere. In the contiguous US it is East
    west of the agonic line (~90°W) and West east of it; within ~3° of the line the sign error is
    under the heading slack the rectangle already carries."""
    try:
        v = float(mag_var)
    except (TypeError, ValueError):
        return 0.0
    return v if lon < -90.0 else -v


def prep_runways_approx():
    """Runways NASR lists without surveyed ends, at airports with exactly ONE runway: a rectangle on the
    airport reference point (the runway's centre for a single-runway field), turned to the designator
    heading, as long as the runway and widened for the designator's rounding.

    It is an estimate, so the merge clears only the reasons a runway's own pixels collect — built-up,
    trees, steep, orchard — and never wires, obstacles or solar: a misplaced estimate must not erase a
    real power line beside the strip. Private strips are where these are, and private strips are where
    an engine-out pilot goes."""
    db = sqlite3.connect(f"file:{APT_DB}?mode=ro", uri=True)
    surveyed = {r[0] for r in db.execute("SELECT DISTINCT ident FROM runway_end WHERE lat IS NOT NULL")}
    rows = db.execute("""SELECT a.ident, a.lat, a.lon, a.mag_var, r.designator, r.length_ft, r.width_ft
                         FROM airport a JOIN runway r ON r.ident = a.ident
                         WHERE a.site_type IN ('A', 'G', 'U') AND a.lat IS NOT NULL""").fetchall()
    per_airport = {}
    for row in rows:                                               # bounded by the runways (~23k)
        per_airport.setdefault(row[0], []).append(row)
    out_ds, out = _new_gpkg(os.path.join(C.SHARED, "runways_approx_3857.gpkg"), "runways_approx", ogr.wkbPolygon)
    n = skipped = 0
    out_ds.StartTransaction()
    for ident, rws in per_airport.items():                         # bounded by the airports
        if ident in surveyed or len(rws) != 1:
            continue
        _, lat, lon, mag_var, des, length_ft, width_ft = rws[0]
        mag = _designator_heading(des or "")
        if mag is None or not length_ft or not _in_conus(lon, lat):
            skipped += 1
            continue
        true_hdg = math.radians(mag + _variation_deg(mag_var, lon))
        half_len = length_ft * 0.3048 / 2.0
        hl = half_len + 60.0 + APPROX_ARP_SLACK_M
        hw = ((width_ft or 60.0) * 0.3048 / 2.0 + 20.0 + APPROX_ARP_SLACK_M
              + half_len * math.tan(math.radians(APPROX_HEADING_SLACK_DEG)))
        k = 1.0 / max(0.2, math.cos(math.radians(lat)))              # ground → Mercator
        cx, cy = C.lonlat_to_merc(lon, lat)
        ux, uy = math.sin(true_hdg), math.cos(true_hdg)              # along the runway (east, north)
        ring = ogr.Geometry(ogr.wkbLinearRing)
        for a, b in ((-hl, -hw), (hl, -hw), (hl, hw), (-hl, hw), (-hl, -hw)):
            ring.AddPoint_2D(cx + (a * ux + b * uy) * k, cy + (a * uy - b * ux) * k)
        poly = ogr.Geometry(ogr.wkbPolygon)
        poly.AddGeometry(ring)
        f = ogr.Feature(out.GetLayerDefn())
        f.SetGeometry(poly)
        out.CreateFeature(f)
        n += 1
    out_ds.CommitTransaction()
    assert n > 2000, f"prep_runways_approx: only {n} estimated runways"
    return {"runway_estimates": n, "runway_estimates_skipped": skipped}


def _rect_feature(lyr, la1, lo1, la2, lo2, width_ft):
    """A runway as a Mercator rectangle: centreline end to end + 30 m, half-width + 15 m (ground)."""
    x1, y1 = C.lonlat_to_merc(lo1, la1)
    x2, y2 = C.lonlat_to_merc(lo2, la2)
    k = 1.0 / max(0.2, math.cos(math.radians((la1 + la2) / 2.0)))     # ground → Mercator
    dx, dy = x2 - x1, y2 - y1
    length = math.hypot(dx, dy)
    assert length > 0, "_rect_feature: zero-length runway"
    ux, uy = dx / length, dy / length
    ext, hw = 30.0 * k, (width_ft * 0.3048 / 2.0 + 15.0) * k
    ax, ay, bx, by = x1 - ux * ext, y1 - uy * ext, x2 + ux * ext, y2 + uy * ext
    ring = ogr.Geometry(ogr.wkbLinearRing)
    for px, py in ((ax - uy * hw, ay + ux * hw), (bx - uy * hw, by + ux * hw),
                   (bx + uy * hw, by - ux * hw), (ax + uy * hw, ay - ux * hw), (ax - uy * hw, ay + ux * hw)):
        ring.AddPoint_2D(px, py)
    poly = ogr.Geometry(ogr.wkbPolygon)
    poly.AddGeometry(ring)
    f = ogr.Feature(lyr.GetLayerDefn())
    f.SetGeometry(poly)
    return f


def prep_dem_vrt():
    path = os.path.join(C.SHARED, "dem_1as.vrt")
    req = urllib.request.Request(DEM_VRT_URL, headers={"User-Agent": "CommSight-avoid-build/1.0"})
    data = urllib.request.urlopen(req, timeout=120).read()
    assert data.lstrip().startswith(b"<VRTDataset") and len(data) > 100000, "dem VRT is not a VRT"
    with open(path, "wb") as f:
        f.write(data)
    ds = gdal.Open(path)
    assert ds.RasterXSize > 100000, "dem VRT has no extent"
    return {"vrt": DEM_VRT_URL, "sources": data.count(b"<SourceFilename")}


def main():
    os.makedirs(C.SHARED, exist_ok=True)
    if sys.argv[1:] == ["--runways-approx"]:                       # added after the cells were built
        with open(os.path.join(C.SHARED, "inputs.json")) as f:
            info = json.load(f)
        info["built_from"]["runway_estimates"] = prep_runways_approx()
        with open(os.path.join(C.SHARED, "inputs.json"), "w") as f:
            json.dump(info, f, indent=1)
        print(json.dumps(info["built_from"]["runway_estimates"]))
        return
    nlcd = glob.glob(os.path.join(C.SHARED, "nlcd2025", "*.tif"))
    cdl = glob.glob(os.path.join(C.SHARED, "cdl2025", "*.tif"))
    assert nlcd and cdl, "national rasters missing — run fetch_national.sh first"
    for p in nlcd + cdl:
        ds = gdal.Open(p)
        assert ds.RasterXSize > 100000, f"{p} opened but has no extent (a stub file?)"
    info = {"nlcd": nlcd[0], "cdl": cdl[0], "built_from": {}}
    t0 = time.time()
    info["built_from"]["lines"] = prep_lines()
    print(f"lines {time.time() - t0:.0f}s", flush=True)
    info["built_from"]["solar"] = prep_solar()
    print(f"solar {time.time() - t0:.0f}s", flush=True)
    xs, ys, rs, bits, counts = prep_points()
    print(f"points {time.time() - t0:.0f}s", flush=True)
    discs, rcounts = prep_runways()
    rcounts.update(prep_runways_approx())
    print(f"runways {time.time() - t0:.0f}s", flush=True)
    np.savez_compressed(os.path.join(C.SHARED, "points.npz"),
                        x=np.array(xs), y=np.array(ys), r=np.array(rs), bit=np.array(bits, np.uint8),
                        disc_x=np.array([d[0] for d in discs]), disc_y=np.array([d[1] for d in discs]),
                        disc_r=np.array([d[2] for d in discs]))
    info["built_from"]["points"] = counts
    info["built_from"]["runways"] = rcounts
    info["built_from"]["dem"] = prep_dem_vrt()
    info["vintages"] = {"nlcd": "Annual NLCD C1.2 2025", "cdl": "USDA CDL 2025 30 m",
                        "lines": "HIFLD/ORNL transmission lines, data to 2024-09-26 (HIFLD Next v1.0.0)",
                        "solar": "USPVDB v4.0 2026-04-14", "turbines": "USWTDB v9.1 2026-09-28",
                        "dof": "FAA DOF daily CSV fetched 2026-10-29", "dem": "USGS 3DEP 1 arc-second, current"}
    with open(os.path.join(C.SHARED, "inputs.json"), "w") as f:
        json.dump(info, f, indent=1)
    print(json.dumps(info["built_from"], indent=1))


if __name__ == "__main__":
    main()
