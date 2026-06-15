"""
SQLite schema and query helpers for the airport context database.

SQLite is used for the prototype (zero-setup, file-based); the schema mirrors the
tables in the spec (section 7) so a later move to Postgres/PostGIS is mechanical.
Geospatial "nearby fixes" queries use a bounding-box prefilter plus a Python
haversine, which is adequate for the airport-radius use case.
"""

from __future__ import annotations

import math
import sqlite3
from pathlib import Path
from typing import List, Optional

from .models import Airport, Frequency, Navaid, Procedure, Runway

# data/ is git-ignored, so the database and CSV cache live there (regenerable).
_REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB_PATH = _REPO_ROOT / "data" / "airport_context" / "airport_context.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS airports (
    id           INTEGER PRIMARY KEY,
    icao         TEXT,
    faa_lid      TEXT,
    iata         TEXT,
    ident        TEXT,
    name         TEXT,
    city         TEXT,
    region       TEXT,
    country      TEXT,
    lat          REAL,
    lon          REAL,
    elevation_ft REAL,
    type         TEXT,
    keywords     TEXT,
    source       TEXT,
    source_cycle TEXT,
    updated_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_airports_icao   ON airports(icao);
CREATE INDEX IF NOT EXISTS idx_airports_iata   ON airports(iata);
CREATE INDEX IF NOT EXISTS idx_airports_lid    ON airports(faa_lid);
CREATE INDEX IF NOT EXISTS idx_airports_ident  ON airports(ident);

CREATE TABLE IF NOT EXISTS runways (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    airport_id   INTEGER,
    ident        TEXT,
    spoken_ident TEXT,
    length_ft    INTEGER,
    width_ft     INTEGER,
    surface      TEXT,
    closed       INTEGER,
    source_cycle TEXT
);
CREATE INDEX IF NOT EXISTS idx_runways_airport ON runways(airport_id);

CREATE TABLE IF NOT EXISTS frequencies (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    airport_id           INTEGER,
    frequency_mhz        TEXT,
    facility_type        TEXT,
    facility_name        TEXT,
    spoken_facility_name TEXT,
    description          TEXT,
    source_cycle         TEXT
);
CREATE INDEX IF NOT EXISTS idx_freq_airport ON frequencies(airport_id);

CREATE TABLE IF NOT EXISTS navaids (
    id           INTEGER PRIMARY KEY,
    ident        TEXT,
    name         TEXT,
    type         TEXT,
    lat          REAL,
    lon          REAL,
    spoken_name  TEXT,
    country      TEXT,
    source       TEXT,
    source_cycle TEXT
);
CREATE INDEX IF NOT EXISTS idx_navaids_latlon ON navaids(lat, lon);

-- Procedure metadata (FAA d-TPP) — table created now, populated in a later phase.
CREATE TABLE IF NOT EXISTS procedures (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    airport_id     INTEGER,
    procedure_type TEXT,
    procedure_name TEXT,
    spoken_name    TEXT,
    runway_ident   TEXT,
    chart_code     TEXT,
    pdf_filename   TEXT,
    effective_date TEXT,
    source_cycle   TEXT
);
CREATE INDEX IF NOT EXISTS idx_proc_airport ON procedures(airport_id);

-- Weather snapshots (AWC) — table created now, populated in a later phase.
CREATE TABLE IF NOT EXISTS weather_snapshots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    airport_id  INTEGER,
    station_id  TEXT,
    captured_at TEXT,
    raw_metar   TEXT,
    raw_taf     TEXT,
    parsed_json TEXT,
    spoken_terms TEXT
);

-- Exact context used for each transcription (spec section 7) — for debugging/eval.
CREATE TABLE IF NOT EXISTS context_snapshots (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    airport_id        INTEGER,
    created_at        TEXT,
    frequency_type    TEXT,
    input_json        TEXT,
    context_json      TEXT,
    prompt_text       TEXT,
    source_cycles     TEXT,
    prompt_word_count INTEGER
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def connect(
    path=None,
    *,
    readonly: bool = False,
    create_parents: bool = True,
    check_same_thread: bool = True,
) -> sqlite3.Connection:
    """Open a SQLite connection with a Row factory.

    Pass ``check_same_thread=False`` when the connection will be used from a
    different thread than the one that created it (e.g. the live pipeline's
    transcription worker). Callers must then serialize access themselves.
    """
    path = Path(path) if path else DEFAULT_DB_PATH
    if readonly:
        conn = sqlite3.connect(
            f"file:{path}?mode=ro", uri=True, check_same_thread=check_same_thread
        )
    else:
        if create_parents:
            path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path), check_same_thread=check_same_thread)
    conn.row_factory = sqlite3.Row
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    """Create all tables/indexes if they do not exist."""
    conn.executescript(SCHEMA)
    conn.commit()


