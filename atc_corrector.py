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

* :class:`DeterministicCorrector` — stdlib-only fuzzy match of transcript tokens
  against the known vocabulary. Catches *near-miss spellings* of known terms
  ("maverik" -> "Maverick", "bonnam" -> "Bonham"); it does NOT invent and cannot
  fix genuine acoustic substitutions ("pasta" heard for "Bonham") — that's the
  LLM's job. Zero dependencies, instant, safe, runs on any device. This is the
  primary layer.
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


class DeterministicCorrector:
    """Fix near-miss spellings of known vocabulary, with zero dependencies.

    For each transcript token that is not already an exact vocab term, find the
    closest vocab term by character-ratio (``difflib``) and, if it clears
    ``threshold``, replace it — recording the edit. Conservative by design: a
    high threshold plus a minimum token length keeps it from "correcting"
    ordinary words. Single-token matching only for now (multi-word fixes like
    "Lone Star" are a future n-gram improvement).
    """

    def __init__(
        self,
        vocab_provider: Callable[[], List[str]],
        threshold: float = 0.84,
        min_token_len: int = _MIN_TOKEN_LEN,
    ):
        self.vocab_provider = vocab_provider
        self.threshold = float(threshold)
        self.min_token_len = int(min_token_len)

    def correct(self, text: str, history: Optional[List[str]] = None) -> Correction:
        text = text or ""
        if not text.strip():
            return _unchanged(text, "deterministic")

        # Map normalized form -> canonical spelling (first wins, preserve order).
        canon: dict[str, str] = {}
        for term in self.vocab_provider() or []:
            n = _norm(str(term))
            if n:
                canon.setdefault(n, str(term))
        if not canon:
            return _unchanged(text, "deterministic")
        norm_vocab = list(canon.keys())

        out: List[str] = []
        edits: List[dict] = []
        for word in text.split():
            nw = _norm(word)
            # Skip short tokens, pure numbers, and tokens already in-vocabulary.
            if len(nw) < self.min_token_len or nw.isdigit() or nw in canon:
                out.append(word)
                continue
            match = difflib.get_close_matches(nw, norm_vocab, n=1, cutoff=self.threshold)
            if match and match[0] != nw:
                canonical = canon[match[0]]
                score = difflib.SequenceMatcher(None, nw, match[0]).ratio()
                edits.append(
                    {
                        "from": word,
                        "to": canonical,
                        "reason": "vocab match",
                        "confidence": round(score, 2),
                        "backend": "deterministic",
                    }
                )
                out.append(canonical)
            else:
                out.append(word)

        corrected = " ".join(out)
        if not edits or corrected == text:
            return _unchanged(text, "deterministic")
        return Correction(
            raw=text, corrected=corrected, changed=True, edits=edits, backend="deterministic"
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
                vocab_provider, threshold=float(config.get("threshold", 0.84))
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
