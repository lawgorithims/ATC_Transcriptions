"""
ATC transcription context from airport/feed config and rolling call history.

Whisper uses the context string as a prompt prefix to bias decoding toward
facility-specific phraseology, runways, and recent transmissions.
"""

from __future__ import annotations

import json
from collections import deque
from pathlib import Path
from typing import Deque, List, Optional


class ATCContext:
    """Builds Whisper prompt context from feed config and recent transcripts."""

    def __init__(
        self,
        feed_config: Optional[Path] = None,
        feed_key: Optional[str] = None,
        max_history: int = 3,
        max_prompt_chars: int = 800,
    ):
        self.feed_config = Path(feed_config) if feed_config else None
        self.feed_key = feed_key
        self.max_history = max_history
        self.max_prompt_chars = max_prompt_chars
        self._history: Deque[str] = deque(maxlen=max_history)
        self._static_prefix = ""
        self._vocab: List[str] = []  # canonical terms for the optional corrector
        if self.feed_config and self.feed_key:
            self._static_prefix = self._build_static_prefix()

    def _build_static_prefix(self) -> str:
        cfg = json.loads(self.feed_config.read_text(encoding="utf-8"))
        streams = cfg.get("streams") or {}
        entry = streams.get(self.feed_key, {})
        label = entry.get("label") or self.feed_key
        freq = entry.get("frequency_mhz") or ""
        tracon = cfg.get("tracon") or ""
        airport = cfg.get("airport_name") or cfg.get("airport_code") or ""
        runways = cfg.get("runways") or []
        fixes = cfg.get("fixes") or cfg.get("waypoints") or []

        # Canonical terms the optional corrector matches transcript tokens against.
        self._vocab = [str(x) for x in (list(runways) + list(fixes)) if x]

        parts = [
            f"Air traffic control radio transcript from {label}.",
        ]
        if airport:
            parts.append(f"Airport: {airport}.")
        if tracon:
            parts.append(f"Facility: {tracon}.")
        if freq:
            parts.append(f"Frequency: {freq} MHz.")
        if runways:
            parts.append("Runways: " + ", ".join(runways[:8]) + ".")
        if fixes:
            parts.append("Fixes: " + ", ".join(fixes[:10]) + ".")
        parts.append(
            "Use standard ICAO phraseology, spell out numbers, include call signs and runways."
        )
        return " ".join(parts)

    def update(self, text: str) -> None:
        text = (text or "").strip()
        if text:
            self._history.append(text)

    @property
    def history(self) -> List[str]:
        return list(self._history)

    def build_prompt(self) -> str:
        """Return context string for Whisper prompt conditioning."""
        if not self._static_prefix and not self._history:
            return ""

        sections = []
        if self._static_prefix:
            sections.append(self._static_prefix)
        if self._history:
            recent = " ".join(self._history)
            sections.append(f"Recent transmissions: {recent}")

        prompt = " ".join(sections).strip()
        if len(prompt) > self.max_prompt_chars:
            prompt = prompt[-self.max_prompt_chars :]
        return prompt

    def vocab(self) -> List[str]:
        """Canonical local terms (runways, fixes) for the optional corrector."""
        return list(self._vocab)

    def reload(self, feed_config: Path, feed_key: str) -> None:
        self.feed_config = Path(feed_config)
        self.feed_key = feed_key
        self._static_prefix = self._build_static_prefix()
