"""
Airport spoken-name generation (spec section 8, step 1).

Produces the spoken airport/facility names used in the prompt — preferring the
city ("Minneapolis") and facility variants ("Minneapolis Tower") over the formal
name. Manual overrides (data/airport_overrides.json) win, because common ATC
spoken names frequently differ from the formal airport name.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import List

from .models import Airport

_OVERRIDES_FILE = Path(__file__).resolve().parent / "data" / "airport_overrides.json"

# Spoken role word appended to a facility's base name.
ROLE_WORDS = {
    "clearance": "Clearance",
    "ground": "Ground",
    "tower": "Tower",
    "approach": "Approach",
    "departure": "Departure",
    "center": "Center",
    "atis": "ATIS",
}

# For a towered field, the facility roles we treat as "likely" controllers.
_TOWERED_ROLE_ORDER = ("tower", "ground", "clearance", "departure", "approach")


@lru_cache(maxsize=1)
def _overrides() -> dict:
    try:
        data = json.loads(_OVERRIDES_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in data.items() if not str(k).startswith("_")}


def _clean(s: str) -> str:
    if not s:
        return ""
    s = s.replace("–", "-").replace("—", "-").replace("’", "'")
    return re.sub(r"\s+", " ", s).strip()


def _strip_airport_words(name: str) -> str:
    """Trim formal qualifiers so 'Foo Regional Airport' -> 'Foo'."""
    n = name.split("/")[0]
    n = re.sub(
        r"\b(International|Intl|Regional|Municipal|Memorial|County|Field|Airport|Airpark|Air\s*Park)\b",
        "",
        n,
        flags=re.I,
    )
    return _clean(n)


def override_for(airport: Airport) -> dict:
    ov = _overrides()
    for key in (airport.icao, airport.faa_lid, airport.iata, airport.ident):
        if key and key in ov:
            return ov[key]
    return {}


def spoken_base(airport: Airport) -> str:
    """The primary spoken token for the field (e.g. 'Minneapolis')."""
    ov = override_for(airport)
    if ov.get("spoken_base"):
        return ov["spoken_base"]
    if airport.city:
        return _clean(airport.city)
    short = _strip_airport_words(airport.name)
    return short or _clean(airport.name) or airport.display_code


def facility_spoken_name(base: str, role: str) -> str:
    word = ROLE_WORDS.get(role)
    return f"{base} {word}" if word else base


def _dedupe(items: List[str]) -> List[str]:
    seen = set()
    out = []
    for it in items:
        it = (it or "").strip()
        key = it.lower()
        if it and key not in seen:
            seen.add(key)
            out.append(it)
    return out


def airport_spoken_names(airport: Airport, towered: bool) -> List[str]:
    """Spoken airport + facility names (overrides win, else generated)."""
    ov = override_for(airport)
    if ov.get("spoken_names"):
        return _dedupe(ov["spoken_names"])

    base = spoken_base(airport)
    names = [base]
    if towered:
        names.extend(facility_spoken_name(base, role) for role in _TOWERED_ROLE_ORDER)
    city = _clean(airport.city or "")
    if city and city.lower() != base.lower():
        names.append(city)
    return _dedupe(names)


def facility_names_for(airport: Airport, frequency_type: str, roles_present, towered: bool) -> List[str]:
    """Likely facility names to surface for the current frequency type (spec section 13).

    Ordered by relevance to ``frequency_type``. For an untowered field we only
    surface the base name (there is no controller to name).
    """
    base = spoken_base(airport)
    if not towered:
        return _dedupe([base])

    # Preference order of controller roles per frequency type.
    preference = {
        "clearance": ["clearance", "ground", "departure", "tower"],
        "ground": ["ground", "tower", "clearance"],
        "tower": ["tower", "ground", "departure", "approach"],
        "approach": ["approach", "departure", "tower", "center"],
        "departure": ["departure", "approach", "tower", "center"],
        "center": ["center", "approach"],
        "ctaf": ["tower"],
        "unknown": ["tower", "ground", "approach", "departure", "clearance"],
    }.get(frequency_type, ["tower", "ground", "approach", "departure"])

    roles_present = set(roles_present or ())
    names = []
    for role in preference:
        # Surface a role if the airport has the frequency, or it is a core
        # controller role that a towered field will always have.
        if role in roles_present or role in ("tower", "ground"):
            names.append(facility_spoken_name(base, role))
    return _dedupe(names)
