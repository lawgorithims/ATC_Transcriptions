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
    ):
        self.airport_code = airport_code
        self.frequency_type = frequency_type or "unknown"
        self.candidate_callsigns = [c for c in (candidate_callsigns or []) if c]
        self.max_prompt_words = max_prompt_words
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
            "max_prompt_words": self.max_prompt_words,
        }
        if self.candidate_callsigns:
            request["candidate_callsigns"] = self.candidate_callsigns
        if self._history:
            request["prior_transcript"] = " ".join(self._history)
        result = self.service.build(request)
        self.last_result = result
        self._cached_prompt = "" if "error" in result else result.get("prompt", "")
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
