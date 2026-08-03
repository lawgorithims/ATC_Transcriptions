#!/usr/bin/env python3
"""Resolve 1 m 3DEP tiles WITHOUT the National Map product API.

WHY THIS EXISTS. The product API answers HTTP 200 with an error body when it is unwell, and the
pipeline read that as "no 1 m lidar here" and quietly built the cell from 10 m elevation instead.
Thirteen cells were built that way on 2026-08-02, including the one holding Albuquerque, which has
nine 1 m surveys over it. The guard in `fetch.py` now refuses to infer absence from a fault — but
refusing still leaves the build stopped, and terrain does not change on the timescale of an outage.
A hill is where it was this morning.

So this resolves the same question from two sources that were up throughout, and neither of which is
the API:

  1. WESM.gpkg — USGS Work-unit Extent Spatial Metadata, the authoritative index of every 3DEP
     survey WITH ITS FOOTPRINT. 3.65 GB, but GDAL reads it over /vsicurl with ranged reads, so a
     spatial query costs about a second and downloads a few hundred KB.
  2. The staged-products S3 bucket, where every project directory carries a
     `0_file_download_links.txt` listing each of its tiles.

⚠️ THE INDEX AND THE STORAGE USE DIFFERENT NAMES. WESM's `workunit` is 'NM_SouthCentral_B6_2018';
the S3 directory is 'NM_SouthCentral_2018_D19'. It is the `project` field that matches the folder.
Using `workunit` yields a 404 for every survey and looks exactly like "this project has no tiles".
"""

import argparse
import json
import math
import re
import sys
import urllib.request

WESM = ("/vsicurl/https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/metadata/WESM.gpkg")
S3 = "https://prd-tnm.s3.amazonaws.com"
PROJECTS = "StagedProducts/Elevation/1m/Projects"
HTTP_TIMEOUT = 120
# `USGS_1M_13_x54y361_NM_SouthCentral_2018_D19.tif` -> zone 13, easting 540 km, northing 3610 km.
TILE_RE = re.compile(r"USGS_1M_(\d+)_x(\d+)y(\d+)_", re.I)
TILE_KM = 10                      # staged 1 m tiles are 10 km square
MAX_PROJECTS = 40                 # bounded (rule 2)


def utm_tile_bounds_lonlat(zone, x10km, y10km):
    """Approximate lon/lat box of a 10 km UTM tile, without pyproj.

    ⚠️ THE FILENAME NUMBERS ARE IN UNITS OF 10 km, NOT 1 km. `x68y360` is easting 680 000 m and
    northing 3 600 000 m — read as kilometres it lands at latitude 3.2 instead of 32, every tile
    misses every cell, and the resolver reports a confident "0 tiles from 0 surveys" for ground with
    705 tiles published over it.

    Inverse UTM by the standard series is overkill here: this only has to be good enough to decide
    whether a 10 km tile touches a 1 degree cell, and it is deliberately GENEROUS — a tile wrongly
    included costs one stream read, a tile wrongly excluded costs a hole in the terrain.
    """
    east_m, north_m = x10km * 10000.0, y10km * 10000.0
    k0, a, e2 = 0.9996, 6378137.0, 0.00669438
    lon0 = math.radians(-183 + 6 * int(zone))
    m = north_m / k0
    mu = m / (a * (1 - e2 / 4 - 3 * e2 ** 2 / 64))
    e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2))
    phi1 = (mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * math.sin(2 * mu)
            + (21 * e1 ** 2 / 16) * math.sin(4 * mu) + (151 * e1 ** 3 / 96) * math.sin(6 * mu))
    n1 = a / math.sqrt(1 - e2 * math.sin(phi1) ** 2)
    t1 = math.tan(phi1) ** 2
    ep2 = e2 / (1 - e2)
    c1 = ep2 * math.cos(phi1) ** 2
    r1 = a * (1 - e2) / (1 - e2 * math.sin(phi1) ** 2) ** 1.5
    d = (east_m - 500000.0) / (n1 * k0)
    lat = phi1 - (n1 * math.tan(phi1) / r1) * (d * d / 2 - (5 + 3 * t1 + 10 * c1) * d ** 4 / 24)
    lon = lon0 + (d - (1 + 2 * t1 + c1) * d ** 3 / 6) / math.cos(phi1)
    lat, lon = math.degrees(lat), math.degrees(lon)
    # A 10 km tile is at most ~0.12 deg of longitude at these latitudes; pad generously.
    pad_lat = TILE_KM / 111.0
    pad_lon = TILE_KM / (111.0 * max(0.25, math.cos(math.radians(lat))))
    return (lon, lat, lon + pad_lon * 1.15, lat + pad_lat * 1.15)


