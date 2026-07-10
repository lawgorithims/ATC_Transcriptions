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
# chart_code → the app-facing category we keep. Everything else (MIN/LAH/HOT/DAU/…) is dropped.
KEEP = {"IAP": "approach", "DP": "departure", "ODP": "departure", "STAR": "arrival", "APD": "diagram"}


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
    print(f"cycle {cycle}", flush=True)

    airports = {}      # ICAO ident → [ {c: category, n: chart_name, f: pdf_name} ]
    n_apt = n_rec = 0
    for apt in root.iter("airport_name"):
        icao = (apt.get("icao_ident") or apt.get("apt_ident") or "").strip().upper()
        if not icao:
            continue
        procs = []
        for rec in apt.findall("record"):
            code = (rec.findtext("chart_code") or "").strip()
            cat = KEEP.get(code)
            if not cat:
                continue
            name = (rec.findtext("chart_name") or "").strip()
            pdf = (rec.findtext("pdf_name") or "").strip()
            if not name:
                continue
            procs.append({"c": cat, "n": name, "f": pdf})
            n_rec += 1
        if procs:
            airports.setdefault(icao, []).extend(procs)
            n_apt += 1

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump({"cycle": cycle, "airports": airports}, f, separators=(",", ":"), sort_keys=True)
    print(f"cycle={cycle} airports={n_apt} records={n_rec} bytes={os.path.getsize(out)} -> {out}")

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
