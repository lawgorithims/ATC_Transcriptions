"""Error attribution on the US gold set: WHERE do models fail, and how much
of the callsign failure is fixable by a post-ASR pipeline layer?

Three analyses per model (all on canonicalized text):
  1. Callsign error taxonomy on rows with an extractable reference callsign:
     correct / wrong-airline / wrong-number / missed. "Wrong number" and
     "wrong airline" are the dangerous, assertive failures (falseCS).
  2. Token-class attribution: substitution+deletion rate per reference token
     class — callsign spans, bare digits, phonetic-alphabet letters, core
     phraseology keywords, everything else. Shows what KIND of content each
     architecture loses.
  3. Snap-layer simulation: the "new pipeline layer" question. Given a
     candidate list of plausible callsigns (stand-in for the live ADS-B
     traffic list), snap each hypothesis callsign to its nearest candidate
     when unambiguous, abstain otherwise. Reports CSA / falseCS before and
     after — the measured ceiling of a post-hoc corrector layer. What a snap
     layer cannot recover (callsigns destroyed past recognition) is the
     remaining case for decode-time biasing.

Usage (from python-legacy/):
    python -m dataset.error_analysis --gold <gold_testset.jsonl> \
        --hyps name=<gold_hyps.jsonl> ...
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from atc_normalize import normalize as canon
from atc_diarize import extract_callsign, _PHONETIC_WORDS, _TELEPHONY

from dataset.normalize import _levenshtein
from dataset.scoreboard import load_gold

import jiwer

PHRASEOLOGY = {
    "cleared", "contact", "runway", "taxi", "hold", "short", "tower", "ground",
    "approach", "center", "departure", "heading", "climb", "descend", "maintain",
    "altimeter", "squawk", "traffic", "wind", "frequency", "ils", "visual",
    "final", "left", "right", "land", "takeoff", "line", "wait", "cross",
    "expect", "direct", "radar", "roger", "wilco", "unable", "say", "again",
}


def _cs(text: str) -> Optional[str]:
    span = extract_callsign(text)
    return canon(span) if span else None


def _split_cs(cs: str) -> Tuple[str, str]:
    """Canonical callsign -> (telephony word, number/letters remainder)."""
    parts = cs.split()
    return parts[0], " ".join(parts[1:])


def _ed(a: str, b: str) -> int:
    return _levenshtein(list(a), list(b))


# ---------------------------------------------------------------------------
# 1. callsign taxonomy
# ---------------------------------------------------------------------------

def callsign_taxonomy(rows: List[dict]) -> Dict[str, int]:
    out = {"correct": 0, "wrong_airline": 0, "wrong_number": 0,
           "wrong_both": 0, "missed": 0, "total": 0}
    for r in rows:
        ref_cs = _cs(r["ref"])
        if not ref_cs:
            continue
        out["total"] += 1
        hyp_cs = _cs(r["hyp"])
        if hyp_cs is None:
            out["missed"] += 1
            continue
        if hyp_cs == ref_cs:
            out["correct"] += 1
            continue
        ra, rn = _split_cs(ref_cs)
        ha, hn = _split_cs(hyp_cs)
        if ha != ra and hn != rn:
            out["wrong_both"] += 1
        elif ha != ra:
            out["wrong_airline"] += 1
        else:
            out["wrong_number"] += 1
    return out


# ---------------------------------------------------------------------------
# 2. token-class attribution
# ---------------------------------------------------------------------------

def _classify_ref_tokens(ref_c: str) -> List[str]:
    toks = ref_c.split()
    classes = ["other"] * len(toks)
    for i, t in enumerate(toks):
        if t.isdigit():
            classes[i] = "digits"
        elif t in _PHONETIC_WORDS:
            classes[i] = "phonetic"
        elif t in PHRASEOLOGY:
            classes[i] = "phraseology"
    cs = _cs(ref_c)
    if cs:
        cs_toks = cs.split()
        for i in range(len(toks) - len(cs_toks) + 1):
            if toks[i: i + len(cs_toks)] == cs_toks:
                for j in range(i, i + len(cs_toks)):
                    classes[j] = "callsign"
                break
    return classes


def token_class_errors(rows: List[dict]) -> Dict[str, Tuple[int, int]]:
    """class -> (sub+del errors, ref token count)."""
    stats: Dict[str, List[int]] = {}
    refs = [canon(r["ref"]) for r in rows]
    hyps = [canon(r["hyp"]) for r in rows]
    out = jiwer.process_words(refs, hyps)
    for ref_c, alignment in zip(refs, out.alignments):
        classes = _classify_ref_tokens(ref_c)
        for chunk in alignment:
            if chunk.type in ("substitute", "delete"):
                for idx in range(chunk.ref_start_idx, chunk.ref_end_idx):
                    c = classes[idx] if idx < len(classes) else "other"
                    stats.setdefault(c, [0, 0])[0] += 1
        for c in classes:
            stats.setdefault(c, [0, 0])[1] += 1
    return {k: (v[0], v[1]) for k, v in stats.items()}


# ---------------------------------------------------------------------------
# 3. snap-layer simulation (the "new pipeline layer")
# ---------------------------------------------------------------------------

def snap(hyp_cs: str, candidates: List[str],
         max_airline_ed: int = 2, max_num_ed: int = 1) -> Optional[str]:
    """Snap an extracted callsign to the nearest candidate; None = abstain."""
    ha, hn = _split_cs(hyp_cs)
    scored = []
    for c in candidates:
        ca, cn = _split_cs(c)
        da, dn = _ed(ha, ca), _ed(hn.replace(" ", ""), cn.replace(" ", ""))
        if da <= max_airline_ed and dn <= max_num_ed:
            scored.append((2 * da + dn, c))
    if not scored:
        return None
    scored.sort()
    if len(scored) > 1 and scored[0][0] == scored[1][0]:
        return None  # ambiguous between two real aircraft — abstain
    return scored[0][1]


def snap_simulation(rows: List[dict], candidates: List[str]) -> Dict[str, Dict[str, int]]:
    def score(get_hyp_cs) -> Dict[str, int]:
        s = {"correct": 0, "false": 0, "missed": 0, "total": 0}
        for r in rows:
            ref_cs = _cs(r["ref"])
            if not ref_cs:
                continue
            s["total"] += 1
            hyp_cs = get_hyp_cs(r)
            if hyp_cs is None:
                s["missed"] += 1
            elif hyp_cs == ref_cs:
                s["correct"] += 1
            else:
                s["false"] += 1
        return s

    raw = score(lambda r: _cs(r["hyp"]))
    snapped = score(lambda r: (lambda h: snap(h, candidates) if h else None)(_cs(r["hyp"])))
    return {"raw": raw, "snapped": snapped}


# ---------------------------------------------------------------------------

def analyze(name: str, rows: List[dict], candidates: List[str]) -> str:
    tax = callsign_taxonomy(rows)
    tok = token_class_errors(rows)
    sim = snap_simulation(rows, candidates)

    L = [f"### {name}", "",
         "callsign taxonomy (of {} ref-callsign rows):".format(tax["total"])]
    for k in ("correct", "wrong_airline", "wrong_number", "wrong_both", "missed"):
        L.append(f"  {k:14s} {tax[k]:3d}  ({tax[k] / max(1, tax['total']) * 100:4.0f}%)")
    L.append("")
    L.append("token-class sub+del rate (errors / ref tokens of class):")
    for c in ("callsign", "digits", "phonetic", "phraseology", "other"):
        if c in tok:
            e, n = tok[c]
            L.append(f"  {c:12s} {e:4d}/{n:4d}  ({e / max(1, n) * 100:4.0f}%)")
    L.append("")
    r, s = sim["raw"], sim["snapped"]

    def line(tag, d):
        return (f"  {tag:8s} CSA {d['correct'] / max(1, d['total']) * 100:4.0f}%  "
                f"falseCS {d['false'] / max(1, d['total']) * 100:4.0f}%  "
                f"missed {d['missed'] / max(1, d['total']) * 100:4.0f}%")
    L.append("snap-layer simulation (candidate list = session callsign inventory):")
    L.append(line("raw", r))
    L.append(line("snapped", s))
    L.append("")
    return "\n".join(L)


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--hyps", nargs="+", required=True, help="name=path pairs")
    args = ap.parse_args(argv)

    gold = load_gold(args.gold)
    candidates = sorted({c for g in gold.values() if (c := _cs(g["ref"]))})
    print(f"gold: {len(gold)} rows, candidate callsign inventory: {len(candidates)}\n")

    for pair in args.hyps:
        name, _, path = pair.partition("=")
        rows = []
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            h = json.loads(line)
            g = gold.get(h["id"])
            if g:
                rows.append({"ref": g["ref"], "hyp": h["hyp"]})
        print(analyze(name, rows, candidates))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
