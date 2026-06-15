"""
Shared transcription engine for the web server.

Loads the fine-tuned Whisper model exactly once and shares it between the
proof-of-life handshake and any live transcription session, so the ~1 GB model
is never loaded twice. Also reports environment / device health for the UI.
"""

from __future__ import annotations

import glob
import json
import os
import platform
import shutil
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Optional


def ensure_ffmpeg_on_path() -> bool:
    """
    Make ffmpeg findable even if it was just installed and the shell PATH is stale.

    winget/choco install ffmpeg but tell you to "restart your shell" before the
    updated PATH takes effect — long-running or inherited processes never see it.
    If ffmpeg isn't already resolvable, probe the standard install locations and
    prepend the first hit to this process's PATH.

    No-op when ffmpeg is already on PATH (e.g. Homebrew on macOS / Linux).
    Returns True if ffmpeg is resolvable afterward.
    """
    if shutil.which("ffmpeg"):
        return True

    candidates: list[str] = []
    local = os.environ.get("LOCALAPPDATA")
    if local:
        candidates += glob.glob(
            os.path.join(
                local, "Microsoft", "WinGet", "Packages",
                "Gyan.FFmpeg*", "**", "bin", "ffmpeg.exe",
            ),
            recursive=True,
        )
        candidates.append(
            os.path.join(local, "Microsoft", "WinGet", "Links", "ffmpeg.exe")
        )
    candidates += [
        r"C:\ProgramData\chocolatey\bin\ffmpeg.exe",
        r"C:\ffmpeg\bin\ffmpeg.exe",
    ]

    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            os.environ["PATH"] = (
                os.path.dirname(candidate) + os.pathsep + os.environ.get("PATH", "")
            )
            return True
    return shutil.which("ffmpeg") is not None

ROOT = Path(__file__).resolve().parent.parent
DIAG_DATA = ROOT / "tests" / "diagnostic_data"
MANIFEST = DIAG_DATA / "manifest.json"
DEFAULT_MODEL = ROOT / "models" / "whisper-atc"

# Articles dropped before scoring so we measure ATC content, not glue words.
_ARTICLES = {"a", "an", "the"}


def _normalize(text: str) -> list[str]:
    out = []
    for raw in (text or "").lower().split():
        tok = "".join(ch for ch in raw if ch.isalnum())
        if tok and tok not in _ARTICLES:
            out.append(tok)
    return out


def _word_error_rate(reference: str, hypothesis: str) -> float:
    """Normalized WER via token-level Levenshtein distance (mirrors the diagnostic)."""
    ref = _normalize(reference)
    hyp = _normalize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, start=1):
        cur = [i]
        for j, h in enumerate(hyp, start=1):
            cost = 0 if r == h else 1
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1] / len(ref)


