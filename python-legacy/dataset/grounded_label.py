"""Grounded-teacher label assembly (idea 3+4): turn the two-model (large-v3 A /
turbo B) decodes into a *cleaner* label than "take A wholesale".

Core primitive here: `merge_ab_unk` — a digit-aware, token-level merge of the two
hypotheses. Where A and B agree, keep the word; where they disagree, collapse to
`<unk>`. This makes model uncertainty *explicit* in the label instead of silently
trusting A, and `<unk>` is already first-class downstream (gold_builder emits it,
scoreboard.load_gold excludes `<unk>`-bearing spans from scoring).

Digit formatting is NOT a disagreement: both sides are canonicalized with
`atc_normalize.normalize` first (spoken-number->digits, multi-digit exploded,
punctuation/case stripped), so "805" and "eight zero five" both become "8 0 5"
and align. Output is in that canonical space, which is the space labels are
stored in anyway (normalize_transcript).

This module is standalone/non-importing-into-the-live-pipeline until wired in via
a grounded config; importing it does not touch the running collector.
"""
from __future__ import annotations

import difflib
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from atc_normalize import normalize as _canon  # _strip -> words->digits -> explode

UNK = "<unk>"


def _collapse_unk(tokens: list) -> list:
    out = []
    for w in tokens:
        if w == UNK and out and out[-1] == UNK:
            continue
        out.append(w)
    return out


def merge_ab_unk(text_a: str, text_b: str) -> str:
    """Word-level merge of two hypotheses; agreements kept, disagreements -> <unk>.

    Both sides are digit-canonicalized before alignment so pure format differences
    ("805" vs "8 0 5") never produce a spurious <unk>. Returns canonical-space text
    with consecutive <unk> collapsed. Empty if either side is empty.
    """
    a = _canon(text_a or "").split()
    b = _canon(text_b or "").split()
    if not a or not b:
        return ""
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    merged: list = []
    for tag, i1, i2, _j1, _j2 in sm.get_opcodes():
        if tag == "equal":
            merged.extend(a[i1:i2])        # agreed span — keep the surface (== on both)
        else:
            merged.append(UNK)             # replace / delete / insert -> one <unk>
    return " ".join(_collapse_unk(merged))


def agreement_ratio(text_a: str, text_b: str) -> float:
    """Fraction of the merged label that is NOT <unk> (1.0 = full agreement)."""
    m = merge_ab_unk(text_a, text_b)
    if not m:
        return 0.0
    toks = m.split()
    return sum(1 for t in toks if t != UNK) / len(toks)


import re
import sqlite3
from functools import lru_cache

# CIFP nav DB (airport fixes / procedures / runways — proper nouns whisper can't guess).
_CIFP_DB = "/Users/bsusl/CommSight/ATC_Transcriptions/ios/ATCTranscribe/Resources/nav/cifp.sqlite"
_RLC = {"L": "left", "R": "right", "C": "center"}


def _airlines_from_spoken(spoken: list) -> list:
    """Distinct airline telephony words = the alpha prefix before the first digit of
    each spoken callsign ("american 1051" -> "american"). These are the proper nouns
    whisper mishears (Delta->COPA, NASA->Master); biasing on them is high-value and
    compact, whereas the full 266-callsign list neither fits nor is per-clip-known."""
    out: list = []
    for cs in spoken or []:
        pre = []
        for t in cs.split():
            if any(ch.isdigit() for ch in t):
                break
            pre.append(t)
        name = " ".join(pre).strip()
        if name and name not in out:
            out.append(name)
    return out


def _runways_spoken(designators: list) -> list:
    out: list = []
    for d in designators or []:
        m = re.match(r"RW(\d{1,2})([LRC]?)", str(d))
        if not m:
            continue
        spoken = (str(int(m.group(1))) + " " + _RLC.get(m.group(2), "")).strip()
        if spoken not in out:
            out.append(spoken)
    return out


