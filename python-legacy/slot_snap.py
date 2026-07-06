"""SlotSnap: context-grounded correction of runway and frequency slots.

WHY: slot_metrics.py showed models emit wrong-but-LEGAL values (5/27 runway
mentions wrong on gold v0 — a 19% runway-false rate, worse than the callsign
problem CallsignSnap fixed) and NEVER physically-impossible ones, so a static
ontology veto catches nothing; the fix is grounding in what actually exists
HERE: the airport's real runways and published frequencies (airport_data.py
providers — curated configs, iOS map/flight plan, OurAirports internet
fallback; LiveATC/demo mode always uses the fallback).

Policies (deliberately conservative — this stage must never flip semantics):
  * runway: exact designator -> verified. Digit near-miss (edit<=1) to a
    UNIQUE candidate with the SAME suffix status -> snap. The L/C/R suffix is
    NEVER added, removed, or changed (left->right is a dangerous flip, and a
    controller misstating a suffix is not an ASR error). Ambiguity -> abstain.
  * frequency: candidates are the airport's published frequencies within the
    VHF airband (118-136.975). Exact -> verified; digit near-miss (edit<=1,
    unique) -> snap; unmatched off-raster value -> verdict "invalid" (text
    kept as heard). Frequency matches require a nearby anchor word (contact/
    tower/ground/...) so stray "point" digits in chatter are never edited.
  * Text is rewritten only on a confident snap, in canonical per-digit space;
    everything else passes through untouched. Verdicts feed the gate/UI.

Composes AFTER callsign_snap in the correction pipeline. Swift mirror pending
(same protocol; see docs/PIPELINE.md).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import List, Optional, Tuple

from atc_normalize import normalize as _canon
from atc_diarize import extract_callsign
from airport_data import AirportContext

# The suffix must not be a direction word belonging to the NEXT phrase ("runway 4,
# right traffic" / "right turn" / "right downwind") — capturing it would invent an
# L/R designator the controller never said (review finding, 2026-07-06).
RUNWAY_RX = re.compile(
    r"\brunway((?: \d){1,2})"
    r"( (?:left|right|center)(?! (?:traffic|turn|downwind|base|closed)))?\b")
FREQ_RX = re.compile(r"\b(\d \d \d) point (\d(?: \d){0,2})\b")
# radio speech often omits "point": "contact tower one two six five five"
FREQ_NOPOINT_RX = re.compile(r"\b(1 \d \d) (\d(?: \d)?)\b(?! point)(?! \d)")

FREQ_ANCHORS = {"contact", "monitor", "frequency", "tower", "ground", "approach",
                "departure", "center", "radio", "clearance", "atis"}
AIRBAND = (118.0, 136.975)
_SUFFIX = {"left": "L", "right": "R", "center": "C"}
_SUFFIX_WORD = {v: k for k, v in _SUFFIX.items()}


def _ed(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


@dataclass
class SlotEdit:
    slot: str                    # "runway" | "frequency"
    verdict: str                 # verified | snapped | unverified | invalid
    original: str
    snapped: Optional[str] = None
    applied: bool = False


# ---------------------------------------------------------------------------
# runway
# ---------------------------------------------------------------------------

def _parse_designator(d: str) -> Tuple[str, str]:
    """'17C' -> ('17', 'C'); '22' -> ('22', '')."""
    m = re.match(r"0?(\d{1,2})([LRC]?)$", d.strip().upper())
    return (m.group(1), m.group(2)) if m else ("", "")


def _snap_runway(num: str, suffix: str, ctx: AirportContext) -> Tuple[str, Optional[str]]:
    """-> (verdict, snapped 'NN[ suffix-word]' in spoken canon form or None)."""
    # Unparseable designators (helipads "H1", water/directional "N"/"18W" — ~12k
    # instances in OurAirports) must NOT enter the pool: an empty num is edit-1
    # from any single digit and a "snap" onto it deletes the runway number from
    # the transcript (review finding, 2026-07-06; the Swift mirror always filtered).
    cands = [p for p in (_parse_designator(r) for r in ctx.runways) if p[0]]
    if suffix:
        pool = [n for n, s in cands if s == suffix]
        if num in pool:
            return "verified", None
        near = sorted({n for n in pool if _ed(n, num) == 1})
        if len(near) == 1:
            return "snapped", near[0]
        return "unverified", None
    families = sorted({n for n, _ in cands})
    if num in families:
        return "verified", None
    near = [n for n in families if _ed(n, num) == 1]
    if len(near) == 1:
        return "snapped", near[0]
    return "unverified", None


# ---------------------------------------------------------------------------
# frequency
# ---------------------------------------------------------------------------

def _freq_digits(mhz: float) -> str:
    # Fixed width (6 digits, no stripping): rstrip collapsed integer-MHz values
    # across the decimal (120.0 -> "12") and licensed 2-spoken-digit "snaps"
    # while missing genuine near-misses (review finding, 2026-07-06).
    return f"{mhz:.3f}".replace(".", "")


def _on_raster(mhz: float) -> bool:
    k = round((mhz - 118.0) / 0.025)
    return abs(118.0 + k * 0.025 - mhz) < 1e-6


def _snap_frequency(heard_mhz: float, ctx: AirportContext) -> Tuple[str, Optional[float]]:
    cands = [f for f in ctx.frequency_values if AIRBAND[0] <= f <= AIRBAND[1]]
    for c in cands:
        if abs(c - heard_mhz) < 1e-6:
            return "verified", None
    hd = _freq_digits(heard_mhz)
    near = sorted({c for c in cands if _ed(_freq_digits(c), hd) == 1})
    if len(near) == 1:
        return "snapped", near[0]
    if not (AIRBAND[0] <= heard_mhz <= AIRBAND[1]) or not _on_raster(heard_mhz):
        return "invalid", None
    return "unverified", None


# GA type/model words that anchor a spoken callsign ("cessna twelve sixty five").
# Used ONLY to protect the digits from the frequency patterns — never for snapping.
GA_CALLSIGN_WORDS = {
    "cessna", "piper", "skyhawk", "skylane", "cherokee", "warrior", "archer",
    "bonanza", "baron", "citation", "mooney", "beech", "beechcraft", "cirrus",
    "diamond", "grumman", "lancair", "malibu", "saratoga", "seminole", "seneca",
    "husky", "cub", "champ", "stinson", "maule", "aztec", "navajo", "caravan",
    "kingair", "king", "experimental", "helicopter", "gyroplane",
}


def _callsign_char_range(s: str) -> Optional[Tuple[int, int]]:
    """Char range of the extracted callsign span in ``s`` (token-aligned), or None.

    Guards the frequency patterns against callsign digits: "center american 1786
    with you" must never be read as frequency 178.6, and neither may a GA tail
    ("tower cessna twelve sixty five") — both measured failure classes.
    """
    span = extract_callsign(s)
    if not span:
        # GA-type anchor + digit run (extract_callsign only knows telephony/november)
        tokens = s.split()
        for i, tok in enumerate(tokens[:-1]):
            if tok in GA_CALLSIGN_WORDS and tokens[i + 1].isdigit():
                j = i + 1
                while j < len(tokens) and tokens[j].isdigit():
                    j += 1
                span = " ".join(tokens[i:j])
                break
        if not span:
            return None
    idx = (" " + s + " ").find(" " + span + " ")
    return (idx, idx + len(span)) if idx >= 0 else None


def _render_freq(mhz: float) -> str:
    whole, frac = f"{mhz:.3f}".split(".")
    frac = frac.rstrip("0") or "0"
    return " ".join(whole) + " point " + " ".join(frac)


# ---------------------------------------------------------------------------
# main entry
# ---------------------------------------------------------------------------

def snap_slots(text: str, ctx: Optional[AirportContext]) -> Tuple[str, List[SlotEdit]]:
    """Returns (canonical-space text, edits). No context -> canonicalize only."""
    out = _canon(text)
    edits: List[SlotEdit] = []
    if ctx is None:
        return out, edits

    def runway_sub(m: re.Match) -> str:
        num = m.group(1).replace(" ", "").lstrip("0") or "0"
        suffix_word = (m.group(2) or "").strip()
        verdict, snapped = _snap_runway(num, _SUFFIX.get(suffix_word, ""), ctx)
        heard = num + (suffix_word and " " + suffix_word)
        if verdict == "snapped":
            edits.append(SlotEdit("runway", "snapped", heard,
                                  snapped + (suffix_word and " " + suffix_word), True))
            return "runway " + " ".join(snapped) + (m.group(2) or "")
        edits.append(SlotEdit("runway", verdict, heard))
        return m.group(0)

    def freq_sub(m: re.Match) -> str:
        # require an ATC anchor word shortly before the number; the POINT-LESS
        # pattern additionally requires the anchor IMMEDIATELY before the digits
        # ("contact tower 126 55" yes; "tower cessna 1265" no) — defense in depth
        # for callsign shapes the guard below doesn't know.
        prefix_toks = out[: m.start()].split()[-4:]
        if not FREQ_ANCHORS.intersection(prefix_toks):
            return m.group(0)
        if "point" not in m.group(0) and (not prefix_toks or prefix_toks[-1] not in FREQ_ANCHORS):
            return m.group(0)
        # never read a callsign's digits as a frequency ("center american 1786",
        # "tower cessna twelve sixty five")
        cs = _callsign_char_range(m.string)
        if cs and not (m.end() <= cs[0] or m.start() >= cs[1]):
            return m.group(0)
        heard_str = m.group(1).replace(" ", "") + "." + m.group(2).replace(" ", "")
        heard = float(heard_str)
        verdict, snapped = _snap_frequency(heard, ctx)
        if verdict == "snapped":
            edits.append(SlotEdit("frequency", "snapped", heard_str,
                                  f"{snapped:.3f}".rstrip("0").rstrip("."), True))
            return _render_freq(snapped)
        edits.append(SlotEdit("frequency", verdict, heard_str))
        return m.group(0)

    out = RUNWAY_RX.sub(runway_sub, out)
    out = FREQ_RX.sub(freq_sub, out)
    out = FREQ_NOPOINT_RX.sub(freq_sub, out)
    return out, edits