class TranscriberEngine:
    """Lazy, thread-safe owner of the fine-tuned Whisper transcriber."""

    def __init__(
        self,
        model_path: str | Path = DEFAULT_MODEL,
        device: str = "auto",
        max_wer: float = 0.5,
    ):
        self.model_path = str(model_path)
        self.device_request = device
        self.max_wer = max_wer
        self._lock = threading.Lock()
        self._transcriber = None  # type: ignore[assignment]
        self._load_error: Optional[str] = None
        self._load_seconds: Optional[float] = None
        self._pol_cache: Optional[dict] = None

    # ----- environment / availability -------------------------------------

    def resolved_device(self) -> str:
        """The backend 'auto' resolves to on this host (cuda / mps / cpu)."""
        try:
            from atc_transcriber import _resolve_device

            return _resolve_device(self.device_request)
        except Exception:
            return self.device_request

    def model_available(self) -> bool:
        p = Path(self.model_path)
        return (p / "model.safetensors").exists() or (p / "config.json").exists()

    def ffmpeg_available(self) -> bool:
        return shutil.which("ffmpeg") is not None

    def is_loaded(self) -> bool:
        return self._transcriber is not None

    def health(self) -> dict:
        info = {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "device_request": self.device_request,
            "resolved_device": self.resolved_device(),
            "model_path": self.model_path,
            "model_available": self.model_available(),
            "model_loaded": self.is_loaded(),
            "ffmpeg_available": self.ffmpeg_available(),
            "load_error": self._load_error,
        }
        try:
            import torch

            info["torch"] = torch.__version__
            info["cuda_available"] = bool(torch.cuda.is_available())
            info["mps_available"] = bool(
                getattr(torch.backends, "mps", None) is not None
                and torch.backends.mps.is_available()
            )
        except Exception:
            pass
        return info

    # ----- model loading ---------------------------------------------------

    def get_transcriber(self):
        """Return the shared transcriber, loading it on first use. Raises on failure."""
        if self._transcriber is not None:
            return self._transcriber
        with self._lock:
            if self._transcriber is not None:
                return self._transcriber
            if not self.model_available():
                self._load_error = (
                    f"Model not found at {self.model_path}. "
                    "Run: python scripts/download_model.py"
                )
                raise FileNotFoundError(self._load_error)
            from atc_transcriber import ATCTranscriber

            t0 = time.perf_counter()
            try:
                self._transcriber = ATCTranscriber(
                    model_path=self.model_path,
                    device=self.device_request,
                    enable_preprocessing=True,
                )
            except Exception as exc:
                self._load_error = str(exc)
                raise
            self._load_seconds = time.perf_counter() - t0
            self._load_error = None
            return self._transcriber

    # ----- proof of life ---------------------------------------------------

    def proof_of_life(self, max_snippets: int = 2, force: bool = False) -> dict:
        """
        Run a few bundled ATC snippets through the model and report PASS/FAIL.

        This is the same handshake as diagnostics/diagnostic.py: it confirms the
        model loads on this host's device and produces sane ATC text. Result is
        cached; pass force=True to re-run.
        """
        if self._pol_cache is not None and not force:
            return self._pol_cache

        result: dict = {
            "passed": False,
            "device": self.resolved_device(),
            "model_available": self.model_available(),
            "checked_at": datetime.now().isoformat(timespec="seconds"),
            "snippets": [],
            "mean_wer": None,
            "load_seconds": None,
            "error": None,
        }

        if not self.model_available():
            result["error"] = (
                "Model weights not found. Run: python scripts/download_model.py"
            )
            self._pol_cache = result
            return result

        try:
            import librosa

            transcriber = self.get_transcriber()
        except Exception as exc:
            result["error"] = f"Model failed to load: {exc}"
            self._pol_cache = result
            return result

        result["load_seconds"] = (
            round(self._load_seconds, 2) if self._load_seconds is not None else None
        )

        try:
            manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
            snippets = manifest.get("snippets", [])[:max_snippets]
        except Exception as exc:
            result["error"] = f"Could not read diagnostic manifest: {exc}"
            self._pol_cache = result
            return result

        scored = []
        for snip in snippets:
            audio_path = DIAG_DATA / snip["file"]
            if not audio_path.exists():
                scored.append(
                    {"file": snip["file"], "ok": False, "error": "missing audio"}
                )
                continue
            audio, _ = librosa.load(str(audio_path), sr=16000)
            t = time.perf_counter()
            hyp = transcriber.transcribe(audio)
            secs = time.perf_counter() - t
            wer = _word_error_rate(snip["reference"], hyp)
            scored.append(
                {
                    "file": snip["file"],
                    "reference": snip["reference"],
                    "hypothesis": hyp,
                    "wer": round(wer, 4),
                    "seconds": round(secs, 3),
                    "ok": bool(hyp.strip()),
                }
            )

        usable = [s for s in scored if "wer" in s]
        mean_wer = sum(s["wer"] for s in usable) / len(usable) if usable else 1.0
        all_alive = bool(usable) and all(s["ok"] for s in scored)
        result["snippets"] = scored
        result["mean_wer"] = round(mean_wer, 4)
        result["passed"] = all_alive and mean_wer <= self.max_wer
        self._pol_cache = result
        return result
