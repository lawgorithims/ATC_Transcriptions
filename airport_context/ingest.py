"""
Offline ingestion of OurAirports CSV data into the local SQLite database.

OurAirports (https://ourairports.com/data/, CC0/public-domain) publishes clean,
documented CSVs that cover the spec's foundation tables — airports, runways,
frequencies, and navaids — globally. We ingest U.S. data by default ("U.S.-first
MVP") with a flag to add more countries. Provenance is stamped in each row's
``source_cycle`` so a later reconciliation against FAA NASR is mechanical.

Spoken forms (runway idents, navaid names) are generated once here, at ingestion
time, per the spec.

Network: stdlib ``urllib`` only — no third-party dependencies.
"""

from __future__ import annotations

import csv
import datetime as _dt
import sqlite3
import sys
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from . import db
from .spoken import runway_spoken

OURAIRPORTS_BASE = "https://davidmegginson.github.io/ourairports-data"
FILES = {
    "airports": "airports.csv",
    "runways": "runways.csv",
    "frequencies": "airport-frequencies.csv",
    "navaids": "navaids.csv",
}

DEFAULT_CACHE_DIR = db.DEFAULT_DB_PATH.parent / "ourairports"

# OurAirports frequency ``type`` token -> normalized facility type (spec section 7).
_FREQ_TYPE_MAP = {
    "TWR": "tower", "GND": "ground", "ATIS": "ATIS", "AWOS": "ATIS", "ASOS": "ATIS",
    "AWIB": "ATIS", "CLD": "clearance", "CD": "clearance", "DEL": "clearance",
    "CLNC": "clearance", "APP": "approach", "A/D": "approach", "ARR": "approach",
    "DEP": "departure", "CTAF": "ctaf", "UNIC": "unicom", "UNICOM": "unicom",
    "MULTICOM": "unicom", "CNTR": "center", "CTR": "center", "CENTER": "center",
    "FSS": "fss", "RMP": "ramp", "RAMP": "ramp", "APRON": "ramp", "OPS": "other",
    "MISC": "other", "RDO": "other", "EMERG": "other",
}

# Keyword fallback when the type token is unrecognized.
_DESC_KEYWORDS = [
    ("CLEARANCE", "clearance"), ("DELIVERY", "clearance"), ("GROUND", "ground"),
    ("TOWER", "tower"), ("DEPARTURE", "departure"), ("APPROACH", "approach"),
    ("CENTER", "center"), ("CENTRE", "center"), ("ATIS", "ATIS"), ("CTAF", "ctaf"),
    ("UNICOM", "unicom"), ("RAMP", "ramp"), ("APRON", "ramp"),
]


def normalize_facility_type(type_token: str, description: str) -> str:
    token = (type_token or "").strip().upper()
    if token in _FREQ_TYPE_MAP:
        return _FREQ_TYPE_MAP[token]
    desc = (description or "").upper()
    for needle, norm in _DESC_KEYWORDS:
        if needle in desc:
            return norm
    return "other"


def _to_int(value) -> Optional[int]:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def _to_float(value) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


# --------------------------------------------------------------------------- #
# Download
# --------------------------------------------------------------------------- #
def download(cache_dir=None, force: bool = False, log=print) -> Dict[str, Path]:
    """Download the OurAirports CSVs into ``cache_dir`` (skips existing unless force)."""
    cache_dir = Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
    cache_dir.mkdir(parents=True, exist_ok=True)
    paths: Dict[str, Path] = {}
    for key, fname in FILES.items():
        dest = cache_dir / fname
        paths[key] = dest
        if dest.exists() and not force:
            log(f"  [cache] {fname} ({dest.stat().st_size // 1024} KB)")
            continue
        url = f"{OURAIRPORTS_BASE}/{fname}"
        log(f"  [get]   {url}")
        req = urllib.request.Request(url, headers={"User-Agent": "atc-airport-context/0.1"})
        with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as fh:
            fh.write(resp.read())
        log(f"          -> {dest} ({dest.stat().st_size // 1024} KB)")
    return paths


def _open_csv(path: Path) -> Iterable[dict]:
    with open(path, "r", encoding="utf-8", newline="") as fh:
        yield from csv.DictReader(fh)


# --------------------------------------------------------------------------- #
# Load
# --------------------------------------------------------------------------- #
def _countries_match(country: str, countries: Optional[set]) -> bool:
    return countries is None or country in countries


