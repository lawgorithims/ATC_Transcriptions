"""
Optional post-ASR correction layer for live ATC transcripts.

This is the FINAL layer in the pipeline: it runs *after* Whisper, on the decoded
text, and tries to fix obvious errors using the airport's known vocabulary
(facility names, fixes/navaids, procedures, runways, callsigns — the same data
that already drives the Whisper prompt).

Two design rules, both required by the product:

1. OPTIONAL. The whole layer is off by default (``correction.enabled: false`` in
   config.yaml). When off, ``build_corrector`` returns a :class:`NullCorrector`
   and the pipeline behaves exactly as before — no dependency, no latency, no
   behavior change. Turning it on is a config flip.

2. TRANSPARENT. A corrector never silently rewrites text. Every run returns a
   :class:`Correction` carrying the raw text, the corrected text, and the exact
   list of edits (``from`` -> ``to`` + reason + confidence + which backend made
   it). The raw transcript is always preserved; correction is assistive, not
   authoritative — important for a safety-relevant feed.

Backends (composed by :class:`ChainCorrector`):

* :class:`DeterministicCorrector` — stdlib-only, three stages: spoken-number
  normalization ("nine seventy five" -> "975"), character near-miss matching
  ("maverik" -> "Maverick"), and phonetic matching for vowel-confusion errors
  ("golf" -> "Gulf" when Gulf is in vocab). It does NOT invent and cannot fix
  genuine semantic substitutions ("pasta" heard for an unrelated "Bonham") —
  that's the LLM's job. Zero dependencies, instant, safe, runs on any device.
  This is the primary layer.
* :class:`OllamaCorrector` — OPTIONAL local LLM via an on-box Ollama/llama.cpp
  HTTP server (Option A: a small compute box in the aircraft, iPad as thin
  client). Off by default; degrades to "no change" on any error so a missing or
  slow model can never break the live feed. Handles what the dictionary can't.

Porting note (placeholder stack -> native iOS): the *contract* here — the
``Correction`` shape, the deterministic vocab/edit-distance algorithm, and the
"raw preserved + edits recorded" rule — is what carries over. On iPad the
deterministic layer becomes plain Swift; the LLM backend becomes Apple's
Foundation Models framework (M-series) or an embedded MLX/llama.cpp model.
"""

from __future__ import annotations

import difflib
import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Protocol

# Tokens shorter than this are never fuzzy-corrected (too easy to false-match a
# common short word onto a vocab term).
_MIN_TOKEN_LEN = 4


@dataclass
class Correction:
    """Result of running the correction layer on one transcript.

    ``corrected`` is "" when nothing changed (``changed`` is False). The caller
    keeps ``raw`` as the source of truth and only displays ``corrected`` when
    ``changed`` — always with ``edits`` visible so the operator sees what moved.
    """

    raw: str
    corrected: str = ""
    changed: bool = False
    edits: List[dict] = field(default_factory=list)
    backend: str = ""


def _unchanged(text: str, backend: str = "") -> Correction:
    return Correction(raw=text, corrected="", changed=False, edits=[], backend=backend)


def _norm(token: str) -> str:
    """Lowercase, strip non-alphanumerics — for matching, not display."""
    return re.sub(r"[^a-z0-9]", "", token.lower())


class Corrector(Protocol):
    """Anything that turns a raw transcript into a :class:`Correction`."""

    def correct(self, text: str, history: Optional[List[str]] = None) -> Correction: ...


class NullCorrector:
    """No-op corrector used whenever correction is disabled (the default)."""

    def correct(self, text: str, history: Optional[List[str]] = None) -> Correction:
        return _unchanged(text)


# --- ATC number-word normalization -----------------------------------------
# Only unambiguous number spellings (no "for"/"to"/"oh" — those collide with
# common words). Includes the ICAO variants (niner/tree/fife/fower).
_UNITS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "tree": 3, "four": 4, "fower": 4,
    "five": 5, "fife": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "niner": 9,
}
_TEENS = {
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
}
_TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
# "hundred"/"thousand" need altitude-aware arithmetic (a v2 concern); for now they
# simply terminate a digit-string run so we never produce a wrong scaled number.

