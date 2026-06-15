"""
Terminal-procedure normalization and spoken-name generation (spec section 8.2).

Parses FAA d-TPP ``chart_name`` strings into a normalized procedure type, a
runway ident, and a spoken form suitable for prompt biasing. Pure functions (no
I/O) so they can be unit-tested and audited against the real d-TPP corpus.

Examples (verified against d-TPP cycle 2606):
    IAP  "ILS OR LOC RWY 30L"   -> "ILS or localizer runway three zero left"
    IAP  "RNAV (GPS) RWY 22"    -> "RNAV GPS runway two two"
    IAP  "RNAV (GPS) Y RWY 12L" -> "RNAV GPS Yankee runway one two left"
    IAP  "RNAV (GPS)-A"         -> "RNAV GPS Alpha"
    IAP  "RNAV (GPS) RWY 28L/R" -> "RNAV GPS runway two eight left right"
    DP   "MINNEAPOLIS NINE"     -> "Minneapolis Nine departure"
    DP   "TIN CITY FIVE RWY 17" -> "Tin City Five departure runway one seven"
    STR  "GOPHER ONE"           -> "Gopher One arrival"
    CVFP "HIGHWAY VISUAL RWY 25R" -> "Highway Visual runway two five right"

Inputs are uppercased on entry (FAA chart names are canonically uppercase) so
the path is robust to mixed-case callers.
"""

from __future__ import annotations

import re
from typing import Optional

from .spoken import PHONETIC, runway_spoken, speak_digits

# Procedure types injected into the prompt (spoken on frequency).
PROMPT_TYPES = ("IAP", "DP", "STAR", "CVFP")

_CONT_RE = re.compile(r",\s*CONT\.?\s*\d*$", re.I)
_PAREN_RE = re.compile(r"\([^)]*\)")
# Runway ident, including multi-side forms ('28L/R', '16 R/C/L'). The (?!\d)
# guard keeps a 3-digit value (e.g. a bearing '240') from matching as '24'.
_RWY_RE = re.compile(r"\bRWY\s+(\d{1,2}(?!\d)(?:\s*[LRC])?(?:\s*/\s*[LRC])*)")
_TRAIL_LETTER_RE = re.compile(r"[-\s]([A-Z])\s*$")
_TRAIL_BEARING_RE = re.compile(r"(\d{3,})\s*$")
_HYPHEN_NUM_RE = re.compile(r"([A-Z]+)-(\d+)")

# Approach-type tokens expanded for speech; anything else passes through as-is.
_TOKEN_SPOKEN = {
    "LOC": "localizer",
    "BC": "back course",
    "OR": "or",
    "CONVERGING": "converging",
    "RWY": "runway",
    "RUNWAY": "runway",
}
# Tokens kept verbatim (acronyms ATC says letter-by-letter or as-is).
_KEEP_TOKENS = {
    "ILS", "VOR", "DME", "NDB", "TACAN", "RNAV", "GPS", "RNP", "GLS", "LDA",
    "GBAS", "PRM", "SDF", "MLS",
}


def is_continuation(chart_name: str) -> bool:
    """True for continuation pages (', CONT.1') that duplicate a base procedure."""
    return bool(_CONT_RE.search(chart_name or ""))


def normalize_type(chart_code: str, chart_name: str) -> str:
    """Map a d-TPP chart_code (+name) to a normalized procedure type."""
    cc = (chart_code or "").strip().upper()
    cn = (chart_name or "").upper()
    if cc == "IAP":
        return "CVFP" if "VISUAL" in cn else "IAP"
    if cc in ("DP", "ODP"):
        return "DP"
    if cc == "STR":
        return "STAR"
    if cc == "APD":
        return "APD"
    if cc == "MIN":
        if "TAKEOFF" in cn:
            return "TAKEOFF_MINIMA"
        if "ALTERNATE" in cn:
            return "ALTERNATE_MINIMA"
        return "OTHER"
    return "OTHER"


def extract_runway(chart_name: str) -> Optional[str]:
    """Return the runway ident embedded in a chart name (whitespace-normalized), or None."""
    m = _RWY_RE.search((chart_name or "").upper())
    return re.sub(r"\s+", "", m.group(1)) if m else None


