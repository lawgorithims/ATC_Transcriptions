#!/usr/bin/env python3
"""Build the bundled nav-coordinate table for the route map.

Generates `ios/ATCTranscribe/Resources/nav/nav_coords.json` — a compact
`{ IDENT: [[lat, lon], ...] }` table: candidate coordinates per identifier
(idents aren't globally unique, so the app picks the candidate nearest the
previous route point — see NavDatabase.swift / RouteResolver.swift). Used to
plot filed VORs and RNAV fixes on the route map. Airports keep resolving via the
smaller curated `icao_coords.json` first, with this table as the fallback and the
source of the navaids + fixes.

Sources — all public-domain / CC0, safe to bundle in the App Store build:
  * Airports + navaids: OurAirports (CC0), stable CSV on GitHub Pages.
  * US enroute fixes: FAA NASR 28-Day Subscription (US Gov, public domain) —
    `FIX.txt` (fixed-width; layout in the zip's `Layout_Data/fix_rf.txt`).
    The subscription URL is dated on a 28-day cycle; the current effective date
    is listed at faa.gov/.../aero_data/NASR_Subscription/. The zip is
    `nfdc.faa.gov/webContent/28DaySub/28DaySubscription_Effective_<YYYY-MM-DD>.zip`
    (~250 MB). NOTE: that server 503s HEAD requests but serves GET fine.

Run on a box with internet (regenerate when you bump the NASR cycle):
  python3 build_nav_db.py [--nasr-zip nasr.zip] [--nasr-date 2026-06-11] [--out path.json]
"""
import argparse, csv, io, json, os, re, urllib.request, zipfile

OURAIRPORTS = "https://davidmegginson.github.io/ourairports-data"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
US = {"US", "PR", "VI", "GU", "AS", "MP", "UM"}
NAVAID_TYPES = {"VOR", "VOR-DME", "VORTAC", "DME", "TACAN", "NDB", "NDB-DME"}


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    return urllib.request.urlopen(req, timeout=600).read()


def parse_dms(s):
    """'34-36-21.290N' / '087-16-24.123W' → signed decimal degrees, or None."""
    s = s.strip()
    if len(s) < 6 or s[-1] not in "NSEW":
        return None
    parts = s[:-1].split("-")
    if len(parts) != 3:
        return None
    try:
        d, m, sec = float(parts[0]), float(parts[1]), float(parts[2])
    except ValueError:
        return None
    v = d + m / 60.0 + sec / 3600.0
    return -v if s[-1] in "SW" else v


def add(table, ident, lat, lon, t):
    """t: kind code — 0=airport, 1=navaid (VOR/NDB/…), 2=enroute fix."""
    ident = (ident or "").strip().upper()
    if not ident or lat is None or lon is None:
        return
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return
    pair = [round(lat, 5), round(lon, 5), t]
    lst = table.setdefault(ident, [])
    if pair not in lst:
        lst.append(pair)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nasr-zip", help="local NASR subscription zip (else download by --nasr-date)")
    ap.add_argument("--nasr-date", default="2026-06-11")
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(__file__), "..", "ATCTranscribe", "Resources", "nav", "nav_coords.json"))
    args = ap.parse_args()

    table = {}

    print("airports (OurAirports)…", flush=True)
    n_apt = 0
    apt = csv.DictReader(io.StringIO(fetch(OURAIRPORTS + "/airports.csv").decode("utf-8", "replace")))
    for r in apt:
        t, ident = r["type"], r["ident"]
        if t in ("closed", "heliport", "seaplane_base", "balloonport"):
            continue
        keep = (r["iso_country"] in US and re.fullmatch(r"[A-Z0-9]{3,4}", ident or "")) or t == "large_airport"
        if not keep:
            continue
        try:
            add(table, ident, float(r["latitude_deg"]), float(r["longitude_deg"]), 0)
            n_apt += 1
        except (ValueError, KeyError):
            pass

    print("navaids (OurAirports)…", flush=True)
    n_nav = 0
    nav = csv.DictReader(io.StringIO(fetch(OURAIRPORTS + "/navaids.csv").decode("utf-8", "replace")))
    for r in nav:
        if r["type"] not in NAVAID_TYPES:
            continue
        try:
            add(table, r["ident"], float(r["latitude_deg"]), float(r["longitude_deg"]), 1)
            n_nav += 1
        except (ValueError, KeyError):
            pass

    print("fixes (FAA NASR)…", flush=True)
    if args.nasr_zip:
        zf = zipfile.ZipFile(args.nasr_zip)
    else:
        url = f"https://nfdc.faa.gov/webContent/28DaySub/28DaySubscription_Effective_{args.nasr_date}.zip"
        print("  downloading", url, flush=True)
        zf = zipfile.ZipFile(io.BytesIO(fetch(url)))
    n_fix = 0
    with zf.open("FIX.txt") as fh:
        for raw in io.TextIOWrapper(fh, encoding="latin-1"):
            if not raw.startswith("FIX1"):
                continue
            add(table, raw[4:34], parse_dms(raw[66:80]), parse_dms(raw[80:94]), 2)
            n_fix += 1

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(table, f, separators=(",", ":"), sort_keys=True)
    print(f"airports={n_apt} navaids={n_nav} fixes={n_fix} idents={len(table)} "
          f"bytes={os.path.getsize(out)} -> {out}")
    for k in ("KBOS", "BOS", "ROBUC", "KDFW", "DFW", "BLECO"):
        print(f"  {k}: {table.get(k)}")


if __name__ == "__main__":
    main()
