"""
Live-pipeline adapter for the airport_context builder.

Exposes the same ``build_prompt()`` / ``update(text)`` surface as
``atc_context.ATCContext`` so ``live_atc_pipeline.LiveATCPipeline`` can drive its
Whisper prompt from auto-fetched airport context instead of a hand-curated feed
config — without changing the transcription loop.

Threading: the live pipeline calls ``build_prompt()``/``update()`` from its
transcription worker thread, so the underlying SQLite connection is opened with
``check_same_thread=False`` and every builder access is serialized with a lock.
The rendered prompt is cached and only rebuilt after the rolling history changes,
so each transmission triggers at most one build.
"""

from __future__ import annotations

import threading
from collections import deque
from typing import List, Optional

from .builder import AirportContextService


def _spoken_list(items, key: str = "spoken") -> List[str]:
    """Pull spoken forms out of snapshot rows (each a dict or a bare string)."""
    out: List[str] = []
    for it in items or []:
        v = it.get(key) if isinstance(it, dict) else it
        if isinstance(v, list):
            v = v[0] if v else None
        if v:
            out.append(str(v))
    return list(dict.fromkeys(out))  # de-dupe, preserve order


def compact_prompt(snapshot: dict, history=None, max_words: int = 95) -> str:
    """Build a tight, proper-noun-first prompt for a FINE-TUNED ATC Whisper model.

    The fine-tuned model already knows ATC phraseology and spelling, so we spend
    the limited prompt budget (Whisper shares one 448-token decoder window between
    prompt and output) on the LOCAL proper nouns it cannot guess — facility names,
    fixes/navaids, procedure names, callsigns — not on generic phrase or spelling
    boilerplate. This is what biases the model toward "Bonham"/"Maverick" instead
    of mishearing them as "Pasta"/"Tellers".
    """
    if not isinstance(snapshot, dict):
        snapshot = {}
    segs: List[str] = []
    fac = snapshot.get("facility_names") or []
    if fac:
        segs.append("; ".join(fac[:4]))
    fixes = _spoken_list(snapshot.get("fixes"))[:20]
    if fixes:
        segs.append("Fixes: " + ", ".join(fixes))
    procs = _spoken_list(snapshot.get("procedures"))[:10]
    if procs:
        segs.append("Procedures: " + ", ".join(procs))
    callsigns: List[str] = []
    for c in snapshot.get("candidate_callsigns") or []:
        callsigns.extend(c.get("spoken") or [] if isinstance(c, dict) else [])
    callsigns = list(dict.fromkeys(callsigns))
    if callsigns:
        segs.append("Callsigns: " + ", ".join(callsigns))
    rwy = _spoken_list(snapshot.get("runways"))[:8]
    if rwy:
        segs.append("Runways: " + ", ".join(rwy))
    prompt = ". ".join(segs)
    hist = " ".join(h for h in (history or []) if h).strip()
    if hist:
        prompt = (prompt + ". Recent: " + hist) if prompt else hist
    words = prompt.split()
    if len(words) > max_words:
        prompt = " ".join(words[:max_words])
    return prompt.strip()


class AirportContextError(RuntimeError):
    """Raised when the requested airport cannot be turned into context.

    Carries the builder's structured error ``result`` (airport_not_found,
    ambiguous_airport, database_empty, ...).
    """

    def __init__(self, result: dict):
        self.result = result or {}
        msg = self.result.get("message") or self.result.get("error") or "airport context unavailable"
        super().__init__(msg)


class AirportModeContext:
    """ATCContext-compatible context driven by :class:`AirportContextService`."""

    def __init__(
        self,
        airport_code: str,
        frequency_type: str = "unknown",
        *,
        candidate_callsigns: Optional[List[str]] = None,
        max_history: int = 3,
        max_prompt_words: int = 600,
        db_path=None,
        log_snapshots: bool = False,
        service: Optional[AirportContextService] = None,
        compact: bool = True,
    ):
        self.airport_code = airport_code
        self.frequency_type = frequency_type or "unknown"
        self.candidate_callsigns = [c for c in (candidate_callsigns or []) if c]
        self.max_prompt_words = max_prompt_words
        # Compact mode renders a tight, proper-noun-first prompt from the snapshot
        # that fits Whisper's prompt budget — the right default for a fine-tuned
        # ATC model. compact=False keeps the full prose prompt (model-agnostic).
        self.compact = compact
        self._history: deque = deque(maxlen=max_history)
        self._lock = threading.Lock()
        self._cached_prompt: Optional[str] = None
        self._dirty = True

        self._own_service = service is None
        self.service = service or AirportContextService(
            db_path=db_path, log_snapshots=log_snapshots, check_same_thread=False
        )

        # Build once up front to validate the airport resolves (fail fast, before
        # the caller loads the ~1 GB model).
        result = self._build()
        if "error" in result:
            if self._own_service:
                self.service.close()
            raise AirportContextError(result)
        self.last_result = result

    # ------------------------------------------------------------------ #
    def _build(self) -> dict:
        request = {
            "airport_code": self.airport_code,
            "frequency_type": self.frequency_type,
            # In compact mode ask for the full snapshot (we trim it ourselves);
            # otherwise honor the configured prose budget.
            "max_prompt_words": 900 if self.compact else self.max_prompt_words,
        }
        if self.candidate_callsigns:
            request["candidate_callsigns"] = self.candidate_callsigns
        if self._history:
            request["prior_transcript"] = " ".join(self._history)
        result = self.service.build(request)
        self.last_result = result
        if "error" in result:
            self._cached_prompt = ""
        elif self.compact:
            self._cached_prompt = compact_prompt(
                result.get("context_snapshot", {}), list(self._history)
            )
        else:
            self._cached_prompt = result.get("prompt", "")
        self._dirty = False
        return result

    def build_prompt(self) -> str:
        """Return the current prompt, rebuilding only if history changed."""
        with self._lock:
            if self._cached_prompt is not None and not self._dirty:
                return self._cached_prompt
            self._build()
            return self._cached_prompt or ""

    def update(self, text: str) -> None:
        text = (text or "").strip()
        if not text:
            return
        with self._lock:
            self._history.append(text)
            self._dirty = True

    @property
    def history(self) -> List[str]:
        return list(self._history)

    def banner_lines(self) -> List[str]:
        """Short human-readable lines for the pipeline startup banner."""
        result = self.last_result or {}
        snap = result.get("context_snapshot", {}) if isinstance(result, dict) else {}
        airport = snap.get("airport", {}) if isinstance(snap, dict) else {}
        code = airport.get("icao") or airport.get("faa_lid") or self.airport_code
        spoken = airport.get("spoken_names") or [airport.get("name") or ""]
        lines = [f"Airport: {code} {spoken[0]} (frequency type: {self.frequency_type})"]
        if result.get("warnings"):
            lines.append("Context notes: " + ", ".join(result["warnings"]))
        return lines

    def close(self) -> None:
        if self._own_service:
            try:
                self.service.close()
            except Exception:
                pass