# Common ATC/English words never replaced by vocab matching — they collide
# phonetically with short vocab terms (e.g. "left" vs a fix "Lift") and must be
# protected from both char and phonetic correction. (Tokens < _MIN_TOKEN_LEN are
# already skipped, so this lists the >=4-char offenders.)
_STOPWORDS = {
    "left", "right", "center", "centre", "cleared", "clear", "runway", "tower",
    "ground", "traffic", "contact", "hold", "short", "line", "wait", "taxi",
    "cross", "descend", "climb", "maintain", "heading", "turn", "approach",
    "departure", "final", "report", "expect", "roger", "wilco", "affirm",
    "negative", "standby", "ready", "position", "holding", "follow", "behind",
    "caution", "wind", "check", "radar", "squawk", "ident", "altitude", "level",
    "knots", "gate", "ramp", "apron", "push", "start", "request", "with",
    "that", "this", "into", "after", "before",
}

_VOWELS = frozenset("aeiou")


def _assemble_digits(run: List[tuple]) -> str:
    """Turn a run of (kind, value) number tokens into a spoken-digit string.

    ATC reads numbers as digit strings, optionally grouping a tens word with the
    following unit: ["nine","seventy","five"] -> "9" + "75" = "975".
    """
    res: List[str] = []
    k = 0
    while k < len(run):
        kind, val = run[k]
        if kind == "tens" and k + 1 < len(run) and run[k + 1][0] == "unit":
            res.append(str(val + run[k + 1][1]))  # seventy + five -> 75
            k += 2
        else:
            res.append(str(val))  # unit->"9", teen->"17", lone tens->"70"
            k += 1
    return "".join(res)


def _normalize_numbers(text: str) -> tuple:
    """Collapse runs of spoken number words into digit strings.

    Returns ``(new_text, edits)``. Vocab-independent, so it runs even with no
    airport context. "hundred"/"thousand" terminate a run (left as-is) to avoid
    producing a wrong scaled altitude — handling those is a later, altitude-aware
    step.
    """
    tokens = text.split()
    out: List[str] = []
    edits: List[dict] = []
    i, n = 0, len(tokens)
    while i < n:
        run: List[tuple] = []
        orig: List[str] = []
        j = i
        while j < n:
            w = _norm(tokens[j])
            if w in _UNITS:
                run.append(("unit", _UNITS[w]))
            elif w in _TEENS:
                run.append(("teen", _TEENS[w]))
            elif w in _TENS:
                run.append(("tens", _TENS[w]))
            else:
                break
            orig.append(tokens[j])
            j += 1
        if run:
            digits = _assemble_digits(run)
            span = " ".join(orig)
            if digits and digits != span:
                edits.append(
                    {"from": span, "to": digits, "reason": "number", "backend": "deterministic"}
                )
                out.append(digits)
            else:
                out.extend(orig)
            i = j
        else:
            out.append(tokens[i])
            i += 1
    return " ".join(out), edits


def _phonetic_key(norm: str) -> str:
    """Crude phonetic skeleton: leading char + ordered consonants, dups collapsed.

    Drops non-leading vowels so vowel-confusion errors collapse together
    ("golf"/"gulf" -> "glf"). Dependency-free and trivial to port to Swift. A
    coarse key, so phonetic matches are additionally gated by a char-ratio floor.
    """
    if not norm:
        return ""
    out = [norm[0]]
    for ch in norm[1:]:
        if ch in _VOWELS or ch == out[-1]:
            continue
        out.append(ch)
    return "".join(out)


