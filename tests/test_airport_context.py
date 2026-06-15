"""
Unit tests for the airport_context pipeline.

Stdlib unittest only (no pytest, no network). The database layer is exercised
against a small in-memory SQLite fixture so the tests do not depend on having
run the OurAirports ingestion.

Run directly:   python tests/test_airport_context.py
Or via pytest:  pytest tests/test_airport_context.py
"""

import sqlite3
import sys
import unittest
from pathlib import Path

# Allow running as a plain script from anywhere.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from airport_context import db, phrases  # noqa: E402
from airport_context.builder import AirportContextService  # noqa: E402
from airport_context.callsigns import parse_callsign  # noqa: E402
from airport_context.resolver import (  # noqa: E402
    AirportNotFound,
    AirportResolver,
    AmbiguousAirport,
)
from airport_context.spoken import frequency_spoken, runway_spoken  # noqa: E402

_NOW = "2026-01-01T00:00:00"

_AIRPORTS = [
    # id, icao, faa_lid, iata, ident, name, city, region, country, lat, lon, elev, type
    (1, "KMSP", "MSP", "MSP", "KMSP", "Minneapolis-Saint Paul International Airport",
     "Minneapolis", "US-MN", "US", 44.880081, -93.221741, 841.0, "large_airport"),
    (2, None, None, None, "SPA1", "Springfield Alpha Airport",
     "Springfield", "US-IL", "US", 39.80, -89.60, 600.0, "small_airport"),
    (3, None, None, None, "SPB2", "Springfield Beta Airport",
     "Springfield", "US-MO", "US", 37.20, -93.40, 1300.0, "small_airport"),
]

_RUNWAYS = ["04", "22", "12R", "30L", "12L", "30R", "17", "35"]

_FREQS = [
    ("tower", "123.675", "TWR"),
    ("ground", "121.8", "GND"),
    ("clearance", "133.2", "CLNC DEL"),
    ("approach", "118.72", "APP"),
    ("departure", "132.975", "DEP"),
    ("ATIS", "120.8", "ATIS"),
]

_NAVAIDS = [
    # id, ident, name, type, lat, lon
    (1, "GEP", "Gopher", "VORTAC", 44.95, -92.95),
    (2, "MSP", "Minneapolis", "VOR-DME", 44.880, -93.221),
    (3, "AP", "Vagey", "NDB", 44.90, -93.30),
]


def make_db() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    db.init_db(conn)
    conn.executemany(
        "INSERT INTO airports(id, icao, faa_lid, iata, ident, name, city, region, country, "
        "lat, lon, elevation_ft, type, keywords, source, source_cycle, updated_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [a + (None, "ourairports", "test-cycle", _NOW) for a in _AIRPORTS],
    )
    conn.executemany(
        "INSERT INTO runways(airport_id, ident, spoken_ident, length_ft, width_ft, surface, "
        "closed, source_cycle) VALUES(?,?,?,?,?,?,?,?)",
        [(1, r, runway_spoken(r), 10000, 150, "ASP", 0, "test-cycle") for r in _RUNWAYS],
    )
    conn.executemany(
        "INSERT INTO frequencies(airport_id, frequency_mhz, facility_type, facility_name, "
        "spoken_facility_name, description, source_cycle) VALUES(?,?,?,?,?,?,?)",
        [(1, mhz, ftype, desc, None, desc, "test-cycle") for ftype, mhz, desc in _FREQS],
    )
    conn.executemany(
        "INSERT INTO navaids(id, ident, name, type, lat, lon, spoken_name, country, source, "
        "source_cycle) VALUES(?,?,?,?,?,?,?,?,?,?)",
        [(i, ident, name, typ, lat, lon, name, "US", "ourairports", "test-cycle")
         for i, ident, name, typ, lat, lon in _NAVAIDS],
    )
    conn.commit()
    return conn


