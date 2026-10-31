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
import sys, datetime as dt

SVC = ("https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/ArcGIS/rest/services/"
       "Special_Use_Airspace/FeatureServer/0/query")
UA = {"User-Agent": "Obelisk/1.0"}
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
        # An ArcGIS error payload carries `error` and NO `features`, so a bare .get(...,[]) turns a
        # failure into "zero results" and the caller cannot tell. Say which it was.
        if "error" in d:
            e = d["error"]
            raise RuntimeError(f"feature service error {e.get('code')}: {e.get('message')} "
                               f"{'; '.join(e.get('details') or [])}")
        if "features" not in d:
            raise RuntimeError(f"feature service returned no `features` key (got {sorted(d)[:6]}) — "
                               f"treating as a failure, not as an empty result")
        batch = d["features"]
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

    # ⚠️ REFUSE AN EMPTY OR COLLAPSED FETCH. THIS ALREADY DESTROYED THE LAYER ONCE.
    #
    # On 2026-10-19 a run returned ZERO features from a service that was up and holding 1,542 — a
    # transient hiccup, confirmed by the same `fetch_all()` returning 1,536 minutes later. The script
    # wrote the file anyway: 2,829 features became 1,286, every MOA, Restricted, Warning, Prohibited
    # and Alert area silently gone, and it printed "SUA kept=0" as if that were a result. Shipped,
    # that is an app drawing no special-use airspace at all and saying nothing — a pilot reads empty
    # as clear.
    #
    # `d.get("features", [])` in fetch_all is what makes it quiet: an error payload has no `features`
    # key, so a failure and an honestly-empty answer are indistinguishable downstream. The floor here
    # is the backstop. It is the same stance lz/fetch.py takes with `assert_coverage()`, and for the
    # same stated reason: a missing source must break the build, not thin the layer.
    MIN_SUA = 800                       # the service has held ~1,540; a real halving is still news
    if len(rows) < MIN_SUA:
        sys.exit(f"REFUSING to write: only {len(rows)} SUA features (expected >= {MIN_SUA}). The "
                 f"feature service returned little or nothing — almost certainly transient. The "
                 f"existing airspace.json is UNTOUCHED. Re-run; if it persists, check whether the "
                 f"service moved: {SVC}")

    out = os.path.abspath(args.out)
    # The file is `{cycle, from, to, features:[…]}` since airspace gained provenance. Older builds
    # wrote a bare array; read both so a part-migrated tree does not lose its class airspace.
    prev = json.load(open(out)) if os.path.exists(out) else {}
    if isinstance(prev, list):
        prev_features, meta = prev, {}
    else:
        prev_features, meta = prev.get("features", []), {k: prev.get(k) for k in ("cycle", "from", "to")}
    classrows = [r for r in prev_features if r.get("c") in ("B", "C", "D")]  # keep class airspace
    # The SUA floor below guards the fetch; this guards the half it does not. If the file we are
    # merging into has lost its class airspace, writing would compound one loss into two — and the
    # whole reason this script re-reads the file is that build_airspace_db.py put those rows there.
    MIN_CLASS = 800
    if len(classrows) < MIN_CLASS:
        sys.exit(f"REFUSING to write: the existing airspace file holds only {len(classrows)} class "
                 f"B/C/D rows (expected >= {MIN_CLASS}). Run build_airspace_db.py first — merging "
                 f"into a thinned file would lose what is left of it.")
    if not meta.get("cycle"):
        sys.exit("the airspace file carries no cycle — run build_airspace_db.py first. Merging SUA "
                 "into an undated file would produce exactly the undated artifact that made 2,829 "
                 "features invisible to the currency sweep.")
    # SUA comes from a CONTINUOUSLY updated feature service, not the 28-day NASR chain, so it gets
    # its own fetch date rather than borrowing a cycle it does not belong to. Reporting it under the
    # NASR cycle would overstate how fresh it is on the day the cycle rolls.
    doc = dict(meta)
    doc["sua_fetched"] = dt.date.today().isoformat()
    doc["features"] = classrows + rows
    merged = doc["features"]
    with open(out, "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    import collections
    dist = collections.Counter(r["c"] for r in rows)
    print(f"SUA kept={kept} {dict(dist)} | class rows kept={len(classrows)} | total={len(merged)} "
          f"bytes={os.path.getsize(out)} -> {out}")


if __name__ == "__main__":
    main()