# --------------------------------------------------------------------------- #
# Geometry helpers
# --------------------------------------------------------------------------- #
_NM_PER_DEG_LAT = 60.0


def haversine_nm(lat1, lon1, lat2, lon2) -> float:
    """Great-circle distance in nautical miles."""
    r_nm = 3440.065
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r_nm * math.asin(math.sqrt(a))


def initial_bearing_deg(lat1, lon1, lat2, lon2) -> float:
    """Initial great-circle bearing from point 1 to point 2, in degrees true."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


# --------------------------------------------------------------------------- #
# Row mapping + queries
# --------------------------------------------------------------------------- #
def row_to_airport(row: sqlite3.Row) -> Airport:
    return Airport(
        icao=row["icao"] or None,
        faa_lid=row["faa_lid"] or None,
        iata=row["iata"] or None,
        ident=row["ident"] or None,
        name=row["name"] or "",
        city=row["city"] or None,
        region=row["region"] or None,
        country=row["country"] or None,
        lat=row["lat"],
        lon=row["lon"],
        elevation_ft=row["elevation_ft"],
        type=row["type"] or None,
        source=row["source"] or "ourairports",
        source_cycle=row["source_cycle"] or None,
        db_id=row["id"],
    )


def get_runways(conn: sqlite3.Connection, airport_id: int) -> List[Runway]:
    rows = conn.execute(
        "SELECT ident, spoken_ident, length_ft, width_ft, surface, closed "
        "FROM runways WHERE airport_id=? ORDER BY length_ft DESC, ident",
        (airport_id,),
    ).fetchall()
    return [
        Runway(
            ident=r["ident"],
            spoken=r["spoken_ident"],
            length_ft=r["length_ft"],
            width_ft=r["width_ft"],
            surface=r["surface"],
            closed=bool(r["closed"]),
        )
        for r in rows
    ]


def get_frequencies(conn: sqlite3.Connection, airport_id: int) -> List[Frequency]:
    rows = conn.execute(
        "SELECT frequency_mhz, facility_type, facility_name, description "
        "FROM frequencies WHERE airport_id=? ORDER BY facility_type",
        (airport_id,),
    ).fetchall()
    return [
        Frequency(
            frequency_mhz=r["frequency_mhz"],
            facility_type=r["facility_type"],
            facility_name=r["facility_name"],
            description=r["description"],
        )
        for r in rows
    ]


def get_navaids_near(
    conn: sqlite3.Connection, lat: float, lon: float, radius_nm: float, limit: int = 60
) -> List[Navaid]:
    """Navaids within ``radius_nm`` of (lat, lon), nearest first.

    Uses a bounding-box SQL prefilter then exact haversine in Python.
    """
    if lat is None or lon is None:
        return []
    dlat = radius_nm / _NM_PER_DEG_LAT
    coslat = max(math.cos(math.radians(lat)), 1e-6)
    dlon = radius_nm / (_NM_PER_DEG_LAT * coslat)
    rows = conn.execute(
        "SELECT ident, name, type, lat, lon, spoken_name FROM navaids "
        "WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
        (lat - dlat, lat + dlat, lon - dlon, lon + dlon),
    ).fetchall()
    out: List[Navaid] = []
    for r in rows:
        if r["lat"] is None or r["lon"] is None:
            continue
        dist = haversine_nm(lat, lon, r["lat"], r["lon"])
        if dist <= radius_nm:
            out.append(
                Navaid(
                    ident=r["ident"],
                    name=r["name"] or "",
                    type=r["type"] or "",
                    spoken=r["spoken_name"] or r["ident"],
                    lat=r["lat"],
                    lon=r["lon"],
                    distance_nm=dist,
                    bearing_deg=initial_bearing_deg(lat, lon, r["lat"], r["lon"]),
                )
            )
    out.sort(key=lambda n: n.distance_nm)
    return out[:limit]


def get_procedures(conn: sqlite3.Connection, airport_id: int, types=None) -> List[Procedure]:
    sql = (
        "SELECT procedure_type, procedure_name, spoken_name, runway_ident, chart_code "
        "FROM procedures WHERE airport_id=?"
    )
    params: list = [airport_id]
    if types:
        sql += " AND procedure_type IN (%s)" % ",".join("?" * len(types))
        params.extend(types)
    sql += " ORDER BY procedure_type, procedure_name"
    rows = conn.execute(sql, params).fetchall()
    return [
        Procedure(
            procedure_type=r["procedure_type"],
            name=r["procedure_name"],
            spoken=r["spoken_name"],
            runway_ident=r["runway_ident"],
            chart_code=r["chart_code"],
        )
        for r in rows
    ]


def count_airports(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM airports").fetchone()[0]


def count_procedures(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM procedures").fetchone()[0]


def meta_get(conn: sqlite3.Connection, key: str) -> Optional[str]:
    row = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row[0] if row else None


def meta_set(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )
