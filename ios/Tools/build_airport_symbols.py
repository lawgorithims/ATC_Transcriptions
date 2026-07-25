#!/usr/bin/env python3
"""build_airport_symbols.py — the airport ATTRIBUTES behind FAA sectional symbology.

The FAA encodes a great deal in an airport symbol: tower status (blue vs magenta), fuel (tick marks),
a rotating beacon (star), hard vs soft surface and runway length (filled circle / open circle / bare
runway outline), and distinct glyphs for heliports, seaplane bases, ultralight parks, private and
unverified fields, abandoned strips, and military airports. None of that was on the device — the
bundled `airport_meta.json` carries only elevation and name — so this builds it.

SOURCES (both public domain / US Government):
  1. aviationweather.gov/api/data/airport — the FAA NASR airport record: `tower`, `beacon`,
     `services`, `owner`, `type`, and per-runway surface/dimension. This is the authoritative set.
     NASR's own 28-day APT download (nfdc.faa.gov) is the usual source but was returning 503, and
     this endpoint serves the same fields from the same government data.
  2. ourairports-data/airports.csv — public-domain, used as a CROSS-CHECK for the airport TYPE
     (heliport / seaplane_base / closed / balloonport), which the API reports less consistently for
     small fields.

Runway GEOMETRY is deliberately NOT taken from here: cifp.sqlite already carries per-runway-end
bearing and length for 6,383 airports, which is what the symbol's runway lines are drawn from. What
this adds is the SURFACE type, which CIFP does not encode.

The API returns an EMPTY BODY (not an error) for a batch whose idents it does not know — most of the
14k US idents are private strips it has no record for — so an empty response is normal, not a failure.

Resumable: partial results are written after every batch, and a re-run skips what is already fetched.

Usage:  python3 Tools/build_airport_symbols.py [--limit N] [--out PATH]
"""
import json, os, sys, time, urllib.request, urllib.error, csv, io, gzip, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
NAV = os.path.join(HERE, "..", "ATCTranscribe", "Resources", "nav")
META = os.path.join(NAV, "airport_meta.json")
OUT_DEFAULT = os.path.join(NAV, "airport_symbols.json")
CACHE = "/tmp/airport_symbols_partial.json"
OURAIRPORTS = "https://davidmegginson.github.io/ourairports-data/airports.csv"
API = "https://aviationweather.gov/api/data/airport"
BATCH = 50
PAUSE = 0.25            # be a polite client to a government service

def log(m): print(m, flush=True)

def fetch_batch(idents):
    """One API call. Returns [] for an unknown-ident batch (empty body is the API's 'no match')."""
    url = f"{API}?ids={','.join(idents)}&format=json"
    try:
        raw = urllib.request.urlopen(url, timeout=45).read()
    except Exception as e:
        log(f"    batch error {type(e).__name__} — retrying once")
        time.sleep(2.0)
        try:
            raw = urllib.request.urlopen(url, timeout=45).read()
        except Exception:
            return None                       # signal failure so the caller can keep the ident queued
    if not raw.strip():
        return []                             # no idents in this batch are known — normal
    try:
        return json.loads(raw)
    except Exception:
        return []

def compact(rec):
    """Keep only what the symbol needs, in a short-key form (this ships in the app bundle)."""
    def flag(v): return 1 if (v not in (None, "", "N", 0)) else 0
    rwy_surfaces = []
    for r in (rec.get("runways") or [])[:32]:                 # bounded
        s = (r.get("surface") or "").upper()
        if s: rwy_surfaces.append(s)
    out = {
        "t": flag(rec.get("tower")),                          # control tower
        "b": flag(rec.get("beacon")),                         # rotating beacon
        "f": flag(rec.get("services")),                       # fuel / services available
        "o": (rec.get("owner") or "")[:1].upper(),            # P public, M military, …
        "y": (rec.get("type") or "")[:4].upper(),             # ARP / HEL / SPB / ULT …
    }
    if rwy_surfaces:
        # Hard if ANY runway is asphalt/concrete — matches the FAA "hard-surfaced runway" wording.
        hard = any(s.startswith(("A", "C", "ASP", "CON")) for s in rwy_surfaces)
        out["s"] = "H" if hard else "S"
    return out

