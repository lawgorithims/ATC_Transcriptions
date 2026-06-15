"""
Context ranking, capping, and de-duplication (spec sections 6.6, 6.7, 11).

Phase 1 keeps the ranker pragmatic: per-category caps, case-insensitive
de-duplication, distance-ordered fixes, and the section drop-order used by the
renderer to honor the prompt word budget. The base term scores from the spec are
recorded here for documentation and future cross-category ranking.
"""

from __future__ import annotations

from typing import List

from .models import DEFAULT_CAPS  # noqa: F401  (re-exported for callers)

# Base term scores (spec section 6, step 6).
SCORES = {
    "candidate_callsign": 100,
    "runway": 90,
    "facility_name": 80,
    "phrase": 70,
    "procedure": 60,
    "fix": 50,
    "weather": 40,
    "prior": 30,
    "spelling": 20,
}

# Whole-section drop order when over the hard word budget (spec section 11).
# Protected sections (opening, runways, supplied callsigns, last prior line) are
# never listed here.
DROP_ORDER = [
    "spelling_hints",
    "weather_terms",
    "fixes",
    "procedures",
    "facility_names",
    "phrase_templates",
]

# Prefer higher-value navaid types when distances are comparable.
NAVAID_TYPE_RANK = {
    "VORTAC": 0, "VOR-DME": 1, "VOR": 2, "TACAN": 3, "NDB-DME": 4, "DME": 5, "NDB": 6,
}


def word_count(text: str) -> int:
    return len(text.split())


def dedupe(items: List[str]) -> List[str]:
    """Case-insensitive de-dup, preserving first-seen order."""
    seen = set()
    out = []
    for it in items:
        it = (it or "").strip()
        key = it.lower()
        if it and key not in seen:
            seen.add(key)
            out.append(it)
    return out


def cap(items: List, n: int) -> List:
    return list(items)[: max(0, n)]


def remove_present_in(items: List[str], haystack: str) -> List[str]:
    """Drop terms already present in ``haystack`` (e.g. the prior transcript)."""
    hay = (haystack or "").lower()
    return [it for it in items if it.lower() not in hay]
