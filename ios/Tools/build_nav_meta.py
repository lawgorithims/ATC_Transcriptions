#!/usr/bin/env python3
"""Build the bundled nav-METADATA tables that back the interactive map's info popups.

Companion to `build_nav_db.py` (which emits coordinates only). This emits the *descriptive*
fields the ForeFlight-style tap-to-identify sheet shows, keyed by identifier, into
`ios/ATCTranscribe/Resources/nav/`:

  * `navaid_meta.json` — `{ IDENT: {"t":"VOR-DME","n":"BOSTON","f":112.7,"mv":-14.5} }`
      t  = navaid type (VOR / VOR-DME / VORTAC / TACAN / DME / NDB / NDB-DME)
      n  = name
      f  = frequency (MHz for VHF navaids; kHz for NDBs — the app labels the unit by `t`)
      mv = magnetic variation (deg; negative = west). SAFETY DATA — `Core/MagneticVariation.swift`
           converts published MAGNETIC hold courses against TRUE great-circle tracks with it, and a
           wrong value can name the wrong holding entry. Withheld entirely for any ident this
           snapshot saw more than once (see the dedup note below).
  * `airport_meta.json` — `{ IDENT: {"n":"John F Kennedy Intl","e":13} }`  (name, field elevation ft)

Runways + ATC frequencies for airports already ship in `airport_ctx.json` (built by
`build_airport_ctx.py`); this only adds the name + elevation those lack.

Source: OurAirports (CC0, public-domain — safe to bundle). Same `airports.csv` / `navaids.csv`
as `build_nav_db.py`; NO 250 MB FAA NASR download needed (fixes carry no descriptive metadata
worth showing beyond ident + coords). Coverage mirrors `build_nav_db.py` so every plotted object
has metadata: US airports (3-4 char ident) + all large airports; all navaids worldwide.

⚠️ PAIRED WITH `nav_coords.json` — NOT INDEPENDENTLY REGENERABLE. `MagneticVariation` trusts a
station's `mv` only when its ident is globally unique in `nav_coords.json`, then reads the value from
here; if the two files come from different OurAirports snapshots, an ident that looks unique there
can carry a different station's variation from here. Both builders now refuse to write when the
navaid ident sets disagree (`navdb.check_nav_pairing`), and `NavDataPairingTests` asserts it on the
shipped tables. To rebuild the pair, IN THIS ORDER, from one snapshot:

  python3 build_nav_db.py --pair --nasr-zip <cached.zip>   # writes nav_coords.json, check deferred
  python3 build_nav_meta.py                                # re-checks the pair, THEN writes

Run on a box with internet:
  python3 build_nav_meta.py [--out-dir path]
"""
import argparse, collections, csv, io, json, os, re, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import navdb   # noqa: E402 — the shared nav-table pairing predicate (one decoder, used by everyone)

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
    ap.add_argument("--pair", action="store_true",
                    help="defer the nav_coords.json pairing check. Normally UNNEEDED: run "
                         "build_nav_db.py --pair first, then this script without --pair so the pair "
                         "is validated before anything is written.")
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
    seen_idents = collections.Counter()
    nav = csv.DictReader(io.StringIO(fetch(OURAIRPORTS + "/navaids.csv").decode("utf-8", "replace")))
    for r in nav:
        typ = r.get("type")
        if typ not in NAVAID_TYPES:
            continue
        ident = (r["ident"] or "").strip().upper()
        if not ident:
            continue
        seen_idents[ident] += 1
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

    # ⚠️ A DUPLICATED IDENT MUST NOT SHIP A MAGNETIC VARIATION. "First candidate wins" above is fine
    # for the tap-to-identify sheet (type/name/frequency are cosmetic), but `mv` is safety data:
    # Core/MagneticVariation.swift uses it to convert published MAGNETIC hold courses against TRUE
    # great-circle tracks, and a wrong value can name the wrong holding entry. The app's defence is to
    # trust only idents that are globally unique in nav_coords.json — which fails the moment the two
    # files drift apart, and key-set equality does NOT detect that drift (measured 2026-07-29: the
    # shipped nav_coords and a live pull had identical 6,022-ident key sets while 11 idents were
    # unique in one and duplicated in the other). So withhold the number at the source instead:
    # if this snapshot saw the ident more than once, we cannot say WHICH station's variation we kept,
    # and an unknown variation is handled honestly downstream (the entry is reported unavailable)
    # whereas a confidently wrong one is not.
    dropped = 0
    for ident, count in seen_idents.items():
        if count > 1 and "mv" in navaids.get(ident, {}):
            del navaids[ident]["mv"]
            dropped += 1
    print("navaids: %d idents (%d duplicated → magnetic variation withheld), %d carry mv"
          % (len(navaids), dropped, sum(1 for m in navaids.values() if "mv" in m)), flush=True)

    # PAIRING GATE — refuse to write metadata that does not match the nav_coords.json it will be read
    # alongside. Checked BEFORE either file is written, so a failure can never leave the pair
    # half-updated. See navdb.check_nav_pairing for the hazard this closes.
    coords_path = os.path.join(out_dir, "nav_coords.json")
    if not os.path.exists(coords_path):
        print("note: no nav_coords.json in the output dir — nothing to pair against")
    elif args.pair:
        print("--pair: deferring the pairing check. Prefer running this script WITHOUT --pair as the "
              "second half of a paired rebuild, so the pair is actually validated.")
    else:
        with open(coords_path) as f:
            coords = json.load(f)
        problems = navdb.check_nav_pairing(coords, navaids, airports)
        if problems:
            raise SystemExit(
                "REFUSING TO WRITE: " + "; ".join(problems)
                + "\nnavaid_meta.json and nav_coords.json must come from ONE OurAirports snapshot "
                  "(magnetic variation depends on it). Rebuild the pair:\n"
                  "  python3 build_nav_db.py --pair --nasr-zip <cached.zip>\n"
                  "  python3 build_nav_meta.py")
        print("pairing OK against nav_coords.json")

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