class DeterministicCorrector:
    """Fix known-vocabulary errors with zero dependencies.

    Three stages, each recorded as an edit:

    1. Number/phraseology normalization (``numbers``) — spoken numbers to digit
       strings ("niner"->9, "nine seventy five"->"975"). Vocab-independent.
    2. Character near-miss matching — closest vocab term by ``difflib`` ratio at
       ``threshold`` ("maverik"->"Maverick").
    3. Phonetic matching (``phonetic``) — when char-distance is too far but the
       token *sounds* like a vocab term (equal phonetic key) and clears
       ``phonetic_min`` ("golf"->"Gulf" when Gulf is in vocab).

    Conservative by design: a stopword list protects common ATC words, short
    tokens and digits are skipped, and phonetic matches need a char-ratio floor.
    Single-token vocab matching for now (multi-word fixes are a later n-gram step).
    """

    def __init__(
        self,
        vocab_provider: Callable[[], List[str]],
        threshold: float = 0.84,
        phonetic: bool = True,
        phonetic_min: float = 0.62,
        numbers: bool = True,
        min_token_len: int = _MIN_TOKEN_LEN,
    ):
        self.vocab_provider = vocab_provider
        self.threshold = float(threshold)
        self.phonetic = bool(phonetic)
        self.phonetic_min = float(phonetic_min)
        self.numbers = bool(numbers)
        self.min_token_len = int(min_token_len)

    def correct(self, text: str, history: Optional[List[str]] = None) -> Correction:
        text = text or ""
        if not text.strip():
            return _unchanged(text, "deterministic")

        edits: List[dict] = []

        # Stage 1: number normalization (runs even with no vocab).
        current = text
        if self.numbers:
            current, num_edits = _normalize_numbers(current)
            edits.extend(num_edits)

        # Stages 2 & 3: vocab matching (char near-miss, then phonetic fallback).
        canon: dict = {}
        for term in self.vocab_provider() or []:
            nrm = _norm(str(term))
            if nrm:
                canon.setdefault(nrm, str(term))
        if canon:
            norm_vocab = list(canon.keys())
            keys = {nv: _phonetic_key(nv) for nv in norm_vocab} if self.phonetic else {}
            out: List[str] = []
            for word in current.split():
                nw = _norm(word)
                if (
                    len(nw) < self.min_token_len
                    or nw.isdigit()
                    or nw in canon
                    or nw in _STOPWORDS
                ):
                    out.append(word)
                    continue
                match = difflib.get_close_matches(nw, norm_vocab, n=1, cutoff=self.threshold)
                if match and match[0] != nw:
                    score = difflib.SequenceMatcher(None, nw, match[0]).ratio()
                    edits.append(
                        {
                            "from": word,
                            "to": canon[match[0]],
                            "reason": "vocab match",
                            "confidence": round(score, 2),
                            "backend": "deterministic",
                        }
                    )
                    out.append(canon[match[0]])
                    continue
                if self.phonetic:
                    key = _phonetic_key(nw)
                    best, best_ratio = None, 0.0
                    for nv in norm_vocab:
                        if keys.get(nv) == key and nv != nw:
                            r = difflib.SequenceMatcher(None, nw, nv).ratio()
                            if r >= self.phonetic_min and r > best_ratio:
                                best, best_ratio = nv, r
                    if best is not None:
                        edits.append(
                            {
                                "from": word,
                                "to": canon[best],
                                "reason": "phonetic match",
                                "confidence": round(best_ratio, 2),
                                "backend": "deterministic",
                            }
                        )
                        out.append(canon[best])
                        continue
                out.append(word)
            current = " ".join(out)

        if not edits or current == text:
            return _unchanged(text, "deterministic")
        return Correction(
            raw=text, corrected=current, changed=True, edits=edits, backend="deterministic"
        )


