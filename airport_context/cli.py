"""
Command-line interface for the airport-mode context pipeline.

    python -m airport_context.cli ingest [--country US|ALL|US,CA] [--force]
    python -m airport_context.cli build --airport KMSP --frequency-type tower \
        --callsigns DAL1234,SKW5670,N345AB --prior "..." [--json]
    python -m airport_context.cli resolve --airport MSP
"""

from __future__ import annotations

import argparse
import json
import sys

from . import db
from .builder import AirportContextService
from .resolver import AirportNotFound, AirportResolver, AmbiguousAirport, normalize_code


def _utf8_stdout() -> None:
    # Windows consoles default to cp1252; spoken names/dashes need UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass


def _cmd_ingest(args) -> int:
    from . import ingest

    country_arg = (args.country or "US").strip().upper()
    countries = None if country_arg == "ALL" else [c for c in country_arg.split(",") if c]
    counts = ingest.run_ingest(
        db_path=args.db, cache_dir=args.cache, countries=countries, force=args.force
    )
    total = sum(counts.values())
    print(f"Ingested {total:,} rows: {counts}")
    return 0


def _cmd_resolve(args) -> int:
    conn = db.connect(args.db, readonly=True)
    try:
        resolver = AirportResolver(conn)
        try:
            ap = resolver.resolve(args.airport)
        except AmbiguousAirport as e:
            print(f"ambiguous: {normalize_code(args.airport)}")
            for c in e.candidates:
                print(f"  {c.display_code:<6} {c.name} ({c.city or ''}, {c.region or ''})")
            return 2
        except AirportNotFound:
            print(f"not found: {args.airport}")
            return 1
        print(json.dumps(ap.identity_dict(), ensure_ascii=False, indent=2))
        return 0
    finally:
        conn.close()


def _cmd_build(args) -> int:
    request = {
        "airport_code": args.airport,
        "frequency_type": args.frequency_type,
    }
    if args.callsigns:
        request["candidate_callsigns"] = [c.strip() for c in args.callsigns.split(",") if c.strip()]
    if args.prior:
        request["prior_transcript"] = args.prior
    if args.max_words:
        request["max_prompt_words"] = args.max_words

    service = AirportContextService(db_path=args.db)
    try:
        result = service.build(request)
    finally:
        service.close()

    if "error" in result:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    print(result["prompt"])
    print()
    print(f"[{result['prompt_word_count']} words]", end="")
    if result.get("warnings"):
        print("  warnings: " + ", ".join(result["warnings"]), end="")
    print()
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m airport_context.cli",
        description="Airport-mode ATC context-injection pipeline.",
    )
    p.add_argument("--db", help="SQLite database path (default: data/airport_context/airport_context.db)")
    sub = p.add_subparsers(dest="command", required=True)

    pi = sub.add_parser("ingest", help="Download OurAirports data and build the database")
    pi.add_argument("--country", default="US", help="ISO country code(s), comma-separated, or ALL (default: US)")
    pi.add_argument("--cache", help="CSV cache directory")
    pi.add_argument("--force", action="store_true", help="Re-download even if cached")
    pi.set_defaults(func=_cmd_ingest)

    pr = sub.add_parser("resolve", help="Resolve an airport code to its canonical identity")
    pr.add_argument("--airport", required=True, help="ICAO / FAA-LID / IATA code")
    pr.set_defaults(func=_cmd_resolve)

    pb = sub.add_parser("build", help="Build a context snapshot + prompt")
    pb.add_argument("--airport", required=True, help="ICAO / FAA-LID / IATA code")
    pb.add_argument(
        "--frequency-type", default="unknown",
        help="clearance|ground|tower|approach|departure|center|ctaf|unknown",
    )
    pb.add_argument("--callsigns", help="Comma-separated candidate callsigns (e.g. DAL1234,N345AB)")
    pb.add_argument("--prior", help="Prior transcript text")
    pb.add_argument("--max-words", type=int, help="Max prompt words (default 600)")
    pb.add_argument("--json", action="store_true", help="Print the full result JSON")
    pb.set_defaults(func=_cmd_build)

    return p


def main(argv=None) -> int:
    _utf8_stdout()
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
