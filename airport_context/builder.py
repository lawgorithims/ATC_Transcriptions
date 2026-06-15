"""
Runtime context builder / service (spec sections 1, 5, 9).

Orchestrates the runtime pipeline: validate -> resolve airport -> fetch static
context -> process callsigns -> rank/cap/dedupe -> render prompt -> log snapshot,
returning the MVP request/response contract. The structured ``context_snapshot``
is the primary product; ``prompt`` is its final rendering.

Weather and procedures are later phases; their absence is reported via
``warnings`` rather than failing the request.
"""

from __future__ import annotations

import datetime as _dt
import json
import re
import sqlite3
from typing import List, Optional

from . import db, names, phrases, ranker, renderer
from .callsigns import format_callsigns
from .models import (
    DEFAULT_CAPS,
    RADIUS_NM_BY_FREQUENCY,
    normalize_frequency_type,
)
from .resolver import AirportNotFound, AirportResolver, AmbiguousAirport


def _split_prior(text: str, max_lines: int = 3, max_words: int = 150) -> List[str]:
    """Keep the last few transmissions of the prior transcript, word-capped."""
    text = (text or "").strip()
    if not text:
        return []
    parts = [p.strip() for p in re.split(r"(?<=[.?!])\s+", text) if p.strip()]
    if not parts:
        parts = [text]
    parts = parts[-max_lines:]
    out: List[str] = []
    total = 0
    for p in reversed(parts):
        n = len(p.split())
        if out and total + n > max_words:
            break
        out.insert(0, p)
        total += n
    return out