class OllamaCorrector:
    """OPTIONAL local-LLM correction via an Ollama-compatible HTTP server.

    Intended for Option A — a small inference box in the aircraft running a tiny
    instruct model (e.g. qwen2.5:3b-instruct). It asks the model for STRICT JSON
    ``{"corrected": str, "edits": [{"from","to","reason"}]}`` (Ollama's
    ``format: "json"`` constrains decoding so small models stay parseable).

    Safety: any failure — server down, timeout, bad JSON, no model — returns the
    text unchanged. A missing or slow local model must never break the live feed.
    Untested without a running Ollama; wired so enabling it is a config flip.
    """

    _SYSTEM = (
        "You correct errors in air-traffic-control radio transcripts. Fix only "
        "clear mistakes using the provided known vocabulary and standard ICAO "
        "phraseology. Make the MINIMUM edits. Never invent content; if unsure, "
        "leave the text unchanged. Preserve numbers and callsigns faithfully. "
        'Reply ONLY with JSON: {"corrected": "...", '
        '"edits": [{"from": "...", "to": "...", "reason": "..."}]}.'
    )

    def __init__(
        self,
        vocab_provider: Callable[[], List[str]],
        url: str = "http://localhost:11434",
        model: str = "qwen2.5:3b-instruct",
        timeout_s: float = 8.0,
    ):
        self.vocab_provider = vocab_provider
        self.url = url.rstrip("/")
        self.model = model
        self.timeout_s = float(timeout_s)

    def correct(self, text: str, history: Optional[List[str]] = None) -> Correction:
        text = text or ""
        if not text.strip():
            return _unchanged(text, "ollama")
        vocab = ", ".join(str(v) for v in (self.vocab_provider() or []) if v)
        user = (
            f"Known vocabulary: {vocab or '(none)'}\n"
            f"Recent transmissions: {' '.join(history or []) or '(none)'}\n"
            f"Transcript to correct: {text}"
        )
        payload = {
            "model": self.model,
            "format": "json",
            "stream": False,
            "options": {"temperature": 0},
            "messages": [
                {"role": "system", "content": self._SYSTEM},
                {"role": "user", "content": user},
            ],
        }
        try:
            req = urllib.request.Request(
                f"{self.url}/api/chat",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=self.timeout_s) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            content = (body.get("message") or {}).get("content") or ""
            parsed = json.loads(content)
        except (urllib.error.URLError, OSError, ValueError, KeyError, TimeoutError):
            # Server down / slow / non-JSON — never break the feed.
            return _unchanged(text, "ollama")

        corrected = (parsed.get("corrected") or "").strip()
        if not corrected or corrected == text:
            return _unchanged(text, "ollama")
        edits = []
        for e in parsed.get("edits") or []:
            if isinstance(e, dict) and e.get("from") and e.get("to"):
                edits.append(
                    {
                        "from": str(e["from"]),
                        "to": str(e["to"]),
                        "reason": str(e.get("reason") or "llm"),
                        "backend": "ollama",
                    }
                )
        return Correction(
            raw=text, corrected=corrected, changed=True, edits=edits, backend="ollama"
        )


class ChainCorrector:
    """Run correctors in order, threading the text through and merging edits.

    Each stage corrects the previous stage's output, so edits accumulate and stay
    attributed to their backend. ``raw`` on the result is the original input.
    """

    def __init__(self, correctors: List[Corrector]):
        self.correctors = list(correctors)

    def correct(self, text: str, history: Optional[List[str]] = None) -> Correction:
        raw = text or ""
        current = raw
        edits: List[dict] = []
        backends: List[str] = []
        for c in self.correctors:
            res = c.correct(current, history=history)
            if res.changed and res.corrected:
                edits.extend(res.edits)
                backends.append(res.backend)
                current = res.corrected
        if not edits or current == raw:
            return _unchanged(raw)
        return Correction(
            raw=raw, corrected=current, changed=True, edits=edits, backend="+".join(backends)
        )


def build_corrector(config: Optional[dict], context) -> Corrector:
    """Build a corrector from config + the live context, or a no-op when disabled.

    ``context`` must expose ``vocab() -> list[str]`` (ATCContext / AirportModeContext
    both do). Returns :class:`NullCorrector` when ``config`` is falsy, disabled, or
    yields no enabled backends — so an "off" config is a genuine no-op.
    """
    if not config or not config.get("enabled"):
        return NullCorrector()

    vocab_provider = getattr(context, "vocab", lambda: [])
    stages: List[Corrector] = []
    if config.get("deterministic", True):
        stages.append(
            DeterministicCorrector(
                vocab_provider,
                threshold=float(config.get("threshold", 0.84)),
                phonetic=bool(config.get("phonetic", True)),
                phonetic_min=float(config.get("phonetic_min", 0.62)),
                numbers=bool(config.get("numbers", True)),
            )
        )
    llm = config.get("llm") or {}
    if llm.get("enabled"):
        stages.append(
            OllamaCorrector(
                vocab_provider,
                url=str(llm.get("url", "http://localhost:11434")),
                model=str(llm.get("model", "qwen2.5:3b-instruct")),
                timeout_s=float(llm.get("timeout_s", 8.0)),
            )
        )
    if not stages:
        return NullCorrector()
    if len(stages) == 1:
        return stages[0]
    return ChainCorrector(stages)
