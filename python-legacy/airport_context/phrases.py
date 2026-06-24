"""
Frequency-specific phrase dictionaries and spelling hints (spec sections 8.4, 13).

These are hand-curated and versioned here (not derived from FAA data). They are
deliberately short; the ranker prefers local terms (callsigns, runways, facility
names) over these generic phrases when the prompt budget is tight.
"""

from __future__ import annotations

from typing import List

CLEARANCE_PHRASES = [
    "cleared to", "via", "as filed", "then as filed", "maintain", "expect",
    "departure frequency", "squawk", "hold for release", "released for departure",
    "read back correct", "clearance on request",
]

GROUND_PHRASES = [
    "taxi via", "hold short", "cross runway", "give way", "follow", "monitor tower",
    "contact tower", "pushback approved", "progressive taxi", "without delay",
    "ramp", "gate",
]

TOWER_PHRASES = [
    "cleared to land", "cleared for takeoff", "line up and wait", "continue",
    "go around", "extend downwind", "make left traffic", "make right traffic",
    "report midfield", "traffic in sight", "wind check", "cleared the option",
]

# Approach and departure share a phrase set.
APPROACH_PHRASES = [
    "radar contact", "climb and maintain", "descend and maintain", "turn left heading",
    "turn right heading", "fly heading", "proceed direct", "resume own navigation",
    "cleared visual approach", "cleared ILS approach", "cleared RNAV approach",
    "maintain until established", "contact tower", "contact departure",
]

CENTER_PHRASES = [
    "radar contact", "climb and maintain", "descend and maintain", "maintain flight level",
    "cleared direct", "proceed direct", "resume own navigation", "contact center",
    "expect higher", "say altitude", "ident",
]

CTAF_PHRASES = [
    "traffic", "left downwind", "right downwind", "base", "final", "short final",
    "clear of runway", "departing runway", "taking the runway", "crosswind",
    "straight in", "any traffic please advise",
]

# Generic airport phrases used when the frequency type is unknown.
UNKNOWN_PHRASES = [
    "cleared to land", "cleared for takeoff", "line up and wait", "taxi via",
    "hold short", "cross runway", "climb and maintain", "descend and maintain",
    "fly heading", "proceed direct", "cleared approach", "contact tower",
    "contact departure",
]

_PHRASES_BY_TYPE = {
    "clearance": CLEARANCE_PHRASES,
    "ground": GROUND_PHRASES,
    "tower": TOWER_PHRASES,
    "approach": APPROACH_PHRASES,
    "departure": APPROACH_PHRASES,
    "center": CENTER_PHRASES,
    "ctaf": CTAF_PHRASES,
    "unknown": UNKNOWN_PHRASES,
}

# Aviation spelling hints. A base set plus per-type additions (spec section 10).
_BASE_SPELLING = ["niner", "fife", "tree", "squawk", "altimeter"]
_NAV_SPELLING = ["localizer", "glideslope", "RNAV", "VOR", "DME"]
_PHON_SPELLING = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"]

_SPELLING_BY_TYPE = {
    "clearance": _PHON_SPELLING + ["niner", "fife", "squawk", "altimeter"],
    "ground": _PHON_SPELLING + ["niner", "fife", "squawk", "altimeter"],
    "tower": _BASE_SPELLING + _NAV_SPELLING,
    "approach": _BASE_SPELLING + _NAV_SPELLING,
    "departure": _BASE_SPELLING + _NAV_SPELLING,
    "center": _BASE_SPELLING + _NAV_SPELLING,
    "ctaf": _PHON_SPELLING + _BASE_SPELLING,
    "unknown": _PHON_SPELLING[:3] + _BASE_SPELLING + ["localizer", "RNAV", "VOR", "DME"],
}


def phrases_for(frequency_type: str) -> List[str]:
    """Phrase templates for a frequency type (falls back to the unknown set)."""
    return list(_PHRASES_BY_TYPE.get(frequency_type, UNKNOWN_PHRASES))


def spelling_hints_for(frequency_type: str) -> List[str]:
    """Spelling hints for a frequency type (falls back to the unknown set)."""
    return list(_SPELLING_BY_TYPE.get(frequency_type, _SPELLING_BY_TYPE["unknown"]))