def surveys_over(west, south, east, north, max_gsd=1.0):
    """Every 3DEP survey whose footprint touches the box, at or finer than `max_gsd` metres."""
    from osgeo import ogr, gdal
    gdal.UseExceptions()
    gdal.SetConfigOption("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".gpkg")
    ds = ogr.Open(WESM)
    if ds is None:
        raise RuntimeError("WESM.gpkg unreachable — no fallback source for 1 m coverage")
    layer = ds.GetLayer(0)
    layer.SetSpatialFilterRect(west, south, east, north)
    out = {}
    for feat in layer:                                               # bounded by the spatial filter
        gsd = feat.GetField("dem_gsd_meters")
        if gsd is None or float(gsd) > max_gsd:
            continue
        # ⚠️ `project`, NOT `workunit` — see the module note. workunit 404s on every survey.
        proj = feat.GetField("project")
        if not proj:
            continue
        out.setdefault(proj, {"project": proj, "gsd": float(gsd),
                              "ql": feat.GetField("ql"),
                              "collect_end": str(feat.GetField("collect_end") or "")[:10]})
    return list(out.values())


def project_tiles(project):
    """Every tile URL a project publishes, from its own download-links manifest."""
    url = f"{S3}/{PROJECTS}/{project}/0_file_download_links.txt"
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as r:
            body = r.read().decode("utf-8", "replace")
    except Exception:                                                # noqa: BLE001
        return []
    return [ln.strip() for ln in body.splitlines()
            if ln.strip().lower().endswith(".tif") and "/TIFF/" in ln]


def resolve(west, south, east, north, max_gsd=1.0):
    """Tiles covering the box, as fetch.py's own tile dicts."""
    tiles, used = [], []
    for s in surveys_over(west, south, east, north, max_gsd)[:MAX_PROJECTS]:   # bounded (rule 2)
        hits = 0
        for url in project_tiles(s["project"]):                      # bounded by the manifest
            m = TILE_RE.search(url.rsplit("/", 1)[-1])
            if not m:
                continue
            zone, x_km, y_km = int(m.group(1)), int(m.group(2)), int(m.group(3))
            tw, ts, te, tn = utm_tile_bounds_lonlat(zone, x_km, y_km)
            if te < west or tw > east or tn < south or ts > north:
                continue
            tiles.append({"url": url, "project": s["project"],
                          "bbox": {"minX": tw, "minY": ts, "maxX": te, "maxY": tn}})
            hits += 1
        if hits:
            used.append(dict(s, tiles=hits))
    # A project can publish the same ground twice; the caller streams by URL so de-dupe on it.
    seen, uniq = set(), []
    for t in tiles:
        if t["url"] in seen:
            continue
        seen.add(t["url"])
        uniq.append(t)
    return uniq, used


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cell", required=True, help="cell id, e.g. n36w107")
    ap.add_argument("--max-gsd", type=float, default=1.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    lat_n, lon_w = int(a.cell[1:3]), -int(a.cell[4:7])
    tiles, used = resolve(lon_w, lat_n - 1, lon_w + 1, lat_n, a.max_gsd)
    if a.json:
        print(json.dumps({"tiles": tiles, "surveys": used}, indent=2))
        return 0
    print(f"{a.cell}: {len(tiles)} tile(s) from {len(used)} survey(s)")
    for s in used:
        print(f"  {s['tiles']:5d}  {s['gsd']:.2f} m  {s['ql'] or '?':6s}  {s['collect_end']}  "
              f"{s['project']}")
    return 0 if tiles else 1


if __name__ == "__main__":
    sys.exit(main())
