#!/usr/bin/env python3
"""Build the bundled Class B/C/D airspace-outline table for the route map.

Extracts lateral airspace boundaries from the FAA NASR 28-Day Subscription
`Additional_Data/Shape_Files/Class_Airspace.shp` (US Gov, public domain),
keeps Class B / C / D (drops the ~4300 Class E polygons), simplifies each ring
with Douglas-Peucker (pure-python — no shapely/GEOS dependency) to keep the
bundle small, and writes a compact JSON consumed by NavDatabase.swift:

    [ {"c":"B","n":"BOSTON","lo":0,"hi":10000,
       "bb":[minLat,minLon,maxLat,maxLon],
       "r":[[[lat,lon],...ring...], ...more rings...]}, ... ]

Coordinates are NAD83 geographic (lat/lon) — within a chart line's width of
WGS84, fine for a display overlay. Rendered as MapPolygons in RouteMapSheet.
Needs `pyshp` (pure-python shapefile reader): pip3 install --user pyshp

Run on a box with the NASR zip (the same one build_nav_db.py uses):
  python3 build_airspace_db.py --nasr-zip nasr.zip [--out path.json] [--tol 0.0015]
"""
import argparse, json, math, os, shutil, sys, tempfile, zipfile

sys.setrecursionlimit(1_000_000)  # some Class B rings have thousands of vertices


def _perp(p, a, b):
    """Perpendicular distance from p to segment a-b, in degrees (lon scaled by cos lat)."""
    kx = math.cos(math.radians((a[0] + b[0]) * 0.5))
    ay, ax = a[0], a[1] * kx
    by, bx = b[0], b[1] * kx
    py, px = p[0], p[1] * kx
    dx, dy = bx - ax, by - ay
    seg2 = dx * dx + dy * dy
    if seg2 == 0.0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def dp(points, tol):
    """Douglas-Peucker simplification; always keeps the two endpoints."""
    if len(points) < 3:
        return points
    a, b = points[0], points[-1]
    dmax, idx = 0.0, 0
    for i in range(1, len(points) - 1):
        d = _perp(points[i], a, b)
        if d > dmax:
            dmax, idx = d, i
    if dmax > tol:
        return dp(points[:idx + 1], tol)[:-1] + dp(points[idx:], tol)
    return [a, b]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nasr-zip", required=True)
    ap.add_argument("--tol", type=float, default=0.0015, help="DP tolerance in degrees (~150 m)")
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(__file__), "..", "ATCTranscribe", "Resources", "nav", "airspace.json"))
    args = ap.parse_args()
    import shapefile  # pyshp

    tmp = tempfile.mkdtemp()
    try:
        base = "Additional_Data/Shape_Files/Class_Airspace"
        with zipfile.ZipFile(args.nasr_zip) as zf:
            for ext in (".shp", ".dbf", ".shx", ".prj"):
                with zf.open(base + ext) as src, open(os.path.join(tmp, "asp" + ext), "wb") as dst:
                    shutil.copyfileobj(src, dst)

        r = shapefile.Reader(os.path.join(tmp, "asp"))
        flds = [f[0] for f in r.fields[1:]]

        def ival(d, k):
            try:
                return int(float(d.get(k)))
            except (TypeError, ValueError):
                return None

        out, kept = [], {"B": 0, "C": 0, "D": 0}
        for sr in r.iterShapeRecords():
            d = dict(zip(flds, sr.record))
            cls = (d.get("CLASS") or "").strip().upper()
            if cls not in ("B", "C", "D"):
                continue
            pts = sr.shape.points  # (lon, lat)
            parts = list(sr.shape.parts) + [len(pts)]
            rings = []
            for i in range(len(parts) - 1):
                seg = pts[parts[i]:parts[i + 1]]
                ring = [[round(p[1], 5), round(p[0], 5)] for p in seg]  # -> (lat, lon)
                if len(ring) >= 4:
                    simp = dp(ring, args.tol)
                    if len(simp) >= 4:
                        rings.append(simp)
            if not rings:
                continue
            flat = [p for ring in rings for p in ring]
            lats = [p[0] for p in flat]
            lons = [p[1] for p in flat]
            out.append({
                "c": cls,
                "n": (d.get("NAME") or "").strip()[:40],
                "lo": ival(d, "LOWER_VAL"),
                "hi": ival(d, "UPPER_VAL"),
                "bb": [round(min(lats), 4), round(min(lons), 4),
                       round(max(lats), 4), round(max(lons), 4)],
                "r": rings,
            })
            kept[cls] += 1

        out.sort(key=lambda e: (e["c"], e["n"]))
        outp = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(outp), exist_ok=True)
        with open(outp, "w") as f:
            json.dump(out, f, separators=(",", ":"))
        nring = sum(len(e["r"]) for e in out)
        nvert = sum(len(rr) for e in out for rr in e["r"])
        print(f"kept {kept} features={len(out)} rings={nring} verts={nvert} "
              f"bytes={os.path.getsize(outp)} -> {outp}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
