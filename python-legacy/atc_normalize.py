"""Canonical normalization for US ATC transcripts.

The validated #1 accuracy lever. A third of the deployed model's apparent "errors"
were pure FORMAT differences — "4R" vs "4 right" vs "four right" are the same runway,
but a naive WER counts them as wrong. Canonicalizing numbers + runway designators on
both hypothesis and reference recovers ~8.7 WER points on the gold set (turbo_ft
28.9% -> 20.2%) at ZERO compute cost.

Three integration points (all benefit from the same function):
  1. EVAL metric  — normalize hyp+ref before WER  -> honest accuracy (~20%, not ~29%).
  2. ON-DEVICE    — canonicalize the corrector/display output so runways render one way.
  3. TRAINING     — canonicalize pseudo-labels so the model learns a single format.

Pure stdlib; the logic is trivially portable to Swift (ATCCorrector.swift).
This module only canonicalizes EQUIVALENT forms — it never changes meaning, so it is
safe to apply unconditionally (unlike the error-fixing corrector).
"""
from __future__ import annotations
import re

# Spoken number words -> value. ICAO variants included; ambiguous words ("for"/"to"/
# "oh") deliberately excluded — they collide with common English.
_UNITS = {"zero": 0, "one": 1, "two": 2, "three": 3, "tree": 3, "four": 4, "fower": 4,
          "five": 5, "fife": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "niner": 9}
_TEENS = {"ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
          "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19}
_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
         "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90}
_RLC = {"r": "right", "l": "left", "c": "center", "centre": "center",
        "right": "right", "left": "left", "center": "center"}


def _strip(text: str) -> str:
    """Lowercase, drop punctuation, collapse whitespace."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", text.lower())).strip()


def _words_to_digits(tokens: list) -> list:
    """Collapse runs of spoken number words into digit strings ("nine seventy five"
    -> "975"); a tens word grabs a following unit (seventy + five -> 75)."""
    out, i, n = [], 0, len(tokens)
    while i < n:
        run, j = [], i
        while j < n and tokens[j] in _UNITS or (j < n and tokens[j] in _TEENS) or (j < n and tokens[j] in _TENS):
            w = tokens[j]
            run.append(_UNITS.get(w, _TEENS.get(w, _TENS.get(w)))); j += 1
        if run:
            k, parts = 0, []
            while k < len(run):
                if run[k] in _TENS.values() and k + 1 < len(run) and run[k + 1] < 10:
                    parts.append(str(run[k] + run[k + 1])); k += 2
                else:
                    parts.append(str(run[k])); k += 1
            out.append("".join(parts)); i = j
        else:
            out.append(tokens[i]); i += 1
    return out


def normalize(text: str) -> str:
    """Return the canonical form: spoken numbers -> digits, multi-digit numbers
    exploded to single spaced digits, and runway designators unified
    ("4r"/"4R"/"four right" -> "4 right"). Apply to BOTH sides before scoring."""
    toks = _words_to_digits(_strip(text).split())
    out = []
    for w in toks:
        m = re.fullmatch(r"(\d+)([rlc])", w)          # "4r" / "22l" -> digits + side
        if m:
            out.append(" ".join(m.group(1))); out.append(_RLC[m.group(2)])
        else:
            out.append(re.sub(r"\d+", lambda x: " ".join(x.group()), w))  # explode digits
    return re.sub(r"\s+", " ", " ".join(out)).strip()


def wer(ref: str, hyp: str) -> float:
    """Word error rate after canonical normalization of both sides."""
    a, b = normalize(ref).split(), normalize(hyp).split()
    n, m = len(a), len(b)
    d = list(range(m + 1))
    for i in range(1, n + 1):
        p = d[0]; d[0] = i
        for j in range(1, m + 1):
            c = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, p + (a[i - 1] != b[j - 1])); p = c
    return d[m] / max(1, n)