def load(
    conn: sqlite3.Connection,
    cache_dir=None,
    countries: Optional[Iterable[str]] = ("US",),
    source_cycle: Optional[str] = None,
    log=print,
) -> Dict[str, int]:
    """Load cached CSVs into the database. Replaces existing OurAirports rows.

    ``countries=None`` loads every country; otherwise pass ISO country codes.
    """
    cache_dir = Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
    country_set = None if countries is None else {c.strip().upper() for c in countries}
    source_cycle = source_cycle or f"ourairports-{_dt.date.today().isoformat()}"
    now = _dt.datetime.now().isoformat(timespec="seconds")

    db.init_db(conn)
    log("  clearing existing rows ...")
    for table in ("airports", "runways", "frequencies", "navaids"):
        conn.execute(f"DELETE FROM {table}")

    counts = {"airports": 0, "runways": 0, "frequencies": 0, "navaids": 0}
    airport_ids: set = set()

    # --- airports ---
    airport_rows = []
    for r in _open_csv(cache_dir / FILES["airports"]):
        if (r.get("type") or "") == "closed":
            continue
        if not _countries_match((r.get("iso_country") or "").upper(), country_set):
            continue
        aid = _to_int(r.get("id"))
        if aid is None:
            continue
        airport_ids.add(aid)
        airport_rows.append(
            (
                aid,
                (r.get("icao_code") or "").strip().upper() or None,
                (r.get("local_code") or "").strip().upper() or None,
                (r.get("iata_code") or "").strip().upper() or None,
                (r.get("ident") or "").strip().upper() or None,
                r.get("name") or "",
                r.get("municipality") or None,
                r.get("iso_region") or None,
                (r.get("iso_country") or "").upper() or None,
                _to_float(r.get("latitude_deg")),
                _to_float(r.get("longitude_deg")),
                _to_float(r.get("elevation_ft")),
                r.get("type") or None,
                r.get("keywords") or None,
                "ourairports",
                source_cycle,
                now,
            )
        )
    conn.executemany(
        "INSERT INTO airports(id, icao, faa_lid, iata, ident, name, city, region, "
        "country, lat, lon, elevation_ft, type, keywords, source, source_cycle, updated_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        airport_rows,
    )
    counts["airports"] = len(airport_rows)
    log(f"  airports:    {counts['airports']:>7,}")

    # --- runways (one CSV row has up to two ends) ---
    runway_rows = []
    for r in _open_csv(cache_dir / FILES["runways"]):
        aid = _to_int(r.get("airport_ref"))
        if aid not in airport_ids:
            continue
        length = _to_int(r.get("length_ft"))
        width = _to_int(r.get("width_ft"))
        surface = r.get("surface") or None
        closed = 1 if (r.get("closed") or "") == "1" else 0
        for end in ("le_ident", "he_ident"):
            ident = (r.get(end) or "").strip().upper()
            if not ident:
                continue
            runway_rows.append(
                (aid, ident, runway_spoken(ident), length, width, surface, closed, source_cycle)
            )
    conn.executemany(
        "INSERT INTO runways(airport_id, ident, spoken_ident, length_ft, width_ft, "
        "surface, closed, source_cycle) VALUES(?,?,?,?,?,?,?,?)",
        runway_rows,
    )
    counts["runways"] = len(runway_rows)
    log(f"  runways:     {counts['runways']:>7,}")

    # --- frequencies ---
    freq_rows = []
    for r in _open_csv(cache_dir / FILES["frequencies"]):
        aid = _to_int(r.get("airport_ref"))
        if aid not in airport_ids:
            continue
        desc = r.get("description") or None
        freq_rows.append(
            (
                aid,
                r.get("frequency_mhz") or "",
                normalize_facility_type(r.get("type"), desc),
                desc,
                None,  # spoken_facility_name computed at runtime from airport name
                desc,
                source_cycle,
            )
        )
    conn.executemany(
        "INSERT INTO frequencies(airport_id, frequency_mhz, facility_type, facility_name, "
        "spoken_facility_name, description, source_cycle) VALUES(?,?,?,?,?,?,?)",
        freq_rows,
    )
    counts["frequencies"] = len(freq_rows)
    log(f"  frequencies: {counts['frequencies']:>7,}")

    # --- navaids ---
    navaid_rows = []
    for r in _open_csv(cache_dir / FILES["navaids"]):
        if not _countries_match((r.get("iso_country") or "").upper(), country_set):
            continue
        nid = _to_int(r.get("id"))
        if nid is None:
            continue
        name = r.get("name") or ""
        navaid_rows.append(
            (
                nid,
                (r.get("ident") or "").strip().upper(),
                name,
                r.get("type") or "",
                _to_float(r.get("latitude_deg")),
                _to_float(r.get("longitude_deg")),
                name or (r.get("ident") or ""),
                (r.get("iso_country") or "").upper() or None,
                "ourairports",
                source_cycle,
            )
        )
    conn.executemany(
        "INSERT INTO navaids(id, ident, name, type, lat, lon, spoken_name, country, "
        "source, source_cycle) VALUES(?,?,?,?,?,?,?,?,?,?)",
        navaid_rows,
    )
    counts["navaids"] = len(navaid_rows)
    log(f"  navaids:     {counts['navaids']:>7,}")

    db.meta_set(conn, "source", "ourairports")
    db.meta_set(conn, "source_cycle", source_cycle)
    db.meta_set(conn, "ingested_at", now)
    db.meta_set(conn, "countries", "ALL" if country_set is None else ",".join(sorted(country_set)))
    for k, v in counts.items():
        db.meta_set(conn, f"count_{k}", str(v))
    conn.commit()
    return counts


def run_ingest(
    db_path=None,
    cache_dir=None,
    countries: Optional[Iterable[str]] = ("US",),
    force: bool = False,
    log=print,
) -> Dict[str, int]:
    """End-to-end: download (if needed) then load into the database."""
    log("Downloading OurAirports data ...")
    download(cache_dir=cache_dir, force=force, log=log)
    log("Loading into database ...")
    conn = db.connect(db_path)
    try:
        counts = load(conn, cache_dir=cache_dir, countries=countries, log=log)
    finally:
        conn.close()
    target = Path(db_path) if db_path else db.DEFAULT_DB_PATH
    log(f"Done. Database: {target}")
    return counts


if __name__ == "__main__":  # convenience: python -m airport_context.ingest
    sys.exit(0 if run_ingest() else 1)
