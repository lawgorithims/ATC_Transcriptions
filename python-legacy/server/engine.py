"""
Shared transcription engine for the web server.

Owns the fine-tuned Whisper model(s) and shares the active one between the
proof-of-life handshake and the live transcription session, so the model is
never loaded twice. Supports two models — a larger, more-accurate `turbo`
(default) and a smaller, faster `small` fallback — with an *adaptive* startup
benchmark: it loads the default, times it on the proof-of-life snippets, and
auto-falls-back to the smaller model if this device runs slower than a
(UI-adjustable) real-time-speed threshold.

INVARIANT: only ONE model is ever resident in RAM. Swapping unloads the current
model (freeing its memory) before loading the other.
"""

from __future__ import annotations

import gc
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

    Package managers install ffmpeg but tell you to "restart your shell" before
    the updated PATH takes effect — long-running or inherited processes never see
    it. This bites two ways: winget/choco on Windows, and Homebrew on macOS when
    the server runs from a non-login shell (e.g. `nohup`, a service, or SSH) that
    never sourced `brew shellenv`, so /opt/homebrew/bin is absent from PATH.

    If ffmpeg isn't already resolvable, probe the standard install locations and
    prepend the first hit to this process's PATH. No-op when ffmpeg is already on
    PATH. Returns True if ffmpeg is resolvable afterward.
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
        "/opt/homebrew/bin/ffmpeg",  # Homebrew on Apple Silicon
        "/usr/local/bin/ffmpeg",     # Homebrew on Intel macOS / common Linux
        "/opt/local/bin/ffmpeg",     # MacPorts
        "/usr/bin/ffmpeg",           # distro package
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

# Default model registry (server/app.py overrides this from config.yaml).
DEFAULT_MODELS = {
    "small": {"path": str(ROOT / "models" / "whisper-atc")},
    "turbo": {"path": str(ROOT / "models" / "whisper-atc-turbo")},
}

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


def _empty_torch_cache() -> None:
    """Best-effort return of freed GPU memory after a model is dropped."""
    try:
        import torch

        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        mps = getattr(torch.backends, "mps", None)
        if mps is not None and mps.is_available() and hasattr(torch, "mps"):
            torch.mps.empty_cache()
    except Exception:
        pass


