"""
Offline ingestion of FAA d-TPP terminal-procedure metadata (spec section 8.2).

The FAA publishes a per-cycle d-TPP metafile (XML) listing every terminal chart
for every U.S. airport: approaches (IAP), departures (DP/ODP), arrivals (STR),
airport diagrams (APD), minima (MIN), etc. We ingest the procedure *names* and
metadata (not the plates), normalize the type, generate a spoken name, and link
each procedure to an airport in the local database.

d-TPP uses the 28-day AIRAC cycle; the cycle id is YYNN (e.g. 2606 = 2026 cycle
6). The current cycle is computed from a known anchor and confirmed by an HTTP
probe; ``--cycle`` overrides. Network: stdlib ``urllib`` only.
"""

from __future__ import annotations

import datetime as _dt
import sqlite3
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, Optional

from . import db, procedures
from .procedures import extract_runway, is_continuation, normalize_type, spoken_name

DTPP_BASE = "https://aeronav.faa.gov/d-tpp"
DEFAULT_CACHE_DIR = db.DEFAULT_DB_PATH.parent / "dtpp"

# Known cycle anchor: cycle 2606 is effective 2026-06-11 (28-day AIRAC cadence).
_ANCHOR_CYCLE = "2606"
_ANCHOR_DATE = _dt.date(2026, 6, 11)

# Normalized types worth storing (others — HOT/LAH/DVA/RADAR — are skipped).
_KEEP_TYPES = {"IAP", "DP", "STAR", "CVFP", "APD", "TAKEOFF_MINIMA", "ALTERNATE_MINIMA"}


def _split_cycle(cycle: str):
    return int(cycle[:2]), int(cycle[2:])


def _join_cycle(year2: int, n: int) -> str:
    return f"{year2 % 100:02d}{n:02d}"


def cycle_add(cycle: str, delta: int) -> str:
    """Step a YYNN cycle id by ``delta`` cycles (13 cycles per year)."""
    y, n = _split_cycle(cycle)
    n += delta
    while n > 13:
        n -= 13
        y += 1
    while n < 1:
        n += 13
        y -= 1
    return _join_cycle(y, n)


def compute_cycle(today: Optional[_dt.date] = None) -> str:
    """Compute the current d-TPP cycle id from the date anchor.

    Uses a fixed 13 cycles/year. This is exact for the foreseeable future and the
    HTTP probe in ``resolve_cycle`` self-corrects any boundary off-by-one; it would
    drift only at rare 14th-cycle years (first in 2043). Pass ``--cycle`` to pin.
    """
    today = today or _dt.date.today()
    steps = (today - _ANCHOR_DATE).days // 28
    return cycle_add(_ANCHOR_CYCLE, steps)


def metafile_url(cycle: str) -> str:
    return f"{DTPP_BASE}/{cycle}/xml_data/d-TPP_Metafile.xml"


def _head_ok(url: str, timeout: int = 30) -> bool:
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "atc-airport-context/0.2"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except (urllib.error.URLError, urllib.error.HTTPError, OSError):
        return False


def resolve_cycle(cycle: Optional[str] = None, today: Optional[_dt.date] = None, probe: bool = True, log=print) -> str:
    """Determine the d-TPP cycle to use: explicit override, else computed + probed."""
    if cycle:
        return str(cycle).strip()
    candidate = compute_cycle(today)
    if not probe:
        return candidate
    # Confirm the candidate exists; if not, walk to the nearest published cycle.
    for delta in (0, -1, 1, -2, 2):
        c = cycle_add(candidate, delta)
        if _head_ok(metafile_url(c)):
            if c != candidate:
                log(f"  computed cycle {candidate} unavailable; using {c}")
            return c
    log(f"  warning: could not confirm any cycle near {candidate}; using it anyway")
    return candidate


