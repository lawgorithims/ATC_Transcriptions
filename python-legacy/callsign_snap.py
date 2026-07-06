"""CallsignSnap: deterministic post-ASR callsign correction against a live
candidate list (ADS-B in-range traffic + filed flight plan).

WHY: error_analysis.py showed callsign failure is a DIGIT problem — both
Whisper and the CTC models nearly always get the airline telephony word right
and garble the flight number. Snapping the extracted callsign to the nearest
candidate (when unambiguous) cut false callsigns 14%->2% (whisper-small-us)
and 43%->2% (zipformer) in simulation. This module is the production
reference for that stage; port to Swift alongside ATCNormalize/ATCCorrector.

Two output channels, used differently downstream:
  * TEXT: the transcript with the callsign span rewritten IF a confident
    unique snap exists. Unverified callsigns stay as heard (we never delete
    what the pilot may want to see) — display-layer channel.
  * ENTITY verdict: verified_exact / snapped / unverified / no_callsign.
    Only verified/snapped callsigns may be attributed to an aircraft
    (CallsignExtractor -> ADS-B match). "unverified" = abstain — this is
    where the falseCS -> ~2% win comes from.

Candidates are canonical spoken-telephony strings ("delta 232",
"november 345 alpha bravo"). Build them from ADS-B flights via the airline
telephony map; never feed raw ICAO codes or registrations (the correction
validator's deny-list lesson, build 21).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

from atc_diarize import extract_callsign, _normalize_for_match
from atc_normalize import normalize as _canon


def _lev(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _split_cs(cs: str) -> Tuple[str, str]:
    """Canonical callsign -> (telephony word, number/letter remainder, no spaces)."""
    parts = cs.split()
    return parts[0], "".join(parts[1:])


def match_callsign(
    cs: str,
    candidates: Sequence[str],
    max_airline_ed: int = 2,
    max_num_ed: int = 1,
) -> Optional[str]:
    """Nearest unambiguous candidate for a canonical callsign, else None.

    Distance = 2*edit(telephony word) + edit(number block); a candidate
    qualifies only within (max_airline_ed, max_num_ed). Ties between two
    real aircraft mean genuine ambiguity -> abstain. Inputs may be in any
    digit format; everything is compared in atc_normalize's canonical
    per-digit space ("delta 2 3 2"), and the canonical match is returned.

    Known limitation: a misheard TELEPHONY word ("dominair" for an airline
    not in the map) never reaches this function — the extractor only anchors
    on known telephony words, so those errors surface as missed, not false.
    Gold taxonomy says that's rare (0-1 of 51); the digit-garble case this
    fixes is 7-21 of 51.
    """
    ha, hn = _split_cs(_canon(cs))
    scored = []
    for c in candidates:
        c = _canon(c)  # tolerate un-canonicalized inputs ("delta 232")
        ca, cn = _split_cs(c)
        da, dn = _lev(ha, ca), _lev(hn, cn)
        if da <= max_airline_ed and dn <= max_num_ed:
            scored.append((2 * da + dn, c))
    if not scored:
        return None
    scored.sort()
    if len(scored) > 1 and scored[0][0] == scored[1][0]:
        return None
    return scored[0][1]


@dataclass
class SnapEdit:
    """Outcome of one snap attempt. `verdict` drives the entity channel."""

    verdict: str                 # verified_exact | snapped | unverified | no_callsign
    original: Optional[str] = None   # canonical callsign as heard
    snapped: Optional[str] = None    # canonical callsign after snap (attribution-safe)
    applied: bool = False            # True iff the TEXT was rewritten


def snap_transcript(
    text: str,
    candidates: Sequence[str],
    max_airline_ed: int = 2,
    max_num_ed: int = 1,
) -> Tuple[str, SnapEdit]:
    """Return (possibly rewritten text, SnapEdit).

    The returned text is in normalized-token form (lowercase, no punctuation)
    — the same space the corrector pipeline already works in.
    """
    norm = _normalize_for_match(text)
    span = extract_callsign(norm)
    if not span:
        return text, SnapEdit(verdict="no_callsign")

    heard = _canon(span)
    match = match_callsign(heard, candidates, max_airline_ed, max_num_ed)
    if match is None:
        return text, SnapEdit(verdict="unverified", original=heard)
    if match == heard:
        return text, SnapEdit(
            verdict="verified_exact", original=heard, snapped=match)

    tokens = norm.split()
    stoks = span.split()
    for i in range(len(tokens) - len(stoks) + 1):
        if tokens[i: i + len(stoks)] == stoks:
            new_tokens = tokens[:i] + match.split() + tokens[i + len(stoks):]
            return " ".join(new_tokens), SnapEdit(
                verdict="snapped", original=heard, snapped=match, applied=True)
    # span found by the extractor but not relocatable verbatim — do no harm
    return text, SnapEdit(verdict="unverified", original=heard)