class SpokenFormTests(unittest.TestCase):
    def test_runway_spoken(self):
        self.assertEqual(runway_spoken("30L"), "runway three zero left")
        self.assertEqual(runway_spoken("30R"), "runway three zero right")
        self.assertEqual(runway_spoken("36C"), "runway three six center")
        self.assertEqual(runway_spoken("04"), "runway zero four")
        self.assertEqual(runway_spoken("4"), "runway four")
        self.assertEqual(runway_spoken("18"), "runway one eight")

    def test_frequency_spoken(self):
        self.assertEqual(frequency_spoken("118.7"), "one one eight point seven")
        self.assertEqual(frequency_spoken("120.95"), "one two zero point niner five")

    def test_callsign_airline(self):
        cs = parse_callsign("DAL1234")
        self.assertEqual(cs.kind, "airline")
        self.assertIn("Delta twelve thirty four", cs.spoken)
        self.assertIn("Delta one two three four", cs.spoken)

    def test_callsign_skywest_grouping(self):
        cs = parse_callsign("SKW5670")
        self.assertIn("SkyWest fifty six seventy", cs.spoken)

    def test_callsign_tail(self):
        cs = parse_callsign("N345AB")
        self.assertEqual(cs.kind, "tail")
        self.assertIn("November three four five alpha bravo", cs.spoken)
        self.assertIn("five alpha bravo", cs.spoken)

    def test_callsign_round_thousand(self):
        self.assertIn("Southwest two thousand", parse_callsign("SWA2000").spoken)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.conn = make_db()
        self.resolver = AirportResolver(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_resolve_icao(self):
        self.assertEqual(self.resolver.resolve("KMSP").icao, "KMSP")

    def test_resolve_iata_lid_and_loose_input(self):
        self.assertEqual(self.resolver.resolve("MSP").icao, "KMSP")
        self.assertEqual(self.resolver.resolve("kmsp").icao, "KMSP")
        self.assertEqual(self.resolver.resolve("  k m s p ").icao, "KMSP")

    def test_not_found(self):
        with self.assertRaises(AirportNotFound):
            self.resolver.resolve("ZZZZ")

    def test_ambiguous(self):
        with self.assertRaises(AmbiguousAirport) as ctx:
            self.resolver.resolve("SPRINGFIELD")
        self.assertGreaterEqual(len(ctx.exception.candidates), 2)


class PhraseTests(unittest.TestCase):
    def test_every_frequency_type_has_phrases_and_spelling(self):
        from airport_context.models import FREQUENCY_TYPES

        for ft in FREQUENCY_TYPES:
            self.assertTrue(phrases.phrases_for(ft), f"no phrases for {ft}")
            self.assertTrue(phrases.spelling_hints_for(ft), f"no spelling for {ft}")


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.conn = make_db()
        self.service = AirportContextService(conn=self.conn)

    def tearDown(self):
        self.conn.close()

    def test_tower_build_end_to_end(self):
        result = self.service.build({
            "airport_code": "KMSP",
            "frequency_type": "tower",
            "prior_transcript": "Delta twelve thirty four, continue runway three zero left.",
            "candidate_callsigns": ["DAL1234", "SKW5670", "N345AB"],
        })
        self.assertNotIn("error", result)
        self.assertEqual(result["airport"], "KMSP")
        self.assertEqual(result["frequency_type"], "tower")

        prompt = result["prompt"]
        for token in [
            "KMSP", "Minneapolis", "Frequency type: tower",
            "runway three zero left", "Delta twelve thirty four",
            "Minneapolis Tower", "cleared to land", "GEP", "Gopher",
        ]:
            self.assertIn(token, prompt, f"missing {token!r} in prompt")

        self.assertGreater(result["prompt_word_count"], 0)
        self.assertLessEqual(result["prompt_word_count"], 900)

        snap = result["context_snapshot"]
        for key in [
            "airport", "frequency_type", "runways", "facility_names", "procedures",
            "fixes", "weather_terms", "candidate_callsigns", "phrase_templates",
            "spelling_hints", "prior_transcript",
        ]:
            self.assertIn(key, snap)

        self.assertEqual(snap["candidate_callsigns"][0]["canonical"], "DAL1234")
        self.assertIn("procedures_unavailable", result.get("warnings", []))

        # snapshot row logged
        n = self.conn.execute("SELECT COUNT(*) FROM context_snapshots").fetchone()[0]
        self.assertEqual(n, 1)

    def test_missing_airport_code(self):
        result = self.service.build({"frequency_type": "tower"})
        self.assertEqual(result["error"], "invalid_request")

    def test_ambiguous_airport_returns_error(self):
        result = self.service.build({"airport_code": "SPRINGFIELD"})
        self.assertEqual(result["error"], "ambiguous_airport")
        self.assertGreaterEqual(len(result["candidates"]), 2)

    def test_unknown_frequency_defaults(self):
        result = self.service.build({"airport_code": "MSP"})
        self.assertEqual(result["frequency_type"], "unknown")
        self.assertIn("Frequency type: unknown", result["prompt"])


class LiveAdapterTests(unittest.TestCase):
    """The ATCContext-compatible adapter used by the live pipeline."""

    def setUp(self):
        self.conn = make_db()
        self.service = AirportContextService(conn=self.conn, log_snapshots=False)

    def tearDown(self):
        self.conn.close()

    def test_build_prompt_and_history(self):
        from airport_context.live import AirportModeContext

        ctx = AirportModeContext("KMSP", "tower", candidate_callsigns=["DAL1234"], service=self.service)
        p1 = ctx.build_prompt()
        self.assertIn("KMSP", p1)
        self.assertIn("Delta twelve thirty four", p1)
        self.assertNotIn("Recent transcript", p1)  # no history yet

        ctx.update("SkyWest fifty six seventy, line up and wait runway three zero right.")
        p2 = ctx.build_prompt()
        self.assertIn("Recent transcript", p2)
        self.assertNotEqual(p1, p2)
        self.assertEqual(ctx.build_prompt(), p2)  # cached when history unchanged

    def test_banner_lines(self):
        from airport_context.live import AirportModeContext

        ctx = AirportModeContext("KMSP", "tower", service=self.service)
        self.assertTrue(any("KMSP" in line for line in ctx.banner_lines()))

    def test_invalid_airport_raises(self):
        from airport_context.live import AirportContextError, AirportModeContext

        with self.assertRaises(AirportContextError) as ctx:
            AirportModeContext("ZZZZ", service=self.service)
        self.assertEqual(ctx.exception.result["error"], "airport_not_found")


if __name__ == "__main__":
    unittest.main(verbosity=2)
