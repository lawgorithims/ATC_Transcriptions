"""
Prompt rendering (spec sections 9.8, 10, 11).

Renders the structured selection into a compact, sectioned prompt in the
recommended order, then enforces the word budget by trimming and dropping
low-priority sections per the spec's drop-order. Protected sections (opening,
runways, supplied callsigns, the last prior-transcript line) are never dropped.
"""

from __future__ import annotations

from typing import Dict, List, Tuple

from . import ranker

_OPENING_TAIL = (
    "Expect FAA ATC phraseology, ICAO phonetic alphabet, aviation numbers, "
    "runway numbers, aircraft callsigns, altitudes, headings, frequencies, "
    "and squawk codes."
)


def opening_line(icao: str, spoken_name: str, frequency_type: str) -> str:
    code = (icao or "").strip()
    name = (spoken_name or "").strip()
    loc = " ".join(p for p in (code, name) if p)
    ft = "unknown" if frequency_type == "unknown" else frequency_type
    return f"ATC aviation radio audio near {loc}. Frequency type: {ft}. {_OPENING_TAIL}"


def _phrase_label(frequency_type: str) -> str:
    if frequency_type == "unknown":
        return "Likely airport phrases"
    if frequency_type in ("approach", "departure"):
        return "Likely approach and departure phrases"
    return f"Likely {frequency_type} phrases"


def _fixes_label(selection: Dict) -> str:
    has_proc = bool(selection.get("procedures"))
    has_fix = bool(selection.get("fixes"))
    if has_proc and has_fix:
        return "Likely procedures and fixes"
    if has_proc:
        return "Likely procedures"
    return "Likely fixes and navaids"


def _compose(selection: Dict, frequency_type: str) -> str:
    """Build the sectioned prompt, skipping empty sections."""
    lines: List[str] = [selection["opening"]]

    def section(label: str, items: List[str]) -> None:
        items = [i for i in (items or []) if i]
        if items:
            lines.append(f"{label}: {'; '.join(items)}.")

    prior = selection.get("prior_transcript") or []
    if prior:
        lines.append(f"Recent transcript: {' '.join(prior)}")

    section("Likely callsigns", selection.get("candidate_callsigns"))
    section("Likely facility names", selection.get("facility_names"))
    section("Likely runways", selection.get("runways"))
    section(_phrase_label(frequency_type), selection.get("phrase_templates"))
    # Combined procedures + fixes section.
    combined = list(selection.get("procedures") or []) + list(selection.get("fixes") or [])
    section(_fixes_label(selection), combined)
    section("Weather words", selection.get("weather_terms"))
    section("Use aviation spellings", selection.get("spelling_hints"))

    return "\n\n".join(lines)


def render(
    selection: Dict,
    frequency_type: str,
    max_words: int = 600,
    hard_max: int = 900,
) -> Tuple[str, int, List[str]]:
    """Render and budget-trim the prompt.

    Returns ``(prompt_text, word_count, dropped_sections)``.
    """
    active = dict(selection)
    text = _compose(active, frequency_type)
    dropped: List[str] = []

    if ranker.word_count(text) <= max_words:
        return text, ranker.word_count(text), dropped

    # First pass: trim droppable list sections to a few items.
    for key in ranker.DROP_ORDER:
        if ranker.word_count(text) <= max_words:
            break
        if active.get(key) and len(active[key]) > 3:
            active[key] = active[key][:3]
            text = _compose(active, frequency_type)

    # Second pass: drop whole sections, in order, until under the hard cap / target.
    for key in ranker.DROP_ORDER:
        if ranker.word_count(text) <= max_words:
            break
        if active.get(key):
            active[key] = []
            dropped.append(key)
            text = _compose(active, frequency_type)

    return text, ranker.word_count(text), dropped