def _normalize_parens(s: str) -> str:
    """Keep the meaningful (GPS)/(RNP) qualifiers as words; drop the rest."""
    s = s.replace("(GPS)", "GPS").replace("(RNP)", "RNP")
    return _PAREN_RE.sub("", s)


def _titlecase(s: str) -> str:
    def cap(word: str) -> str:
        return word[:1].upper() + word[1:].lower() if word[:1].isalpha() else word

    # Capitalize each hyphen-delimited component too ('WILKES-BARRE' -> 'Wilkes-Barre').
    return " ".join("-".join(cap(p) for p in w.split("-")) for w in s.split())


def _spell_digits(text: str) -> str:
    """Speak any digit runs aviation-style ('80' -> 'eight zero')."""
    return re.sub(r"\d+", lambda m: speak_digits(m.group()), text)


def _expand_prefix(prefix: str) -> str:
    """Expand an approach-type prefix (e.g. 'ILS OR LOC/DME') to spoken words."""
    prefix = prefix.replace("/", " ")
    out = []
    for tok in prefix.split():
        t = tok.upper()
        m_num = _HYPHEN_NUM_RE.fullmatch(t)
        if m_num and m_num.group(1) in _KEEP_TOKENS:  # e.g. 'VOR-1' -> 'VOR one'
            out.append(m_num.group(1))
            out.append(speak_digits(m_num.group(2)))
        elif t in _TOKEN_SPOKEN:
            out.append(_TOKEN_SPOKEN[t])
        elif t in _KEEP_TOKENS:
            out.append(t)
        elif re.fullmatch(r"[A-Z]", t):  # approach designator letter -> phonetic
            out.append(PHONETIC.get(t, t).capitalize())
        else:
            out.append(tok)
    return " ".join(out).strip()


def _approach_spoken(chart_name: str) -> str:
    cn = _normalize_parens(_CONT_RE.sub("", chart_name.strip().upper()).strip())
    copter = cn.startswith("COPTER")
    cn = re.sub(r"^COPTER\s+", "", cn)
    cn = re.sub(r"^HI-\s*", "", cn)

    m = _RWY_RE.search(cn)
    if m:
        spoken = f"{_expand_prefix(cn[: m.start()])} {runway_spoken(m.group(1))}".strip()
    else:
        mletter = _TRAIL_LETTER_RE.search(cn)
        mbear = _TRAIL_BEARING_RE.search(cn)
        if mletter:
            letter = PHONETIC.get(mletter.group(1), mletter.group(1).lower()).capitalize()
            spoken = f"{_expand_prefix(cn[: mletter.start()])} {letter}".strip()
        elif mbear:
            spoken = f"{_expand_prefix(cn[: mbear.start()])} {speak_digits(mbear.group(1))}".strip()
        else:
            spoken = _expand_prefix(cn).strip() or cn.lower()
    return f"copter {spoken}" if copter else spoken


def spoken_name(chart_code: str, chart_name: str, procedure_type: Optional[str] = None) -> str:
    """Generate the spoken form of a procedure from its d-TPP chart name."""
    ptype = procedure_type or normalize_type(chart_code, chart_name)
    name = (chart_name or "").strip().upper()

    if ptype in ("DP", "STAR"):
        base = _PAREN_RE.sub("", _CONT_RE.sub("", name))
        suffix = " departure" if ptype == "DP" else " arrival"
        m = _RWY_RE.search(base)
        if m:
            lead = _titlecase(_spell_digits(_RWY_RE.sub("", base).strip()))
            return f"{lead}{suffix} {runway_spoken(m.group(1))}".strip()
        return _titlecase(_spell_digits(base.strip())) + suffix
    if ptype == "CVFP":
        m = _RWY_RE.search(name)
        if m:
            lead = _titlecase(_spell_digits(_normalize_parens(name[: m.start()]).strip()))
            return f"{lead} {runway_spoken(m.group(1))}".strip()
        return _titlecase(_spell_digits(_normalize_parens(name).strip()))
    if ptype == "IAP":
        return _approach_spoken(name)
    if ptype == "APD":
        return "airport diagram"
    return _titlecase(_PAREN_RE.sub("", name).strip())