def load_ourairports():
    """type per ident: heliport / seaplane_base / closed / balloonport / *_airport."""
    try:
        raw = urllib.request.urlopen(OURAIRPORTS, timeout=90).read().decode("utf-8", "replace")
    except Exception as e:
        log(f"  OurAirports fetch failed ({type(e).__name__}) — continuing without the cross-check")
        return {}
    out = {}
    for row in csv.DictReader(io.StringIO(raw)):
        if (row.get("iso_country") or "") != "US":
            continue
        for key in (row.get("ident"), row.get("gps_code"), row.get("local_code")):
            k = (key or "").strip().upper()
            if k:
                out.setdefault(k, (row.get("type") or "").strip())
    log(f"  OurAirports: {len(out)} US idents")
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", default=OUT_DEFAULT)
    a = ap.parse_args()

    idents = sorted(json.load(open(META)).keys())
    if a.limit: idents = idents[:a.limit]
    log(f"== airport symbol attributes for {len(idents)} idents ==")

    have = {}
    if os.path.exists(CACHE):
        try:
            have = json.load(open(CACHE)); log(f"  resuming with {len(have)} already fetched")
        except Exception: have = {}

    todo = [i for i in idents if i not in have]
    log(f"  {len(todo)} to fetch in batches of {BATCH}")
    done_batches = 0
    for i in range(0, len(todo), BATCH):
        batch = todo[i:i + BATCH]
        recs = fetch_batch(batch)
        if recs is None:
            log("    batch failed twice — leaving these queued for a re-run")
            continue
        for r in recs:
            for key in (r.get("icaoId"), r.get("faaId")):
                k = (key or "").strip().upper()
                if k: have[k] = compact(r)
        # Mark every ident in the batch as SEEN so a re-run doesn't refetch the unknown ones forever.
        for b in batch:
            have.setdefault(b, {})
        done_batches += 1
        if done_batches % 10 == 0:
            json.dump(have, open(CACHE, "w"))
            known = sum(1 for v in have.values() if v)
            log(f"    {i + len(batch)}/{len(todo)}  ({known} with attributes)")
        time.sleep(PAUSE)
    json.dump(have, open(CACHE, "w"))

    # ---- merge the other sources -------------------------------------------------------------
    # The API only has a record for the ~25% of idents that are significant public airports; the rest
    # are private strips. Those still get a symbol, from data already on the device.

    # (a) OurAirports TYPE, for EVERY ident (not just the API-known ones).
    oa = load_ourairports()
    TYPE_MAP = {"heliport": "HEL", "seaplane_base": "SPB", "closed": "CLS", "balloonport": "BLN"}
    typed = 0
    for ident in idents:
        t = TYPE_MAP.get(oa.get(ident, ""), "")
        if not t: continue
        rec = have.setdefault(ident, {})
        if rec.get("y") not in ("HEL", "SPB"):        # never override the authoritative API type
            rec["y"] = t; typed += 1
    log(f"  OurAirports set/refined the type for {typed} airports")

    # (b) TOWER from the already-bundled frequency table: a published TWR frequency IS a control
    #     tower, and this covers airports the API has no record for. Only fills, never overrides.
    try:
        ctx = json.load(open(os.path.join(NAV, "airport_ctx.json")))
    except Exception:
        ctx = {}
    towers = 0
    for ident, v in ctx.items():
        if not (isinstance(v, list) and len(v) > 1 and isinstance(v[1], dict)): continue
        if "TWR" not in v[1]: continue
        rec = have.setdefault(ident.upper(), {})
        if "t" not in rec: rec["t"] = 1; towers += 1
    log(f"  bundled TWR frequencies filled tower status for {towers} more airports")

    final = {k: v for k, v in have.items() if v}
    json.dump(final, open(a.out, "w"), separators=(",", ":"), sort_keys=True)
    size = os.path.getsize(a.out)
    towered = sum(1 for v in final.values() if v.get("t"))
    fuel    = sum(1 for v in final.values() if v.get("f"))
    beacon  = sum(1 for v in final.values() if v.get("b"))
    mil     = sum(1 for v in final.values() if v.get("o") == "M")
    hel     = sum(1 for v in final.values() if v.get("y") == "HEL")
    spb     = sum(1 for v in final.values() if v.get("y") == "SPB")
    log(f"WROTE {a.out}  {len(final)} airports, {size//1024} KB")
    log(f"  towered={towered} fuel={fuel} beacon={beacon} military={mil} heliport={hel} seaplane={spb}")

if __name__ == "__main__":
    main()