class AirportContextService:
    """Build airport-mode context snapshots + prompts from request dicts."""

    def __init__(
        self,
        db_path=None,
        conn: Optional[sqlite3.Connection] = None,
        *,
        log_snapshots: bool = True,
        check_same_thread: bool = True,
    ):
        self._own_conn = conn is None
        self.conn = (
            conn if conn is not None
            else db.connect(db_path, check_same_thread=check_same_thread)
        )
        self.log_snapshots = log_snapshots
        db.init_db(self.conn)  # ensure tables exist even before ingestion
        self.resolver = AirportResolver(self.conn)

    def close(self) -> None:
        if self._own_conn:
            self.conn.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ------------------------------------------------------------------ #
    def build(self, request: dict) -> dict:
        if not isinstance(request, dict):
            return {"error": "invalid_request", "message": "request must be a JSON object"}

        code = request.get("airport_code")
        if not code or not str(code).strip():
            return {"error": "invalid_request", "message": "airport_code is required"}

        if db.count_airports(self.conn) == 0:
            return {
                "error": "database_empty",
                "message": "Airport database is empty. Run: python -m airport_context.cli ingest",
            }

        frequency_type = normalize_frequency_type(request.get("frequency_type"))
        max_words = _coerce_int(request.get("max_prompt_words"), default=600)
        max_words = max(150, min(max_words, 900))
        warnings: List[str] = []

        # --- resolve ---
        try:
            airport = self.resolver.resolve(code)
        except AmbiguousAirport as e:
            return {
                "error": "ambiguous_airport",
                "message": "Multiple airports match the input code.",
                "candidates": [c.candidate_dict() for c in e.candidates],
            }
        except AirportNotFound:
            return {
                "error": "airport_not_found",
                "message": "No airport found for input code.",
                "airport_code": code,
            }

        aid = airport.db_id

        # --- static context ---
        runways = db.get_runways(self.conn, aid)
        open_runways = [r for r in runways if not r.closed]
        runways = open_runways or runways

        frequencies = db.get_frequencies(self.conn, aid)
        roles_present = {f.facility_type for f in frequencies}
        towered = "tower" in roles_present
        airport.spoken_names = names.airport_spoken_names(airport, towered)
        base = names.spoken_base(airport)

        facility_names = names.facility_names_for(airport, frequency_type, roles_present, towered)

        radius = RADIUS_NM_BY_FREQUENCY.get(frequency_type, 50)
        navaids = []
        if airport.lat is not None and airport.lon is not None:
            navaids = db.get_navaids_near(
                self.conn, airport.lat, airport.lon, radius, limit=DEFAULT_CAPS["fixes"] * 2
            )
            # Prefer high-value navaid types (VOR/VORTAC) over short NDBs, then distance —
            # these are the fixes ATC actually references ("direct Gopher").
            navaids.sort(key=lambda n: (ranker.NAVAID_TYPE_RANK.get(n.type, 9), n.distance_nm or 9e9))

        # --- dynamic / not-yet-ingested context ---
        if request.get("include_weather"):
            warnings.append("weather_unavailable")  # AWC weather is a later phase
        warnings.append("procedures_unavailable")  # d-TPP procedures are a later phase

        # --- callsigns + prior transcript ---
        callsigns = format_callsigns(request.get("candidate_callsigns"))
        prior_text = str(request.get("prior_transcript") or "").strip()
        prior_lines = _split_prior(prior_text)

        # --- rank / cap / dedupe into prompt terms ---
        runway_terms = ranker.cap(ranker.dedupe([r.spoken for r in runways]), DEFAULT_CAPS["runways"])
        facility_terms = ranker.cap(ranker.dedupe(facility_names), DEFAULT_CAPS["facility_names"])

        phrase_terms = ranker.cap(
            ranker.dedupe(phrases.phrases_for(frequency_type)), DEFAULT_CAPS["phrase_templates"]
        )
        # Drop phrases already in the prior transcript (but never empty the section).
        phrase_terms = ranker.remove_present_in(phrase_terms, prior_text) or phrase_terms

        spelling_terms = ranker.cap(
            ranker.dedupe(phrases.spelling_hints_for(frequency_type)), DEFAULT_CAPS["spelling_hints"]
        )

        # Fix terms: navaid idents, plus single-word spoken names for VOR-class
        # navaids (e.g. "Gopher"), since ATC speaks those by name.
        _named_types = ("VORTAC", "VOR-DME", "VOR", "TACAN")
        _city = (airport.city or "").lower()
        fix_terms: List[str] = []
        for n in navaids:
            fix_terms.append(n.ident)
            nm = (n.name or "").strip()
            if n.type in _named_types and nm and len(nm.split()) == 1 and nm.lower() not in (base.lower(), _city):
                fix_terms.append(nm)
        fix_terms = ranker.cap(ranker.dedupe(fix_terms), DEFAULT_CAPS["fixes"])

        callsign_terms: List[str] = []
        for cs in ranker.cap(callsigns, DEFAULT_CAPS["candidate_callsigns"]):
            callsign_terms.extend(cs.spoken[:2])  # best one or two variants each
        callsign_terms = ranker.dedupe(callsign_terms)

        selection = {
            "opening": renderer.opening_line(airport.display_code, base, frequency_type),
            "prior_transcript": prior_lines,
            "candidate_callsigns": callsign_terms,
            "facility_names": facility_terms,
            "runways": runway_terms,
            "phrase_templates": phrase_terms,
            "procedures": [],
            "fixes": fix_terms,
            "weather_terms": [],
            "spelling_hints": spelling_terms,
        }

        prompt, word_count, dropped = renderer.render(selection, frequency_type, max_words=max_words)
        if dropped:
            warnings.append("prompt_trimmed:" + ",".join(dropped))

        snapshot = {
            "airport": airport.identity_dict(),
            "frequency_type": frequency_type,
            "runways": [r.snapshot_dict() for r in runways[: DEFAULT_CAPS["runways"]]],
            "facility_names": facility_terms,
            "procedures": [],
            "fixes": [n.snapshot_dict() for n in navaids[: DEFAULT_CAPS["fixes"]]],
            "weather_terms": [],
            "candidate_callsigns": [cs.snapshot_dict() for cs in callsigns],
            "phrase_templates": phrase_terms,
            "spelling_hints": spelling_terms,
            "prior_transcript": prior_lines,
        }

        self._log_snapshot(aid, frequency_type, request, snapshot, prompt, word_count, airport.source_cycle)

        result = {
            "airport": airport.display_code,
            "frequency_type": frequency_type,
            "prompt": prompt,
            "prompt_word_count": word_count,
            "context_snapshot": snapshot,
        }
        if warnings:
            result["warnings"] = warnings
        return result

    # ------------------------------------------------------------------ #
    def _log_snapshot(self, aid, ft, request, snapshot, prompt, word_count, source_cycle) -> None:
        if not self.log_snapshots:
            return
        try:
            self.conn.execute(
                "INSERT INTO context_snapshots(airport_id, created_at, frequency_type, "
                "input_json, context_json, prompt_text, source_cycles, prompt_word_count) "
                "VALUES(?,?,?,?,?,?,?,?)",
                (
                    aid,
                    _dt.datetime.now().isoformat(timespec="seconds"),
                    ft,
                    json.dumps(request, ensure_ascii=False),
                    json.dumps(snapshot, ensure_ascii=False),
                    prompt,
                    source_cycle,
                    word_count,
                ),
            )
            self.conn.commit()
        except sqlite3.Error:
            pass  # snapshot logging must never break a transcription request


def _coerce_int(value, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default