class TranscriberEngine:
    """Thread-safe owner of the *active* fine-tuned Whisper model (one in RAM)."""

    def __init__(
        self,
        models: Optional[dict] = None,
        device: str = "auto",
        default_model: str = "turbo",
        fallback_model: str = "small",
        min_realtime_speed: float = 1.2,
        adaptive: bool = True,
        max_wer: float = 0.5,
    ):
        self.models = dict(models or DEFAULT_MODELS)
        self.device_request = device
        self.default_model = (
            default_model if default_model in self.models else next(iter(self.models))
        )
        self.fallback_model = (
            fallback_model if fallback_model in self.models else self.default_model
        )
        self.min_realtime_speed = float(min_realtime_speed)
        self.adaptive = bool(adaptive)
        self.max_wer = max_wer

        self._lock = threading.RLock()
        self._transcriber = None  # type: ignore[assignment]
        self.active_model: Optional[str] = None
        self._load_seconds: Optional[float] = None
        self._load_error: Optional[str] = None

        self.auto_downgraded = False
        self.measured_speed: Optional[float] = None  # realtime speed of the default model
        self._selected = False  # has auto_select run at least once?
        self._selecting = False  # auto_select currently in progress
        self._pol_cache: Optional[dict] = None

    # ----- model registry helpers -----------------------------------------

    def model_path(self, name: str) -> str:
        return str(self.models[name]["path"])

    def model_available(self, name: str) -> bool:
        if name not in self.models:
            return False
        p = Path(self.model_path(name))
        return (p / "model.safetensors").exists() or (p / "config.json").exists()

    def available_models(self) -> dict:
        return {n: self.model_available(n) for n in self.models}

    # ----- environment / availability -------------------------------------

    def resolved_device(self) -> str:
        try:
            from atc_transcriber import _resolve_device

            return _resolve_device(self.device_request)
        except Exception:
            return self.device_request

    def ffmpeg_available(self) -> bool:
        return shutil.which("ffmpeg") is not None

    def is_loaded(self) -> bool:
        return self._transcriber is not None

    # ----- load / unload (enforce one model in RAM) -----------------------

    def _unload_locked(self) -> None:
        if self._transcriber is not None:
            self._transcriber = None
            self.active_model = None
            gc.collect()
            _empty_torch_cache()

    def load_model(self, name: str):
        """Unload the current model (free RAM), then load `name`. Returns the transcriber."""
        if name not in self.models:
            raise ValueError(f"Unknown model '{name}'. Known: {list(self.models)}")
        with self._lock:
            if self.active_model == name and self._transcriber is not None:
                return self._transcriber
            # Free the current model BEFORE loading the next — never two in RAM.
            self._unload_locked()
            if not self.model_available(name):
                self._load_error = (
                    f"Model '{name}' not found at {self.model_path(name)}. "
                    "Run: python scripts/download_model.py"
                )
                raise FileNotFoundError(self._load_error)
            from atc_transcriber import ATCTranscriber

            t0 = time.perf_counter()
            try:
                self._transcriber = ATCTranscriber(
                    model_path=self.model_path(name),
                    device=self.device_request,
                    enable_preprocessing=True,
                )
            except Exception as exc:
                self._load_error = str(exc)
                self.active_model = None
                raise
            self._load_seconds = time.perf_counter() - t0
            self.active_model = name
            self._load_error = None
            self._pol_cache = None  # proof-of-life is per-model
            return self._transcriber

    def get_transcriber(self):
        """Return the active transcriber; run adaptive selection on first use."""
        if self._transcriber is not None:
            return self._transcriber
        with self._lock:
            if self._transcriber is not None:
                return self._transcriber
            if self.adaptive and not self._selected:
                self.auto_select()
                if self._transcriber is not None:
                    return self._transcriber
            return self.load_model(self.active_model or self.default_model)

    # ----- benchmark / timing ---------------------------------------------

    def _load_snippets(self, max_snippets: int):
        import librosa

        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        clips = []
        for snip in manifest.get("snippets", [])[:max_snippets]:
            ap = DIAG_DATA / snip["file"]
            if ap.exists():
                audio, _ = librosa.load(str(ap), sr=16000)
                clips.append((audio, len(audio) / 16000.0, snip))
        return clips

    def _time_snippets(self, transcriber, clips, warmup: int) -> dict:
        # Warmup (untimed): the first MPS/CUDA inference compiles kernels and
        # would otherwise dominate (and ruin) the real-time-speed measurement.
        for _ in range(max(0, warmup)):
            if clips:
                transcriber.transcribe(clips[0][0])

        scored = []
        total_audio = 0.0
        total_proc = 0.0
        for audio, dur, snip in clips:
            t = time.perf_counter()
            hyp = transcriber.transcribe(audio)
            secs = time.perf_counter() - t
            total_audio += dur
            total_proc += secs
            scored.append(
                {
                    "file": snip["file"],
                    "reference": snip.get("reference"),
                    "hypothesis": hyp,
                    "wer": round(_word_error_rate(snip.get("reference", ""), hyp), 4),
                    "seconds": round(secs, 3),
                    "audio_seconds": round(dur, 3),
                    "ok": bool(hyp.strip()),
                }
            )
        realtime_speed = (total_audio / total_proc) if total_proc > 0 else 0.0
        usable = [s for s in scored if s["ok"]]
        mean_wer = sum(s["wer"] for s in usable) / len(usable) if usable else 1.0
        return {
            "snippets": scored,
            "realtime_speed": round(realtime_speed, 3),
            "mean_wer": round(mean_wer, 4),
            "audio_seconds": round(total_audio, 2),
            "processing_seconds": round(total_proc, 2),
            "all_alive": bool(scored) and all(s["ok"] for s in scored),
        }

    def _measure_speed(self, transcriber, warmup: int = 1, passes: int = 2) -> float:
        """Real-time speed (audio_seconds / processing_seconds) on a clip of
        REALISTIC length.

        Whisper has a large fixed per-call cost — it always encodes a 30 s window
        — so timing short snippets individually badly understates throughput: a
        2.8 s clip and a 14 s clip take almost the same wall time, which makes even
        fast hardware look like it can barely keep up (~1x) when it is really ~2x+.
        We concatenate the bundled snippets into one realistic-length transmission
        and time that, after a warmup pass that absorbs first-call kernel/graph
        compilation on MPS/CUDA. Genuinely slow devices still fall below the
        threshold; capable ones are no longer penalized for the fixed cost.
        """
        import numpy as np

        clips = self._load_snippets(1000)  # all bundled snippets
        if not clips:
            return 0.0
        audio = np.concatenate([c[0] for c in clips])
        audio = audio[: 25 * 16000]  # cap ~25 s (one Whisper window) to stay bounded
        dur = len(audio) / 16000.0
        if dur <= 0:
            return 0.0
        for _ in range(max(1, warmup)):
            transcriber.transcribe(audio)  # discard: compiles kernels, warms caches
        best = None
        for _ in range(max(1, passes)):
            t0 = time.perf_counter()
            transcriber.transcribe(audio)
            secs = time.perf_counter() - t0
            best = secs if best is None else min(best, secs)
        return (dur / best) if best and best > 0 else 0.0

    def benchmark(self, name: Optional[str] = None, warmup: int = 1, max_snippets: int = 3) -> dict:
        """Load `name` (or active/default), warm up, then measure real-time speed
        on a representative-length clip (see _measure_speed for why)."""
        with self._lock:
            target = name or self.active_model or self.default_model
            transcriber = self.load_model(target)
            return {
                "realtime_speed": round(self._measure_speed(transcriber, warmup=warmup), 3),
                "model": self.active_model,
                "device": self.resolved_device(),
                "load_seconds": (
                    round(self._load_seconds, 2) if self._load_seconds is not None else None
                ),
            }

    # ----- adaptive selection ---------------------------------------------

    def auto_select(self) -> dict:
        """Startup: load default, benchmark it, downgrade to fallback if too slow."""
        with self._lock:
            self._selecting = True
            self.auto_downgraded = False
            self.measured_speed = None
            try:
                # Default model missing -> fall back to whatever is available.
                if not self.model_available(self.default_model):
                    if self.model_available(self.fallback_model):
                        self.load_model(self.fallback_model)
                    self._selected = True
                    return self.model_status()

                if not self.adaptive:
                    self.load_model(self.default_model)
                    self._selected = True
                    return self.model_status()

                bench = self.benchmark(self.default_model)
                self.measured_speed = bench.get("realtime_speed")
                too_slow = (
                    self.measured_speed is not None
                    and self.measured_speed < self.min_realtime_speed
                )
                if (
                    too_slow
                    and self.fallback_model != self.default_model
                    and self.model_available(self.fallback_model)
                ):
                    self.load_model(self.fallback_model)
                    self.auto_downgraded = True
                # else: keep the default model (already loaded by benchmark())
                self._selected = True
                return self.model_status()
            finally:
                self._selecting = False

    def start_auto_select_async(self) -> None:
        """Kick off adaptive selection in a background thread (non-blocking startup)."""
        if self._selected or self._selecting:
            return

        def _run():
            try:
                self.auto_select()
            except Exception:
                pass

        threading.Thread(target=_run, name="auto-select", daemon=True).start()

    def override(self, name: str) -> dict:
        """Manually force `name` (unloads the other). Caller must ensure no live session."""
        with self._lock:
            self.load_model(name)
            self._selected = True
            self.auto_downgraded = False  # a manual choice supersedes the auto decision
            return self.model_status()

    def set_min_realtime_speed(self, value: float) -> dict:
        with self._lock:
            self.min_realtime_speed = max(0.0, float(value))
            return self.model_status()

    # ----- status / health ------------------------------------------------

    def warning(self) -> Optional[str]:
        if self.auto_downgraded and self.measured_speed is not None:
            return (
                f"Running the smaller model. This device measured "
                f"{self.measured_speed:.2f}x real-time on the larger "
                f"({self.default_model}) model — below the "
                f"{self.min_realtime_speed:.2f}x threshold, so accuracy may be reduced. "
                f"Override in Settings to force the larger model."
            )
        return None

    def model_status(self) -> dict:
        return {
            "active_model": self.active_model,
            "default_model": self.default_model,
            "fallback_model": self.fallback_model,
            "adaptive": self.adaptive,
            "selecting": self._selecting,
            "selected": self._selected,
            "auto_downgraded": self.auto_downgraded,
            "measured_speed": self.measured_speed,
            "min_realtime_speed": self.min_realtime_speed,
            "available": self.available_models(),
            "device": self.resolved_device(),
            "model_loaded": self.is_loaded(),
            "load_error": self._load_error,
            "warning": self.warning(),
        }

    def health(self) -> dict:
        info = {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "device_request": self.device_request,
            "resolved_device": self.resolved_device(),
            "active_model": self.active_model,
            "model_path": self.model_path(self.active_model) if self.active_model else None,
            "model_available": (
                self.model_available(self.active_model)
                if self.active_model
                else any(self.available_models().values())
            ),
            "models_available": self.available_models(),
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

    # ----- proof of life (active model) -----------------------------------

    def proof_of_life(self, max_snippets: int = 2, force: bool = False) -> dict:
        """
        Run a few bundled ATC snippets through the ACTIVE model and report
        PASS/FAIL plus the measured real-time speed. Result is cached; pass
        force=True (or switch models) to re-run.
        """
        if self._pol_cache is not None and not force:
            return self._pol_cache

        result: dict = {
            "passed": False,
            "device": self.resolved_device(),
            "active_model": None,
            "models_available": self.available_models(),
            "checked_at": datetime.now().isoformat(timespec="seconds"),
            "snippets": [],
            "mean_wer": None,
            "realtime_speed": None,
            "load_seconds": None,
            "error": None,
        }

        try:
            transcriber = self.get_transcriber()
        except Exception as exc:
            result["error"] = f"Model failed to load: {exc}"
            self._pol_cache = result
            return result

        result["active_model"] = self.active_model
        result["load_seconds"] = (
            round(self._load_seconds, 2) if self._load_seconds is not None else None
        )

        try:
            timing = self._time_snippets(transcriber, self._load_snippets(max_snippets), warmup=1)
        except Exception as exc:
            result["error"] = f"Proof-of-life failed: {exc}"
            self._pol_cache = result
            return result

        result["snippets"] = timing["snippets"]
        result["mean_wer"] = timing["mean_wer"]
        result["realtime_speed"] = timing["realtime_speed"]
        result["passed"] = timing["all_alive"] and timing["mean_wer"] <= self.max_wer
        self._pol_cache = result
        return result
