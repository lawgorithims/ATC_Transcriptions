"""
Role attribution for ATC transmissions: controller vs pilot, plus the callsign.

WHY content-based, not acoustic: ATC is single-channel, band-limited (~8 kHz),
push-to-talk, with short turns and many pilots who sound alike — voice/speaker
diarization (pyannote etc.) is unreliable here. The robust signal is the CONTENT
of the transmission, so this module is rule-based and reuses the existing callsign
vocabulary (``airport_context``).

A "turn" is one VAD segment: ``atc_stream.VADSegmenter`` already yields one
push-to-talk transmission per segment, so each segment is already one speaker on
its own line — this module only LABELS it.

Public API:
    classify_turn(text, context=None) -> TurnLabel(role, callsign, confidence)

``role`` is "controller", "pilot", or "unknown" (when ambiguous/clipped). Callers
should never let an ``unknown`` role block a segment from plain-ASR training.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import List, Optional

# Spoken aviation digit words (one..niner) + the natural cardinals ATC groups
# flight numbers into ("twelve thirty four"). Used to capture the number run that
# follows an airline telephony name when reconstructing a callsign from text.
_DIGIT_WORDS = {
    "zero", "one", "two", "three", "tree", "four", "fower", "five", "fife",
    "six", "seven", "eight", "nine", "niner",
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen",
    "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    "hundred", "thousand",
}

# ICAO phonetic letters (alpha..zulu) — the tokens a tail-number callsign is read
# in ("november three four five alpha bravo").
_PHONETIC_WORDS = {
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliet", "juliett", "kilo", "lima", "mike", "november", "oscar",
    "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
    "xray", "x-ray", "yankee", "zulu",
}

# Phrases that strongly indicate the CONTROLLER is speaking (instructions/clearances).
_CONTROLLER_CUES = (
    "cleared to land", "cleared for takeoff", "cleared for the option",
    "cleared", "contact", "fly heading", "heading", "turn left", "turn right",
    "climb and maintain", "descend and maintain", "climb", "descend", "maintain",
    "radar contact", "traffic", "wind", "expect", "reduce speed", "increase speed",
    "say again", "ident", "squawk", "go around", "line up and wait",
    "hold short", "taxi to", "taxi via", "runway", "cross runway",
    "frequency change approved", "resume own navigation", "no delay", "caution",
    "altimeter", "report", "join", "intercept",
)

# Phrases that indicate a PILOT is speaking (readbacks/requests/acknowledgements).
_PILOT_CUES = (
    "with you", "checking in", "check in", "request", "requesting", "roger",
    "wilco", "we'd like", "we would like", "looking for", "unable", "going around",
    "say intentions", "ready", "in sight", "field in sight", "traffic in sight",
    "negative contact", "missed approach", "for the", "out of", "descending to",
    "climbing to", "leaving",
)


@dataclass
class TurnLabel:
    """Result of classifying one transmission."""

    role: str = "unknown"          # "controller" | "pilot" | "unknown"
    callsign: Optional[str] = None  # best-effort spoken callsign phrase, e.g. "delta twelve thirty four"
    confidence: float = 0.0         # 0..1, heuristic margin


def _telephony_words() -> set:
    """Lowercased single-token airline telephony names (e.g. {"delta","united"}).

    Reuses the project's curated ICAO->telephony map; multi-word names contribute
    their first token (good enough to anchor a callsign span). Falls back silently
    if the airport_context package is unavailable.
    """
    names = set()
    try:
        from airport_context.airlines import telephony_map

        for name in telephony_map().values():
            first = str(name).strip().lower().split()
            if first:
                names.add(first[0])
    except Exception:
        # Minimal embedded fallback so role/callsign logic still works standalone.
        names.update(
            {"american", "delta", "united", "southwest", "jetblue", "spirit",
             "frontier", "alaska", "skywest", "fedex", "ups"}
        )
    return names


_TELEPHONY = _telephony_words()


def _normalize_for_match(text: str) -> str:
    text = (text or "").lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def extract_callsign(text: str) -> Optional[str]:
    """Best-effort: pull the spoken callsign phrase out of a transmission.

    Recognizes two shapes:
      * airline:  <telephony> <number/letter run>   ("delta twelve thirty four")
      * tail:     november <phonetic/number run>     ("november three four five alpha bravo")
    Number tokens may be spoken words OR numerals ("delta 232") — canonicalized
    transcripts and Whisper output both use digits.
    Returns the matched span as spoken (normalized) text, or None.
    """
    tokens = _normalize_for_match(text).split()
    if not tokens:
        return None

    def _is_digitish(tok: str) -> bool:
        return tok in _DIGIT_WORDS or tok.isdigit()

    def _run_from(idx: int) -> List[str]:
        run = [tokens[idx]]
        j = idx + 1
        while j < len(tokens) and (
            _is_digitish(tokens[j]) or tokens[j] in _PHONETIC_WORDS
        ):
            run.append(tokens[j])
            j += 1
        return run

    # Tail number: "november ..." (november is also the phonetic for N).
    for i, tok in enumerate(tokens):
        if tok == "november" and i + 1 < len(tokens) and (
            _is_digitish(tokens[i + 1]) or tokens[i + 1] in _PHONETIC_WORDS
        ):
            return " ".join(_run_from(i))

    # Airline: telephony name followed by at least one number word.
    for i, tok in enumerate(tokens):
        if tok in _TELEPHONY and i + 1 < len(tokens) and _is_digitish(tokens[i + 1]):
            return " ".join(_run_from(i))

    return None


# Weight-class words spoken AFTER a callsign ("delta two thirty two heavy"). They trail the
# callsign span (extract_callsign stops at the digits), so allow them when testing for a
# trailing/readback callsign.
_WEIGHT_SUFFIX = {"heavy", "super"}


def _callsign_position(tokens: List[str], callsign: Optional[str]) -> str:
    """Where the full callsign span sits: 'front', 'back', 'mid', or 'none'.

    'back' = a transmission ENDING in the callsign (a readback / self-identification tag,
    leans pilot); a trailing weight-class word ("heavy"/"super") still counts as back.
    'front' = a transmission LEADING with the callsign (controller addressing an aircraft,
    or a pilot check-in — disambiguated by whether an instruction follows). 'mid'/'none' =
    no positional signal. Matches the whole callsign span, not just its first token.
    """
    if not callsign:
        return "none"
    cs = callsign.split()
    if not cs or len(cs) > len(tokens):
        return "none"
    tail = list(tokens)
    while tail and tail[-1] in _WEIGHT_SUFFIX:
        tail.pop()
    if len(cs) <= len(tail) and tail[-len(cs):] == cs:
        return "back"
    if tokens[: len(cs)] == cs:
        return "front"
    return "mid"


def _count_cues(text: str, cues) -> int:
    """Count DISTINCT matched cue phrases, dropping any that is a substring of a
    longer matched cue (so "cleared to land" isn't also counted as "cleared")."""
    hits = [c for c in cues if c in text]
    distinct = [c for c in hits if not any(c != o and c in o for o in hits)]
    return len(distinct)


def classify_turn(text: str, context=None) -> TurnLabel:
    """Classify a single transmission as controller vs pilot and pull its callsign.

    STRUCTURAL first, lexical second. The strongest discriminator in ATC is WHERE the
    callsign sits:
      * ENDING in the callsign  -> pilot readback / self-identification. The controller
        cue words present are the ECHOED instruction, NOT the controller speaking, so
        they must not flip it (this is the main fix for readbacks being mislabeled
        controller and pilots being undercounted).
      * LEADING with the callsign -> controller IF it also carries an instruction (the
        controller addresses then instructs); otherwise a pilot check-in / request.
    Only with no positional signal do we fall back to counting controller vs pilot cue
    phrases. A lone callsign with no cues leans pilot (ident/ack); a truly empty/ambiguous
    turn stays "unknown" (callers must not let "unknown" block plain-ASR training).

    ``context`` is accepted for forward compatibility but is not required.
    """
    norm = _normalize_for_match(text)
    if not norm:
        return TurnLabel(role="unknown", callsign=None, confidence=0.0)

    tokens = norm.split()
    callsign = extract_callsign(norm)
    position = _callsign_position(tokens, callsign)
    score_c = _count_cues(norm, _CONTROLLER_CUES)
    score_p = _count_cues(norm, _PILOT_CUES)

    # 1) Trailing callsign = readback / ident -> PILOT (echoed controller cues ignored).
    if position == "back":
        return TurnLabel(role="pilot", callsign=callsign,
                         confidence=0.8 if score_p else 0.65)

    # 2) Leading callsign: controller if it instructs, else a pilot check-in / request.
    if position == "front":
        if score_c > 0 and score_c >= score_p:
            return TurnLabel(role="controller", callsign=callsign,
                             confidence=round(min(1.0, 0.6 + 0.2 * (score_c - score_p)), 2))
        return TurnLabel(role="pilot", callsign=callsign, confidence=0.65)

    # 3) No positional signal -> lexical cue counts decide.
    if score_p > score_c:
        return TurnLabel(role="pilot", callsign=callsign,
                         confidence=round(min(1.0, 0.5 + 0.25 * (score_p - score_c)), 2))
    if score_c > score_p:
        return TurnLabel(role="controller", callsign=callsign,
                         confidence=round(min(1.0, 0.5 + 0.25 * (score_c - score_p)), 2))

    # 4) Tie / no cues: a lone callsign leans pilot (ident/ack); otherwise unknown.
    if callsign:
        return TurnLabel(role="pilot", callsign=callsign, confidence=0.5)
    return TurnLabel(role="unknown", callsign=None, confidence=0.0)


def label_line(text: str, context=None) -> str:
    """Render a transmission as a labeled line, e.g. '[CTRL] ...' / '[N345AB] ...'.

    Used by the live pipeline for human-readable, speaker-separated output.
    """
    label = classify_turn(text, context)
    if label.role == "controller":
        tag = "CTRL"
    elif label.role == "pilot":
        tag = (label.callsign or "PILOT").upper() if label.callsign else "PILOT"
    else:
        tag = "??"
    return f"[{tag}] {text}".rstrip()
