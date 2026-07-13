#!/usr/bin/env python3
"""Add Special Use Airspace (Restricted / Prohibited / Warning / Alert / MOA / Danger) to the bundled
airspace table, from the FAA's authoritative ArcGIS feature service (no NASR zip needed).

Fetches https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/.../Special_Use_Airspace/FeatureServer/0, keeps
US areas, maps TYPE_CODE → a compact class code, parses floor/ceiling, simplifies each ring with
Douglas-Peucker (shared with build_airspace_db), and MERGES into nav/airspace.json (preserving the
existing Class B/C/D rows, replacing any prior SUA rows). Same row shape NavDatabase.swift already reads:

    {"c":"R","n":"R-2508","lo":0,"hi":40000,"bb":[minLat,minLon,maxLat,maxLon],"r":[[[lat,lon],...],...]}

class codes: B/C/D (class airspace, pre-existing) · R Restricted · P Prohibited · W Warning · A Alert ·
             MOA Military Operations Area · D Danger
"""
import argparse, json, math, os, urllib.request

SVC = ("https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/ArcGIS/rest/services/"
       "Special_Use_Airspace/FeatureServer/0/query")
UA = {"User-Agent": "CommSight/1.0"}
SUA_CODES = {"R", "P", "W", "A", "MOA", "D", "TFR"}   # the codes we keep + render


def _perp(p, a, b):
    kx = math.cos(math.radians((a[0] + b[0]) * 0.5))
    ay, ax = a[0], a[1] * kx; by, bx = b[0], b[1] * kx; py, px = p[0], p[1] * kx
    dx, dy = bx - ax, by - ay; seg2 = dx * dx + dy * dy
    if seg2 == 0.0: return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def dp(pts, tol):
    if len(pts) < 3: return pts
    a, b = pts[0], pts[-1]; dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        d = _perp(pts[i], a, b)
        if d > dmax: dmax, idx = d, i
    if dmax > tol: return dp(pts[:idx + 1], tol)[:-1] + dp(pts[idx:], tol)
    return [a, b]


UNLIMITED = 99999   # sentinel → the app shows "UNL"


def alt_ft(val, uom, code, is_lower):
    """Parse an FAA altitude cell → feet (surface→0, unlimited→UNLIMITED, FL→×100)."""
    code = (code or "").upper()
    if code == "UNLTD":
        return UNLIMITED
    if is_lower and code == "SFC":
        return 0
    try:
        v = float(val)
    except (TypeError, ValueError):
        return None
    if v < 0:                       # negative sentinel (e.g. -9998) = unlimited
        return UNLIMITED
    return int(v * 100) if (uom or "").upper() == "FL" else int(v)


def fetch_all():
    feats, offset = [], 0
    while True:
        q = (f"{SVC}?where=COUNTRY%3D%27UNITED+STATES%27&outFields=NAME,TYPE_CODE,"
             f"LOWER_VAL,LOWER_UOM,LOWER_CODE,UPPER_VAL,UPPER_UOM,UPPER_CODE&"
             f"returnGeometry=true&outSR=4326&resultOffset={offset}&resultRecordCount=1000&f=json")
        d = json.loads(urllib.request.urlopen(urllib.request.Request(q, headers=UA), timeout=90).read())
        batch = d.get("features", [])
        feats += batch
        print(f"  fetched {len(feats)} SUA features…", flush=True)
        if not d.get("exceededTransferLimit") or not batch:
            break
        offset += len(batch)
    return feats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tol", type=float, default=0.0015, help="DP tolerance in degrees (~150 m)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__),
                    "..", "ATCTranscribe", "Resources", "nav", "airspace.json"))
    args = ap.parse_args()

    print("fetching FAA Special Use Airspace…", flush=True)
    feats = fetch_all()
    # Standing National-Defense-Airspace TFR areas (clean, from ArcGIS) → type "TFR". The DYNAMIC daily
    # TFRs (fires / VIP / stadiums) come from a separate live feed handled in-app.
    tfr_svc = SVC.replace("Special_Use_Airspace", "National_Defense_Airspace_TFR_Areas")
    try:
        tq = (f"{tfr_svc}?where=COUNTRY%3D%27UNITED+STATES%27&outFields=NAME,TYPE_CODE&"
              f"returnGeometry=true&outSR=4326&resultRecordCount=2000&f=json")
        tfeats = json.loads(urllib.request.urlopen(urllib.request.Request(tq, headers=UA), timeout=90).read()).get("features", [])
        for f in tfeats:
            f["attributes"]["TYPE_CODE"] = "TFR"   # standing NDA TFR: surface→unlimited by NOTAM
        feats = feats + tfeats
        print(f"  + {len(tfeats)} standing National-Defense TFR areas", flush=True)
    except Exception as e:
        print(f"  (NDA TFR fetch skipped: {e})", flush=True)

    rows, kept = [], 0
    for f in feats:
        a = f["attributes"]; code = (a.get("TYPE_CODE") or "").strip().upper()
        if code not in SUA_CODES: continue
        geom = f.get("geometry") or {}
        rings_xy = geom.get("rings") or []
        rings = []
        for ring in rings_xy:
            latlon = [[round(y, 5), round(x, 5)] for x, y in ring]   # ArcGIS [lon,lat] → [lat,lon]
            simp = dp(latlon, args.tol)
            if len(simp) >= 3: rings.append(simp)
        if not rings: continue
        lat = [p[0] for r in rings for p in r]; lon = [p[1] for r in rings for p in r]
        lo = alt_ft(a.get("LOWER_VAL"), a.get("LOWER_UOM"), a.get("LOWER_CODE"), True)
        hi = alt_ft(a.get("UPPER_VAL"), a.get("UPPER_UOM"), a.get("UPPER_CODE"), False)
        if code == "TFR":                       # standing NDA TFR: surface → unlimited by NOTAM
            lo = 0 if lo is None else lo
            hi = UNLIMITED if hi is None else hi
        rows.append({"c": code, "n": (a.get("NAME") or "").strip(),
                     "lo": lo, "hi": hi,
                     "bb": [round(min(lat), 4), round(min(lon), 4), round(max(lat), 4), round(max(lon), 4)],
                     "r": rings})
        kept += 1

    out = os.path.abspath(args.out)
    existing = json.load(open(out)) if os.path.exists(out) else []
    classrows = [r for r in existing if r.get("c") in ("B", "C", "D")]   # keep pre-existing class airspace
    merged = classrows + rows
    with open(out, "w") as fh:
        json.dump(merged, fh, separators=(",", ":"))
    import collections
    dist = collections.Counter(r["c"] for r in rows)
    print(f"SUA kept={kept} {dict(dist)} | class rows kept={len(classrows)} | total={len(merged)} "
          f"bytes={os.path.getsize(out)} -> {out}")


if __name__ == "__main__":
    main()
