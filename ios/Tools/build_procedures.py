#!/usr/bin/env python3
"""Build the bundled terminal-procedures index for the map's airport info.

Emits `ios/ATCTranscribe/Resources/nav/procedures.json` — per airport, the published FAA terminal
procedures (instrument approaches, departures/ODPs, arrivals, airport diagram) with their chart name
and plate-PDF filename, so tapping an airport can list "ILS OR LOC RWY 4R", "LOGAN SIX DEPARTURE", …
and (later) open the plate at `https://aeronav.faa.gov/d-tpp/<cycle>/<pdf>`.

Source: FAA **d-TPP** metafile (public domain), the electronic Terminal Procedures index. The "current"
metafile always points at the effective 28-day cycle:
    https://nfdc.faa.gov/webContent/dtpp/current.xml
Schema: digital_tpp[cycle] → state_code → city_name → airport_name[icao_ident, apt_ident] →
        record(chart_code, chart_name, pdf_name). chart_code: IAP=approach, DP=SID, ODP=obstacle
        departure, STAR=arrival, APD=airport diagram, MIN/LAH/HOT/DAU=other (skipped).

This is the procedure LIST + plate references only — NOT coded ARINC-424 geometry (drawing the
procedure on the map is a separate CIFP effort). No 1 GB plate download; just the small index.

Run on a box with internet (regenerate when you bump the chart cycle):
    python3 build_procedures.py [--metafile URL] [--out path.json]
"""
import argparse, json, os, urllib.request
import xml.etree.ElementTree as ET

METAFILE = "https://nfdc.faa.gov/webContent/dtpp/current.xml"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
# We keep the RAW FAA chart_code (stored in "c") and let the APP bucket it into the ForeFlight-style
# tabs — Airport (APD/HOT/LAH), Departure (DP/ODP + takeoff MIN), Arrival (STAR + alternate MIN),
# Approach (IAP/CVFP), Other (everything else). Keeping the raw code (vs. a pre-collapsed category)
# is what lets a MIN doc land under Departure or Arrival by its chart name, and fixes STARs being
# absent from the old build.
# NOTE: the FAA d-TPP metafile codes arrivals as "STR" (NOT "STAR") — using "STAR" is why the old
# build silently dropped every arrival. Keep "STR".
KEEP_CODES = {"IAP", "DP", "ODP", "STR", "APD", "MIN", "LAH", "HOT", "CVFP", "DVA"}

# ~7 FAA-ish regions (by state) so the app can offer region bundle downloads.
REGIONS = {
    "Northeast":     {"ME", "NH", "VT", "MA", "RI", "CT", "NY", "NJ", "PA"},
    "Southeast":     {"MD", "DE", "DC", "VA", "WV", "NC", "SC", "GA", "FL", "KY", "TN", "AL", "MS", "PR", "VI"},
    "North Central": {"OH", "MI", "IN", "IL", "WI", "MN", "IA", "MO", "ND", "SD", "NE", "KS"},
    "South Central": {"TX", "OK", "AR", "LA", "NM"},
    "Northwest":     {"WA", "OR", "ID", "MT", "WY"},
    "Southwest":     {"CA", "NV", "UT", "AZ", "CO"},
    "Alaska":        {"AK"},
    "Pacific":       {"HI", "GU", "MP", "AS"},
}


def isodate(s):
    """FAA edate '0901Z  07/09/26' → ISO '2026-07-09' (empty on parse failure)."""
    try:
        mdy = s.strip().split()[-1]              # '07/09/26'
        mm, dd, yy = mdy.split("/")
        return f"20{yy}-{mm}-{dd}"
    except Exception:
        return ""


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    return urllib.request.urlopen(req, timeout=600).read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metafile", default=METAFILE)
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(__file__), "..", "ATCTranscribe", "Resources", "nav", "procedures.json"))
    args = ap.parse_args()

    print("fetching d-TPP metafile…", flush=True)
    root = ET.fromstring(fetch(args.metafile))
    cycle = root.get("cycle") or ""
    eff = isodate(root.get("from_edate"))   # cycle effective / expiry (28-day chart cycle window)
    exp = isodate(root.get("to_edate"))
    print(f"cycle {cycle}  {eff}..{exp}", flush=True)

    airports = {}      # ICAO ident → [ {c: raw chart_code, n: chart_name, f: pdf_name} ]
    state_of = {}      # ICAO → 2-letter state code (for region bundles)
    n_apt = n_rec = 0
    for state in root.iter("state_code"):
        sid = (state.get("ID") or "").strip().upper()
        for apt in state.iter("airport_name"):
            icao = (apt.get("icao_ident") or apt.get("apt_ident") or "").strip().upper()
            if not icao:
                continue
            procs = []
            for rec in apt.findall("record"):
                code = (rec.findtext("chart_code") or "").strip().upper()
                if code not in KEEP_CODES:
                    continue
                name = (rec.findtext("chart_name") or "").strip()
                pdf = (rec.findtext("pdf_name") or "").strip()
                if not name or not pdf:
                    continue
                procs.append({"c": code, "n": name, "f": pdf})
                n_rec += 1
            if procs:
                airports.setdefault(icao, []).extend(procs)
                if sid:
                    state_of[icao] = sid
                n_apt += 1

    # Group airports into ~7 FAA-ish regions (by state) so the app can offer region bundle downloads.
    regions = {name: sorted(i for i in airports if state_of.get(i) in states)
               for name, states in REGIONS.items()}
    # Sweep any airport not captured by a region (territories with an unlisted state code, or a blank
    # code) into Pacific, so no airport is silently undownloadable via a region bundle (C7).
    assigned = set().union(*regions.values()) if regions else set()
    orphans = sorted(i for i in airports if i not in assigned)
    if orphans:
        regions["Pacific"] = sorted(set(regions.get("Pacific", [])) | set(orphans))
        print(f"swept {len(orphans)} orphan airports into Pacific: {orphans[:12]}")
    regions = {k: v for k, v in regions.items() if v}

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump({"cycle": cycle, "from": eff, "to": exp, "airports": airports, "regions": regions},
                  f, separators=(",", ":"), sort_keys=True)
    print(f"cycle={cycle} {eff}..{exp} airports={n_apt} records={n_rec} "
          f"regions={ {k: len(v) for k, v in regions.items()} } bytes={os.path.getsize(out)} -> {out}")

    for k in ("KBOS", "KJFK", "KDFW", "KLAX"):
        procs = airports.get(k, [])
        by = {}
        for p in procs:
            by.setdefault(p["c"], 0)
            by[p["c"]] += 1
        print(f"  {k}: {len(procs)} charts {dict(by)}")
        for p in procs[:3]:
            print(f"      {p['c']:9} {p['n']}  [{p['f']}]")


if __name__ == "__main__":
    main()