def download(cycle: str, cache_dir=None, force: bool = False, log=print) -> Path:
    """Download the d-TPP metafile for a cycle (skips an existing cache unless force)."""
    cache_dir = Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
    cache_dir.mkdir(parents=True, exist_ok=True)
    dest = cache_dir / f"d-TPP_Metafile_{cycle}.xml"
    if dest.exists() and not force:
        log(f"  [cache] {dest.name} ({dest.stat().st_size // 1024} KB)")
        return dest
    url = metafile_url(cycle)
    log(f"  [get]   {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "atc-airport-context/0.2"})
    # Download to a temp file and atomically promote only after a complete transfer,
    # so an interrupted download never leaves a truncated "poison" cache file.
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = resp.read()
        if b"<html" in data[:1024].lower():
            raise ValueError(f"d-TPP fetch for cycle {cycle} returned HTML, not XML")
        tmp.write_bytes(data)
        tmp.replace(dest)  # atomic on the same filesystem
    finally:
        if tmp.exists():
            tmp.unlink()
    log(f"          -> {dest} ({dest.stat().st_size // 1024} KB)")
    return dest


_INSERT = (
    "INSERT INTO procedures(airport_id, procedure_type, procedure_name, spoken_name, "
    "runway_ident, chart_code, pdf_filename, effective_date, source_cycle) "
    "VALUES(?,?,?,?,?,?,?,?,?)"
)


def load(conn: sqlite3.Connection, xml_path, cycle: str, log=print) -> Dict[str, int]:
    """Parse the d-TPP metafile and load procedures, linking each to an airport."""
    db.init_db(conn)
    now = _dt.datetime.now().isoformat(timespec="seconds")

    # Build airport-id lookups from the (already-ingested) airports table.
    rows = conn.execute("SELECT id, icao, faa_lid, ident FROM airports").fetchall()
    by_icao: Dict[str, int] = {}
    by_lid: Dict[str, int] = {}
    by_ident: Dict[str, int] = {}
    for r in rows:
        if r["icao"]:
            by_icao.setdefault(r["icao"], r["id"])
        if r["faa_lid"]:
            by_lid.setdefault(r["faa_lid"], r["id"])
        if r["ident"]:
            by_ident.setdefault(r["ident"], r["id"])
    if not rows:
        # Refuse to wipe a populated procedures table when nothing can be matched.
        raise RuntimeError(
            "airports table is empty — run the OurAirports ingest before ingesting "
            "d-TPP (refusing to wipe the procedures table)"
        )

    conn.execute("DELETE FROM procedures")

    batch = []
    count = 0
    airports_with_procs = set()
    unmatched = set()

    for _ev, el in ET.iterparse(str(xml_path), events=("end",)):
        if el.tag != "airport_name":
            continue
        icao = (el.get("icao_ident") or "").strip().upper()
        lid = (el.get("apt_ident") or "").strip().upper()
        aid = by_icao.get(icao) or by_lid.get(lid) or by_ident.get(icao)
        if aid is None:
            if icao or lid:
                unmatched.add(icao or lid)
            el.clear()
            continue
        for rec in el.findall("record"):
            cc = (rec.findtext("chart_code") or "").strip()
            cn = (rec.findtext("chart_name") or "").strip()
            # Skip continuation pages and AAUP "Attention All Users Page" charts
            # (informational, not procedures voiced on frequency).
            if not cn or is_continuation(cn) or cn.upper().endswith("AAUP"):
                continue
            ptype = normalize_type(cc, cn)
            if ptype not in _KEEP_TYPES:
                continue
            batch.append(
                (
                    aid,
                    ptype,
                    cn,
                    spoken_name(cc, cn, ptype),
                    extract_runway(cn),
                    cc,
                    (rec.findtext("pdf_name") or "").strip() or None,
                    (rec.findtext("amdtdate") or "").strip() or None,
                    cycle,
                )
            )
            count += 1
            airports_with_procs.add(aid)
        el.clear()
        if len(batch) >= 5000:
            conn.executemany(_INSERT, batch)
            batch = []
    if batch:
        conn.executemany(_INSERT, batch)

    db.meta_set(conn, "dtpp_cycle", cycle)
    db.meta_set(conn, "dtpp_ingested_at", now)
    db.meta_set(conn, "count_procedures", str(count))
    conn.commit()

    counts = {
        "procedures": count,
        "airports_with_procedures": len(airports_with_procs),
        "unmatched_airports": len(unmatched),
    }
    log(
        f"  procedures:  {count:>7,}  across {len(airports_with_procs):,} airports"
        f"  ({len(unmatched):,} d-TPP airports not in DB)"
    )
    return counts


def run_ingest(
    db_path=None,
    cache_dir=None,
    cycle: Optional[str] = None,
    force: bool = False,
    log=print,
) -> Dict[str, int]:
    """End-to-end: resolve cycle, download the metafile, load procedures."""
    log("Resolving d-TPP cycle ...")
    cycle = resolve_cycle(cycle, log=log)
    log(f"  cycle: {cycle}")
    log("Downloading d-TPP metafile ...")
    xml_path = download(cycle, cache_dir=cache_dir, force=force, log=log)
    log("Loading procedures into database ...")
    conn = db.connect(db_path)
    try:
        counts = load(conn, xml_path, cycle, log=log)
    finally:
        conn.close()
    target = Path(db_path) if db_path else db.DEFAULT_DB_PATH
    log(f"Done. Database: {target}")
    return counts


if __name__ == "__main__":  # python -m airport_context.ingest_dtpp
    run_ingest()
