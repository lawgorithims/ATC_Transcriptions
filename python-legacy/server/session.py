"""
Live transcription session for the web server.

Wraps LiveATCPipeline in a background thread and exposes a thread-safe view of
its state (status, rolling transcripts, latency stats) for the HTTP/WebSocket
layer to read. Only one session is active at a time per server.
"""

from __future__ import annotations

import statistics
import threading
import time
from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from typing import Optional

from live_atc_pipeline import LatencyRecord, LiveATCPipeline
from server.audio import AudioBroadcaster

try:
    from airport_context.live import AirportContextError
except Exception:  # airport_context is stdlib-only and always present, but be safe
    class AirportContextError(Exception):  # type: ignore
        pass

ROOT = Path(__file__).resolve().parent.parent

# Status lifecycle the UI renders on the "Stream" pill.
IDLE = "idle"
STARTING = "starting"
CONNECTING = "connecting"
LIVE = "live"
STOPPING = "stopping"
STOPPED = "stopped"
ERROR = "error"

_MAX_RECORDS = 500  # cap in-memory transcript history for the UI


class TranscriptionSession:
    """Manages a single live transcription run in a background thread."""

    def __init__(self, engine, correction_config=None):
        self.engine = engine
        # Optional post-ASR correction layer config (off by default). Passed
        # straight to the pipeline, which builds a no-op corrector when disabled.
        self.correction_config = correction_config or {}
        self._lock = threading.Lock()
        self._pipeline: Optional[LiveATCPipeline] = None
        self._thread: Optional[threading.Thread] = None
        # Live audio relay: the pipeline tees decoded PCM here; browsers subscribe
        # via GET /api/session/audio and hear the same feed the model transcribes.
        self.audio = AudioBroadcaster()

        self.status = IDLE
        self.detail = "No stream running."
        self.error: Optional[str] = None
        self.source_label = ""
        self.stream_url = ""
        self.started_at: Optional[float] = None
        self.stopped_at: Optional[float] = None

        self._seq = 0  # monotonic across runs so WS deltas never miss a record
        self._run_id = 0
        self._records: list[dict] = []
        self._capture_ms: list[float] = []
        self._transcribe_ms: list[float] = []
        self._rtf: list[float] = []

    # ----- lifecycle -------------------------------------------------------

    def is_running(self) -> bool:
        with self._lock:
            return self.status in (STARTING, CONNECTING, LIVE, STOPPING)

    def start(
        self,
        *,
        stream_url: Optional[str] = None,
        feed_config: Optional[str] = None,
        feed_key: Optional[str] = None,
        simulate_file: Optional[str] = None,
        fast_simulate: bool = False,
        max_segments: Optional[int] = None,
        source_label: Optional[str] = None,
        airport: Optional[str] = None,
        frequency_type: Optional[str] = None,
        candidate_callsigns: Optional[list] = None,
    ) -> dict:
        """Start a session. Raises ValueError if one is already running."""
        with self._lock:
            if self.status in (STARTING, CONNECTING, LIVE, STOPPING):
                raise ValueError("A transcription session is already running.")
            self._reset_locked()
            self._run_id += 1
            self.status = STARTING
            self.detail = "Loading model and connecting..."
            self.started_at = time.time()
            self.stopped_at = None
            self.error = None

        # Resolve the playable URL (LiveATC page / mount / direct mp3) up front
        # so bad input fails fast with a clean error instead of in the thread.
        # Resolve a relative feed_config (e.g. "airport_configs/kdfw.json") against
        # the project root so it works no matter where the server was launched from.
        if feed_config:
            fc_path = Path(feed_config)
            if not fc_path.is_absolute():
                fc_path = ROOT / fc_path
            feed_config = str(fc_path)

        resolved_url = stream_url
        simulate = bool(simulate_file)
        if simulate:
            path = Path(simulate_file)  # type: ignore[arg-type]
            if not path.exists():
                self._fail(f"Replay file not found: {simulate_file}")
                raise ValueError(f"Replay file not found: {simulate_file}")
            resolved_url = str(path.resolve())
            label = source_label or f"Replay: {path.name}"
        else:
            from atc_stream import resolve_stream_url

            try:
                resolved_url = resolve_stream_url(
                    stream_url=stream_url,
                    feed_config=Path(feed_config) if feed_config else None,
                    feed_key=feed_key,
                )
            except Exception as exc:
                self._fail(f"Could not resolve stream: {exc}")
                raise ValueError(str(exc))
            if not self.engine.ffmpeg_available():
                self._fail(
                    "ffmpeg is not installed on this host. Live web streams need "
                    "ffmpeg (brew install ffmpeg). Use the replay demo to test "
                    "without it."
                )
                raise ValueError("ffmpeg not available")
            label = source_label or stream_url or feed_key or resolved_url

        with self._lock:
            self.stream_url = resolved_url or ""
            self.source_label = label

        # Build the pipeline with the shared, pre-loaded transcriber.
        airport = (airport or "").strip() or None
        pipe_kwargs = dict(
            stream_url=resolved_url,  # type: ignore[arg-type]
            simulate_file=simulate,
            fast_simulate=fast_simulate,
            feed_config=Path(feed_config) if (feed_config and not simulate) else None,
            feed_key=feed_key if not simulate else None,
            on_record=self._on_record,
            on_status=self._on_status,
            on_audio=self.audio.publish,
            correction_config=self.correction_config,
        )
        try:
            transcriber = self.engine.get_transcriber()
            try:
                pipeline = LiveATCPipeline(
                    transcriber=transcriber,
                    airport=airport if not simulate else None,
                    frequency_type=frequency_type or "unknown",
                    candidate_callsigns=candidate_callsigns or None,
                    **pipe_kwargs,
                )
                if airport and not simulate:
                    with self._lock:
                        self.detail = (
                            f"Using {airport} {frequency_type or 'unknown'} airport context."
                        )
            except AirportContextError as exc:
                # Unknown/ambiguous airport must NOT kill the session — transcribe
                # with generic context and tell the user why.
                with self._lock:
                    self.detail = (
                        f"Airport '{airport}' context unavailable ({exc}); "
                        "using generic context."
                    )
                pipeline = LiveATCPipeline(transcriber=transcriber, **pipe_kwargs)
        except Exception as exc:
            self._fail(f"Failed to start pipeline: {exc}")
            raise

        self._pipeline = pipeline
        self._thread = threading.Thread(
            target=self._run, args=(pipeline, max_segments), daemon=True
        )
        self._thread.start()
        return self.snapshot()

    def stop(self) -> dict:
        with self._lock:
            pipeline = self._pipeline
            if pipeline is None or self.status in (IDLE, STOPPED, ERROR):
                self.status = STOPPED if self.status != ERROR else ERROR
                return self.snapshot()
            self.status = STOPPING
            self.detail = "Stopping..."
        try:
            pipeline.stop()
        except Exception:
            pass
        thread = self._thread
        if thread is not None:
            thread.join(timeout=10)
        self.audio.close()  # end any browser audio streams for this run
        with self._lock:
            if self.status != ERROR:
                self.status = STOPPED
                self.detail = "Stopped."
                self.stopped_at = time.time()
        return self.snapshot()

    # ----- pipeline thread -------------------------------------------------

    def _run(self, pipeline: LiveATCPipeline, max_segments: Optional[int]) -> None:
        try:
            pipeline.run(max_segments=max_segments, report_interval=0)
            with self._lock:
                if self.status not in (STOPPING, STOPPED, ERROR):
                    self.status = STOPPED
                    self.detail = "Stream ended."
                    self.stopped_at = time.time()
            self.audio.close()  # end browser audio when the stream ends on its own
        except Exception as exc:  # pragma: no cover - runtime stream failure
            self._fail(f"Pipeline error: {exc}")

    def _on_record(self, record: LatencyRecord) -> None:
        with self._lock:
            self._seq += 1
            entry = asdict(record)
            entry["seq"] = self._seq
            self._records.append(entry)
            if len(self._records) > _MAX_RECORDS:
                self._records = self._records[-_MAX_RECORDS:]
            self._capture_ms.append(record.capture_to_text_ms)
            self._transcribe_ms.append(record.transcribe_ms)
            self._rtf.append(record.real_time_factor)
            self.status = LIVE
            self.detail = "Transcribing."

    def _on_status(self, msg: str) -> None:
        with self._lock:
            if self.status in (STOPPING, STOPPED, ERROR):
                return
            low = msg.lower()
            if "connecting" in low or "reconnect" in low:
                if self.status != LIVE:
                    self.status = CONNECTING
            self.detail = msg

    def _fail(self, message: str) -> None:
        with self._lock:
            self.status = ERROR
            self.error = message
            self.detail = message
            self.stopped_at = time.time()
        self.audio.close()  # end any browser audio streams on failure

    # ----- read-side -------------------------------------------------------

    def _reset_locked(self) -> None:
        # _seq stays monotonic; only per-run buffers are cleared.
        self._records = []
        self._capture_ms = []
        self._transcribe_ms = []
        self._rtf = []
        self.error = None
        # Evict any listeners attached to the previous run's audio.
        self.audio.close()

    def _stats_locked(self) -> dict:
        def _summary(values: list[float]) -> Optional[dict]:
            if not values:
                return None
            return {
                "mean": round(statistics.mean(values), 1),
                "p50": round(statistics.median(values), 1),
                "min": round(min(values), 1),
                "max": round(max(values), 1),
            }

        return {
            "count": len(self._capture_ms),
            "capture_to_text_ms": _summary(self._capture_ms),
            "transcribe_ms": _summary(self._transcribe_ms),
            "real_time_factor": _summary(self._rtf),
        }

    def snapshot(self, last_seq: int = 0, max_records: int = 100) -> dict:
        """Full state view. Records with seq > last_seq only (0 = all recent)."""
        with self._lock:
            new = [r for r in self._records if r["seq"] > last_seq]
            if max_records:
                new = new[-max_records:]
            uptime = None
            if self.started_at is not None:
                end = self.stopped_at or time.time()
                uptime = round(end - self.started_at, 1)
            return {
                "status": self.status,
                "detail": self.detail,
                "error": self.error,
                "run_id": self._run_id,
                "source_label": self.source_label,
                "stream_url": self.stream_url,
                "started_at": (
                    datetime.fromtimestamp(self.started_at).isoformat(timespec="seconds")
                    if self.started_at
                    else None
                ),
                "uptime_s": uptime,
                "seq": self._seq,
                "records": new,
                "stats": self._stats_locked(),
            }