@lru_cache(maxsize=64)
def cifp_airport_context(airport_code: str, db: str = _CIFP_DB) -> tuple:
    """(runways, fixes, procedures) for an airport from CIFP. Cached; read-only; returns
    empty tuples if the DB or airport is missing (fail-open — grounding is best-effort)."""
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    except Exception:
        return ((), (), ())
    try:
        cur = con.cursor()
        rwy = _runways_spoken([r[0] for r in cur.execute(
            "SELECT DISTINCT designator FROM runway WHERE airport=?", (airport_code,))])
        fixes = [r[0] for r in cur.execute(
            "SELECT DISTINCT leg.fix FROM leg JOIN procedure p ON leg.procedure_id=p.id "
            "WHERE p.airport=? AND leg.fix IS NOT NULL AND leg.fix != '' LIMIT 80", (airport_code,))]
        procs = [r[0] for r in cur.execute(
            "SELECT DISTINCT name FROM procedure WHERE airport=? AND name IS NOT NULL LIMIT 30",
            (airport_code,))]
        return (tuple(rwy), tuple(fixes), tuple(procs))
    except Exception:
        return ((), (), ())
    finally:
        con.close()


def build_grounded_prompt(airport_code: str, traffic_spoken: list,
                          max_words: int = 55, use_cifp: bool = True) -> str:
    """Per-clip whisper `initial_prompt`: airline telephony WORDS present (from ADS-B) plus
    airport fixes/runways (CIFP). Deliberately WEAK/short.

    Validated 2026-07-14: a number-dense prompt (full callsigns like "alaska 2608") makes
    whisper loop/hallucinate the prompted callsigns on low-speech audio. So the prompt carries
    only the proper-noun HINTS whisper can't guess (airline words -> fixes NASA->Master, fixes
    like CAMRN); the digit-level callsign correction is done SAFELY post-decode by callsign_snap
    (digit-preserving, candidate-validated), never by biasing the decoder."""
    airlines = _airlines_from_spoken(traffic_spoken)
    rwy, fixes, _procs = cifp_airport_context(airport_code) if (use_cifp and airport_code) else ((), (), ())
    segs: list = []
    if airlines:
        segs.append("Callsigns: " + ", ".join(airlines[:18]))
    if fixes:
        segs.append("Fixes: " + ", ".join(fixes[:12]))
    if rwy:
        segs.append("Runways: " + ", ".join(rwy[:8]))
    prompt = ". ".join(segs)
    words = prompt.split()
    if len(words) > max_words:
        prompt = " ".join(words[:max_words])
    return prompt.strip()


def _snap(text: str, canon_candidates: list) -> str:
    """Snap the callsign in one decode to the real ADS-B candidates (airline word only;
    digits never invented). Fail-open to the original text."""
    if not canon_candidates:
        return text
    try:
        from callsign_snap import snap_transcript
        return snap_transcript(text, canon_candidates)[0]
    except Exception:
        return text


def assemble_grounded_label(text_a: str, text_b: str, spoken_candidates: list) -> str:
    """The Phase-1 grounded label: snap the callsign in BOTH decodes against the real
    traffic, THEN merge. Pre-snapping lets a candidate disambiguate an A/B callsign
    disagreement (both snap to the same real callsign -> they now agree, no <unk>); an
    unresolvable disagreement still collapses to <unk> for the LLM gap-fill (Phase 3)."""
    cands = list(dict.fromkeys(_canon(c) for c in (spoken_candidates or []) if c))
    return merge_ab_unk(_snap(text_a, cands), _snap(text_b, cands))


if __name__ == "__main__":
    # Demo on REAL consensus pairs from the live collector's scores.jsonl.
    import json

    scores = Path("/Users/bsusl/CommSight/atc-data/us_pseudo/scores.jsonl")
    rows = (json.loads(l) for l in scores.open() if l.strip())
    # accepted pairs where the two models actually differ on the surface — the
    # interesting case for <unk> merging.
    shown = 0
    for r in rows:
        if str(r.get("accepted")) != "True":
            continue
        ta, tb = r.get("text_a") or "", r.get("text_b") or ""
        if not ta.strip() or not tb.strip():
            continue
        merged = merge_ab_unk(ta, tb)
        if UNK not in merged and _canon(ta) == _canon(tb):
            continue  # identical after canon — skip, not illustrative
        ar = agreement_ratio(ta, tb)
        print(f"\n[{r.get('id')}]  agreement={ar:.0%}")
        print(f"  A     : {ta[:90]}")
        print(f"  B     : {tb[:90]}")
        print(f"  MERGED: {merged[:110]}")
        shown += 1
        if shown >= 8:
            break
    print(f"\n(shown {shown} disagreement examples)")
