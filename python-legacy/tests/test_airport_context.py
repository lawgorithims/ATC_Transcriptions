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
from airport_context.procedures import (  # noqa: E402
    extract_runway,
    is_continuation,
    normalize_type,
    spoken_name,
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


def seed_procedures(conn, airport_id=1):
    """Add a few procedures to an existing fixture DB (KMSP = airport_id 1)."""
    procs = [
        ("IAP", "ILS OR LOC RWY 30L", "ILS or localizer runway three zero left", "30L", "IAP"),
        ("IAP", "ILS RWY 30L (CAT II)", "ILS runway three zero left", "30L", "IAP"),
        # Distinct chart, identical spoken form -> must de-dupe to one slot.
        ("IAP", "ILS RWY 30L (CAT II - III)", "ILS runway three zero left", "30L", "IAP"),
        ("IAP", "RNAV (GPS) RWY 22", "RNAV GPS runway two two", "22", "IAP"),
        ("STAR", "GOPHER ONE", "Gopher One arrival", None, "STR"),
        ("DP", "MINNEAPOLIS NINE", "Minneapolis Nine departure", None, "DP"),
    ]
    conn.executemany(
        "INSERT INTO procedures(airport_id, procedure_type, procedure_name, spoken_name, "
        "runway_ident, chart_code, source_cycle) VALUES(?,?,?,?,?,?,?)",
        [(airport_id, pt, nm, sp, rwy, cc, "test") for pt, nm, sp, rwy, cc in procs],
    )
    conn.commit()


class ProcedureSpokenTests(unittest.TestCase):
    def test_normalize_type(self):
        self.assertEqual(normalize_type("IAP", "ILS OR LOC RWY 30L"), "IAP")
        self.assertEqual(normalize_type("STR", "GOPHER ONE"), "STAR")
        self.assertEqual(normalize_type("DP", "MINNEAPOLIS NINE"), "DP")
        self.assertEqual(normalize_type("ODP", "JOGMO ONE (OBSTACLE)"), "DP")
        self.assertEqual(normalize_type("IAP", "HIGHWAY VISUAL RWY 25R"), "CVFP")
        self.assertEqual(normalize_type("MIN", "TAKEOFF MINIMUMS"), "TAKEOFF_MINIMA")

    def test_continuation_detection(self):
        self.assertTrue(is_continuation("COULT SEVEN, CONT.1"))
        self.assertFalse(is_continuation("COULT SEVEN"))

    def test_extract_runway(self):
        self.assertEqual(extract_runway("ILS OR LOC RWY 30L"), "30L")
        self.assertEqual(extract_runway("RNAV (GPS) RWY 04"), "04")
        self.assertIsNone(extract_runway("GOPHER ONE"))

    def test_approach_spoken(self):
        self.assertEqual(spoken_name("IAP", "ILS OR LOC RWY 30L"), "ILS or localizer runway three zero left")
        self.assertEqual(spoken_name("IAP", "RNAV (GPS) RWY 22"), "RNAV GPS runway two two")
        self.assertEqual(spoken_name("IAP", "LOC RWY 04"), "localizer runway zero four")
        self.assertEqual(spoken_name("IAP", "RNAV (GPS)-A"), "RNAV GPS Alpha")
        self.assertEqual(spoken_name("IAP", "LOC BC RWY 31"), "localizer back course runway three one")

    def test_sid_star_spoken(self):
        self.assertEqual(spoken_name("DP", "MINNEAPOLIS NINE"), "Minneapolis Nine departure")
        self.assertEqual(spoken_name("DP", "JOGMO ONE (OBSTACLE) (RNAV)", "DP"), "Jogmo One departure")
        self.assertEqual(spoken_name("STR", "GOPHER ONE"), "Gopher One arrival")
        self.assertEqual(spoken_name("STR", "BAINY FOUR (RNAV)"), "Bainy Four arrival")

    def test_no_leftover_tokens(self):
        for code, name in [("IAP", "ILS OR LOC RWY 30L"), ("DP", "COULT SEVEN"), ("STR", "GOPHER ONE")]:
            out = spoken_name(code, name)
            self.assertNotIn("RWY", out)
            self.assertNotIn("(", out)
            self.assertTrue(out.strip())

    def test_multi_runway(self):
        self.assertEqual(extract_runway("RNAV (GPS) RWY 28L/R"), "28L/R")
        self.assertEqual(extract_runway("ILS OR LOC RWY 16 R/C/L"), "16R/C/L")
        self.assertEqual(spoken_name("IAP", "RNAV (GPS) RWY 28L/R"), "RNAV GPS runway two eight left right")
        self.assertEqual(runway_spoken("28L/R"), "runway two eight left right")
        self.assertEqual(runway_spoken("16 R/C/L"), "runway one six right center left")

    def test_designator_letters_phonetic(self):
        self.assertIn("Victor", spoken_name("IAP", "ILS V RWY 35"))
        self.assertIn("Yankee", spoken_name("IAP", "RNAV (GPS) Y RWY 12L"))

    def test_converging_and_hyphen_number(self):
        self.assertEqual(spoken_name("IAP", "CONVERGING ILS RWY 17C"), "converging ILS runway one seven center")
        self.assertEqual(spoken_name("IAP", "VOR-1 RWY 14L"), "VOR one runway one four left")

    def test_dp_embedded_runway_and_bare_digit(self):
        self.assertEqual(spoken_name("DP", "TIN CITY FIVE RWY 17"), "Tin City Five departure runway one seven")
        self.assertEqual(spoken_name("DP", "DEVLN 1"), "Devln One departure")

    def test_hyphenated_name_titlecase(self):
        self.assertEqual(spoken_name("DP", "WILKES-BARRE FIVE"), "Wilkes-Barre Five departure")

    def test_case_insensitive_input(self):
        self.assertEqual(spoken_name("IAP", "ils or loc rwy 30l"), "ILS or localizer runway three zero left")

    def test_three_digit_value_not_split(self):
        # A 3-digit value must not be matched as a 2-digit runway dropping a digit.
        self.assertEqual(spoken_name("IAP", "ILS OR LOC RWY 240"), "ILS or localizer runway two four zero")


class ProcedureBuildTests(unittest.TestCase):
    def setUp(self):
        self.conn = make_db()
        seed_procedures(self.conn)
        self.service = AirportContextService(conn=self.conn)

    def tearDown(self):
        self.conn.close()

    def test_approach_includes_procedures(self):
        result = self.service.build({"airport_code": "KMSP", "frequency_type": "approach"})
        self.assertNotIn("procedures_unavailable", result.get("warnings", []))
        prompt = result["prompt"]
        self.assertIn("Gopher One arrival", prompt)
        self.assertIn("ILS or localizer runway three zero left", prompt)
        self.assertTrue(result["context_snapshot"]["procedures"])

    def test_equivalent_approaches_dedupe(self):
        # 'ILS OR LOC RWY 30L' and 'ILS RWY 30L (CAT II)' have distinct spoken forms;
        # but exact-duplicate spoken forms must not repeat in the prompt.
        result = self.service.build({"airport_code": "KMSP", "frequency_type": "tower"})
        prompt = result["prompt"]
        self.assertEqual(prompt.count("ILS or localizer runway three zero left"), 1)

    def test_ground_excludes_procedures(self):
        result = self.service.build({"airport_code": "KMSP", "frequency_type": "ground"})
        self.assertEqual(result["context_snapshot"]["procedures"], [])

    def test_clearance_uses_departures(self):
        result = self.service.build({"airport_code": "KMSP", "frequency_type": "clearance"})
        self.assertIn("Minneapolis Nine departure", result["prompt"])

    def test_snapshot_no_duplicate_spoken(self):
        # Two distinct charts collapse to 'ILS runway three zero left' — must appear once.
        result = self.service.build({"airport_code": "KMSP", "frequency_type": "tower"})
        spokens = [p["spoken"] for p in result["context_snapshot"]["procedures"]]
        self.assertEqual(len(spokens), len(set(spokens)))

    def test_build_degrades_on_db_error(self):
        # A transient DB read error must degrade gracefully, not raise.
        import airport_context.builder as B

        original = B.db.count_procedures

        def boom(_conn):
            raise sqlite3.OperationalError("database is locked")

        B.db.count_procedures = boom
        try:
            result = self.service.build({"airport_code": "KMSP", "frequency_type": "approach"})
        finally:
            B.db.count_procedures = original
        self.assertNotIn("error", result)
        self.assertIn("procedures_unavailable", result.get("warnings", []))


class IngestGuardTests(unittest.TestCase):
    def test_empty_airports_refuses_to_wipe_procedures(self):
        from airport_context import ingest_dtpp

        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        db.init_db(conn)  # no airports inserted
        conn.execute(
            "INSERT INTO procedures(airport_id, procedure_type, procedure_name, spoken_name, "
            "source_cycle) VALUES(1,'IAP','X','x','t')"
        )
        conn.commit()
        with self.assertRaises(RuntimeError):
            ingest_dtpp.load(conn, "does-not-exist.xml", "2606")
        # Existing procedures must survive the refused ingest.
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM procedures").fetchone()[0], 1)
        conn.close()

    def test_cycle_math(self):
        from airport_context import ingest_dtpp

        self.assertEqual(ingest_dtpp.compute_cycle(__import__("datetime").date(2026, 6, 14)), "2606")
        self.assertEqual(ingest_dtpp.cycle_add("2613", 1), "2701")
        self.assertEqual(ingest_dtpp.cycle_add("2701", -1), "2613")


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
