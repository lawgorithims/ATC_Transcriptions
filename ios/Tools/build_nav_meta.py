#!/usr/bin/env python3
"""Build the bundled nav-METADATA tables that back the interactive map's info popups.

Companion to `build_nav_db.py` (which emits coordinates only). This emits the *descriptive*
fields the ForeFlight-style tap-to-identify sheet shows, keyed by identifier, into
`ios/ATCTranscribe/Resources/nav/`:

  * `navaid_meta.json` — `{ IDENT: {"t":"VOR-DME","n":"BOSTON","f":112.7,"mv":-14.5} }`
      t  = navaid type (VOR / VOR-DME / VORTAC / TACAN / DME / NDB / NDB-DME)
      n  = name
      f  = frequency (MHz for VHF navaids; kHz for NDBs — the app labels the unit by `t`)
      mv = magnetic variation (deg; negative = west). Bundled now, used once the map adds
           magnetic bearings/radials — so that feature needs no data rebuild.
  * `airport_meta.json` — `{ IDENT: {"n":"John F Kennedy Intl","e":13} }`  (name, field elevation ft)

Runways + ATC frequencies for airports already ship in `airport_ctx.json` (built by
`build_airport_ctx.py`); this only adds the name + elevation those lack.

Source: OurAirports (CC0, public-domain — safe to bundle). Same `airports.csv` / `navaids.csv`
as `build_nav_db.py`; NO 250 MB FAA NASR download needed (fixes carry no descriptive metadata
worth showing beyond ident + coords). Coverage mirrors `build_nav_db.py` so every plotted object
has metadata: US airports (3-4 char ident) + all large airports; all navaids worldwide.

Run on a box with internet (regenerate when you refresh nav_coords.json):
  python3 build_nav_meta.py [--out-dir path]
"""
import argparse, csv, io, json, os, re, urllib.request

OURAIRPORTS = "https://davidmegginson.github.io/ourairports-data"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
US = {"US", "PR", "VI", "GU", "AS", "MP", "UM"}
NAVAID_TYPES = {"VOR", "VOR-DME", "VORTAC", "DME", "TACAN", "NDB", "NDB-DME"}


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    return urllib.request.urlopen(req, timeout=600).read()


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--us-only", action="store_true",
                    help="airports: US 3-4 char idents + large airports only (default: mirror build_nav_db).")
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(__file__), "..", "ATCTranscribe", "Resources", "nav"))
    args = ap.parse_args()
    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(out_dir, exist_ok=True)

    # ---- airports: name + elevation (same keep-filter as build_nav_db.py) ----
    print("airports (OurAirports)…", flush=True)
    airports = {}
    apt = csv.DictReader(io.StringIO(fetch(OURAIRPORTS + "/airports.csv").decode("utf-8", "replace")))
    for r in apt:
        t, ident = r["type"], (r["ident"] or "").strip().upper()
        if t in ("closed", "heliport", "seaplane_base", "balloonport"):
            continue
        keep = (r["iso_country"] in US and re.fullmatch(r"[A-Z0-9]{3,4}", ident)) or t == "large_airport"
        if not keep or not ident:
            continue
        meta = {}
        if r.get("name"):
            meta["n"] = r["name"].strip()
        elev = num(r.get("elevation_ft"))
        if elev is not None:
            meta["e"] = int(round(elev))
        if meta:
            airports.setdefault(ident, meta)   # first wins (OurAirports is deduped by ident anyway)

    # ---- navaids: type + name + frequency + magnetic variation (worldwide) ----
    print("navaids (OurAirports)…", flush=True)
    navaids = {}
    nav = csv.DictReader(io.StringIO(fetch(OURAIRPORTS + "/navaids.csv").decode("utf-8", "replace")))
    for r in nav:
        typ = r.get("type")
        if typ not in NAVAID_TYPES:
            continue
        ident = (r["ident"] or "").strip().upper()
        if not ident:
            continue
        meta = {"t": typ}
        if r.get("name"):
            meta["n"] = r["name"].strip()
        khz = num(r.get("frequency_khz"))
        if khz:
            meta["f"] = round(khz, 1) if "NDB" in typ else round(khz / 1000.0, 3)   # kHz for NDB, else MHz
        mv = num(r.get("magnetic_variation_deg"))
        if mv is not None:
            meta["mv"] = round(mv, 1)
        navaids.setdefault(ident, meta)   # first candidate wins on duplicate idents

    for name, obj in (("airport_meta.json", airports), ("navaid_meta.json", navaids)):
        path = os.path.join(out_dir, name)
        with open(path, "w") as f:
            json.dump(obj, f, separators=(",", ":"), sort_keys=True)
        print(f"{name}: {len(obj)} entries, {os.path.getsize(path)} bytes -> {path}")

    # sanity spot-checks
    for k in ("KJFK", "KBOS", "KDFW"):
        print(f"  airport {k}: {airports.get(k)}")
    for k in ("BOS", "JFK", "DFW", "LAX"):
        print(f"  navaid  {k}: {navaids.get(k)}")


if __name__ == "__main__":
    main()
