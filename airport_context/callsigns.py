"""
Candidate-callsign parsing and spoken-variant generation (spec sections 5.5, 12).

Two shapes are handled for the MVP:
* Airline callsigns: 3-letter ICAO code + 1-4 digit flight number (e.g. DAL1234,
  SKW5670, NKS123). Telephony name comes from airlines.json; the flight number
  gets both a grouped natural form ("twelve thirty four") and a digit-by-digit
  form ("one two three four").
* Tail numbers: N + alphanumerics (e.g. N345AB). Spoken full ("November three
  four five alpha bravo") plus shorter abbreviated variants pilots/ATC use.

Multiple variants are stored on the snapshot; the renderer injects only the best
one or two per callsign.
"""

from __future__ import annotations

import re
from typing import List

from .airlines import telephony_for
from .models import Callsign
from .spoken import grouped_number, speak_alnum, speak_digits

_AIRLINE_RE = re.compile(r"^([A-Z]{3})(\d{1,4})([A-Z]?)$")
_TAIL_RE = re.compile(r"^N[0-9A-Z]{1,5}$")


def _normalize(raw: str) -> str:
    return re.sub(r"[\s\-]", "", str(raw or "")).upper()


def _airline_variants(prefix: str, number: str, suffix: str) -> List[str]:
    telephony = telephony_for(prefix) or speak_alnum(prefix)
    digits = speak_digits(number)
    grouped = grouped_number(number)
    tail = (" " + speak_alnum(suffix)) if suffix else ""

    variants: List[str] = []
    if grouped:
        variants.append(f"{telephony} {grouped}{tail}".strip())
    variants.append(f"{telephony} {digits}{tail}".strip())
    return _dedupe(variants)


def _tail_variants(canonical: str) -> List[str]:
    rest = canonical[1:]  # drop leading N
    full = f"November {speak_alnum(rest)}".strip()
    variants = [full, speak_alnum(rest)]
    if len(rest) >= 3:
        variants.append(speak_alnum(rest[-3:]))
    return _dedupe(variants)


def _dedupe(items: List[str]) -> List[str]:
    seen = set()
    out = []
    for it in items:
        it = it.strip()
        key = it.lower()
        if it and key not in seen:
            seen.add(key)
            out.append(it)
    return out


def parse_callsign(raw: str) -> Callsign:
    """Parse one raw callsign into a Callsign with spoken variants."""
    canonical = _normalize(raw)
    if not canonical:
        return Callsign(canonical=str(raw or "").strip(), spoken=[], kind="unknown")

    m = _AIRLINE_RE.match(canonical)
    if m:
        prefix, number, suffix = m.group(1), m.group(2), m.group(3)
        return Callsign(
            canonical=canonical,
            spoken=_airline_variants(prefix, number, suffix),
            kind="airline",
        )

    if _TAIL_RE.match(canonical):
        return Callsign(canonical=canonical, spoken=_tail_variants(canonical), kind="tail")

    # Unknown shape: fall back to speaking it out alphanumerically.
    return Callsign(canonical=canonical, spoken=[speak_alnum(canonical)], kind="unknown")


def format_callsigns(raws) -> List[Callsign]:
    """Parse and de-duplicate a list of candidate callsigns, preserving order."""
    if not raws:
        return []
    out: List[Callsign] = []
    seen = set()
    for raw in raws:
        cs = parse_callsign(raw)
        if cs.canonical and cs.canonical not in seen:
            seen.add(cs.canonical)
            out.append(cs)
    return out
