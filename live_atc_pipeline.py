"""
Live ATC pipeline — finished-product style real-time transcription from online feeds.

Tunes into a replaceable HTTP/Icecast ATC stream (LiveATC or any MP3 URL), detects
transmissions with VAD, transcribes with the fine-tuned local model, prints each
transmission as it completes, and reports per-utterance latency metrics.

Usage:
    # Default KDFW Lone Star Approach feed from airport_configs/kdfw.json
    python live_atc_pipeline.py

    # Custom stream URL (any replaceable live feed)
    python live_atc_pipeline.py --stream-url https://d.liveatc.net/kdfw1_app_fin_17c

    # Auto-fetched airport-mode context (airport_context): pair any feed with an
    # airport + frequency type. Needs the DB: python -m airport_context.cli ingest
    python live_atc_pipeline.py --stream-url https://d.liveatc.net/kdfw1_twr1_e \
        --airport KDFW --frequency-type tower

    # LiveATC listen page (mount extracted automatically)
    python live_atc_pipeline.py --liveatc-page "https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c"

    # Offline latency evaluation using a recorded feed
    python live_atc_pipeline.py --simulate-file data/live_atc/KJFK-Twr2-Mar-15-2026-0000Z.mp3 --max-segments 20
"""

from __future__ import annotations

import argparse
import json
import queue
import statistics
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable, List, Optional

from atc_context import ATCContext
from atc_stream import (
    AsyncSegmentProducer,
    FileSimulator,
    StreamCapture,
    VADSegmenter,
    resolve_stream_url,
)
from atc_transcriber import ATCTranscriber

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass


@dataclass
class LatencyRecord:
    text: str
    stream_start_s: float
    stream_end_s: float
    audio_duration_ms: float
    capture_to_text_ms: float
    transcribe_ms: float
    real_time_factor: float
    timestamp: str = field(default_factory=lambda: datetime.now().strftime("%H:%M:%S"))


@dataclass
class LatencyStats:
    count: int = 0
    capture_to_text_ms: List[float] = field(default_factory=list)
    transcribe_ms: List[float] = field(default_factory=list)
    rtf: List[float] = field(default_factory=list)

    def add(self, record: LatencyRecord) -> None:
        self.count += 1
        self.capture_to_text_ms.append(record.capture_to_text_ms)
        self.transcribe_ms.append(record.transcribe_ms)
        self.rtf.append(record.real_time_factor)

    def summary(self) -> dict:
        if not self.count:
            return {"count": 0}

        def _stats(values: List[float]) -> dict:
            return {
                "mean": round(statistics.mean(values), 1),
                "p50": round(statistics.median(values), 1),
                "p95": round(_percentile(values, 95), 1),
                "min": round(min(values), 1),
                "max": round(max(values), 1),
            }

        return {
            "count": self.count,
            "capture_to_text_ms": _stats(self.capture_to_text_ms),
            "transcribe_ms": _stats(self.transcribe_ms),
            "real_time_factor": _stats(self.rtf),
        }


def _percentile(values: List[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = int(round((pct / 100.0) * (len(ordered) - 1)))
    return ordered[idx]


class LiveATCPipeline:
    """Capture live ATC audio, transcribe transmissions, report latency."""

    def __init__(
        self,
        stream_url: str,
        model_path: str = "models/whisper-atc",
        device: str = "auto",
        enable_preprocessing: bool = True,
        aggressive_preprocessing: bool = True,
        vad_aggressiveness: int = 2,
        silence_duration_ms: int = 700,
        min_speech_ms: int = 500,
        max_segment_s: float = 12.0,
        simulate_file: bool = False,
        fast_simulate: bool = False,
        feed_config: Optional[Path] = None,
        feed_key: Optional[str] = None,
        context_history: int = 3,
        airport: Optional[str] = None,
        frequency_type: str = "unknown",
        candidate_callsigns: Optional[List[str]] = None,
        context_db: Optional[str] = None,
        log_context_snapshots: bool = False,
        max_prompt_words: int = 600,
        transcriber: Optional[ATCTranscriber] = None,
        on_record: Optional[Callable[[LatencyRecord], None]] = None,
        on_status: Optional[Callable[[str], None]] = None,
        on_audio: Optional[Callable] = None,
    ):
        self.stream_url = stream_url
        self.simulate_file = simulate_file
        # Optional callbacks for embedding the pipeline (e.g. the web server).
        # The CLI leaves these unset and keeps its print-based behavior.
        self.on_record = on_record
        self.on_status_cb = on_status
        # Optional tee of the decoded PCM for the web server's browser audio relay.
        self.on_audio = on_audio
        self.stats = LatencyStats()
        self.records: List[LatencyRecord] = []
        self._result_queue: queue.Queue = queue.Queue()
        self._transcribe_thread: Optional[threading.Thread] = None
        self._running = False
        self._max_segments: Optional[int] = None
        self._segments_done = 0

        # Airport-mode context (auto-fetched from the airport_context database)
        # is opt-in via `airport`; otherwise use the hand-curated feed-config
        # context. Both expose build_prompt()/update(), so the loop is unchanged.
        # An invalid/unknown airport raises AirportContextError here, before the
        # ~1 GB model loads below — surfaced with a friendly message in main().
        if airport:
            from airport_context.live import AirportModeContext

            self.context = AirportModeContext(
                airport_code=airport,
                frequency_type=frequency_type,
                candidate_callsigns=candidate_callsigns,
                max_history=context_history,
                max_prompt_words=max_prompt_words,
                db_path=context_db,
                log_snapshots=log_context_snapshots,
            )
        else:
            self.context = ATCContext(
                feed_config=feed_config,
                feed_key=feed_key,
                max_history=context_history,
            )

        # Reuse a pre-loaded transcriber when one is supplied (the web server
        # loads the ~1 GB model once and shares it across proof-of-life + sessions).
        self.transcriber = transcriber or ATCTranscriber(
            model_path=model_path,
            device=device,
            enable_preprocessing=enable_preprocessing,
            aggressive_preprocessing=aggressive_preprocessing,
        )

        capture_url = str(Path(stream_url).resolve()) if simulate_file else stream_url

        if simulate_file:
            self.capture = FileSimulator(
                capture_url,
                chunk_duration_s=0.5,
                realtime=not fast_simulate,
                on_audio=on_audio,
            )  # type: ignore[assignment]
        else:
            self.capture = StreamCapture(
                capture_url,
                chunk_duration_s=0.5,
                on_status=self._status,
                on_audio=on_audio,
            )
        self.segmenter = VADSegmenter(
            aggressiveness=vad_aggressiveness,
            silence_duration_ms=silence_duration_ms,
            min_speech_ms=min_speech_ms,
            max_segment_s=max_segment_s,
        )
        self.producer = AsyncSegmentProducer(self.capture, self.segmenter)

    def _status(self, msg: str) -> None:
        print(f"[stream] {msg}", file=sys.stderr)
        if self.on_status_cb is not None:
            try:
                self.on_status_cb(msg)
            except Exception:  # never let a UI callback kill the stream
                pass

    def stop(self) -> None:
        """Request a graceful shutdown of the run loop (for embedded use)."""
        self._running = False
        self.producer.stop()

    def close(self) -> None:
        """Release the owned airport context / DB connection (idempotent)."""
        closer = getattr(self.context, "close", None)
        if callable(closer):
            try:
                closer()
            except Exception:
                pass

    def _transcribe_segment(self, segment) -> Optional[LatencyRecord]:
        t0 = time.perf_counter()
        prompt = self.context.build_prompt()
        text = self.transcriber.transcribe(segment.audio, context=prompt)
        t1 = time.perf_counter()

        text = (text or "").strip()
        if not text:
            return None

        self.context.update(text)

        audio_ms = len(segment.audio) / 16000.0 * 1000.0
        transcribe_ms = (t1 - t0) * 1000.0
        # capture-to-text spans two events, so it must use the wall clock
        # (time.time) — segment.finalized_wall_time is a time.time() stamp, NOT a
        # perf_counter value, so subtracting t1 (perf_counter) gave garbage.
        capture_to_text_ms = (time.time() - segment.finalized_wall_time) * 1000.0
        rtf = transcribe_ms / audio_ms if audio_ms > 0 else 0.0

        return LatencyRecord(
            text=text,
            stream_start_s=round(segment.stream_start_s, 1),
            stream_end_s=round(segment.stream_end_s, 1),
            audio_duration_ms=round(audio_ms, 1),
            capture_to_text_ms=round(capture_to_text_ms, 1),
            transcribe_ms=round(transcribe_ms, 1),
            real_time_factor=round(rtf, 3),
        )

    def _print_transcription(self, record: LatencyRecord) -> None:
        print(f"\n[{record.timestamp} | stream {record.stream_start_s:.1f}s]")
        print(f"  ATC> {record.text}")
        print(
            f"  latency: {record.capture_to_text_ms:.0f} ms capture-to-text | "
            f"transcribe {record.transcribe_ms:.0f} ms | "
            f"audio {record.audio_duration_ms:.0f} ms | "
            f"RTF {record.real_time_factor:.2f}"
        )

    def _print_summary(self) -> None:
        summary = self.stats.summary()
        if summary.get("count", 0) == 0:
            print("\nNo transcriptions captured.")
            return

        ct = summary["capture_to_text_ms"]
        tr = summary["transcribe_ms"]
        print("\n" + "=" * 72)
        print("LATENCY SUMMARY")
        print("=" * 72)
        print(f"  Transmissions: {summary['count']}")
        print(
            f"  Capture-to-text:  mean {ct['mean']:.0f} ms | "
            f"p50 {ct['p50']:.0f} | p95 {ct['p95']:.0f} | "
            f"min {ct['min']:.0f} | max {ct['max']:.0f}"
        )
        print(
            f"  Transcribe:      mean {tr['mean']:.0f} ms | "
            f"p50 {tr['p50']:.0f} | p95 {tr['p95']:.0f}"
        )
        print(f"  RTF mean:        {summary['real_time_factor']['mean']:.2f}")
        print("=" * 72)

    def _transcribe_worker(self) -> None:
        while self._running:
            try:
                segment = self._segment_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            if segment is None:
                break
            try:
                record = self._transcribe_segment(segment)
            except Exception as exc:  # one bad segment must not kill the worker
                self._status(f"transcription error (segment dropped): {exc}")
                record = None
            if record:
                self._result_queue.put(record)

    def run(
        self,
        max_segments: Optional[int] = None,
        report_interval: int = 10,
        output_json: Optional[Path] = None,
    ) -> None:
        # ATC transcripts can contain non-Latin-1 characters; the default Windows
        # console encoding (cp1252) would otherwise raise UnicodeEncodeError and
        # kill the run loop. Replace unencodable chars instead of crashing.
        for stream in (sys.stdout, sys.stderr):
            try:
                stream.reconfigure(errors="replace")  # type: ignore[attr-defined]
            except (AttributeError, ValueError):
                pass

        print("=" * 72)
        print("LIVE ATC TRANSCRIPTION PIPELINE")
        print("=" * 72)
        print(f"  Feed:   {self.stream_url}")
        if self.simulate_file:
            realtime = getattr(self.capture, "realtime", True) is not False
            mode = "real-time replay" if realtime else "fast replay"
            audio_s = len(getattr(self.capture, "audio", [])) / 16000.0
            print(f"  Mode:   offline simulation ({mode}, {audio_s:.0f}s audio)")
            if realtime and audio_s > 120:
                # Real-time replay of a long recording runs for the full duration;
                # this is intentional for latency eval but surprises quick checks.
                print(
                    f"          note: real-time replay of this file takes ~{audio_s / 60:.0f} min — "
                    "add --fast-simulate for a quick functional check"
                )
        print(f"  Model:  whisper-atc (with context)")
        print(f"  Device: {self.transcriber.device}")
        for line in getattr(self.context, "banner_lines", lambda: [])():
            print(f"  {line}")
        if self.context.build_prompt():
            preview = self.context.build_prompt()[:120]
            print(f"  Context: {preview}...")
        print("  Press Ctrl+C to stop\n")

        self._max_segments = max_segments
        self._running = True
        self._segment_queue: queue.Queue = queue.Queue(maxsize=16)
        self._transcribe_thread = threading.Thread(
            target=self._transcribe_worker, daemon=True
        )
        self._transcribe_thread.start()
        self.producer.start()

        try:
            while self._running:
                try:
                    segment = self.producer.queue.get(timeout=0.5)
                except queue.Empty:
                    # No new segment yet (e.g. silence on a live stream). Surface
                    # any finished transcriptions and keep waiting — do NOT exit.
                    self._drain_results(report_interval)
                    continue
                if segment is None:
                    self._status("Stream producer stopped.")
                    break
                self._segment_queue.put(segment)

                self._drain_results(report_interval)

                if max_segments and self._segments_done >= max_segments:
                    print(f"\nReached --max-segments {max_segments}. Stopping.")
                    break

            self._segment_queue.put(None)
            if self._transcribe_thread:
                self._transcribe_thread.join(timeout=120)

            self._drain_results(report_interval, stop_at_max=True)

        except KeyboardInterrupt:
            print("\n\nStopping pipeline...")
        finally:
            self._running = False
            self.producer.stop()
            self._print_summary()
            if output_json:
                self._save_json(output_json)
            self.close()

    def _drain_results(self, report_interval: int, stop_at_max: bool = False) -> None:
        """Flush any completed transcriptions from the worker to the handler."""
        while True:
            try:
                record = self._result_queue.get_nowait()
            except queue.Empty:
                break
            self._handle_record(record, report_interval)
            if stop_at_max and self._max_segments and self._segments_done >= self._max_segments:
                break

    def _handle_record(self, record: LatencyRecord, report_interval: int) -> None:
        self.records.append(record)
        self.stats.add(record)
        # Notify embedded subscribers (e.g. the web UI) first — console printing
        # is best-effort and must never block or drop a transcript.
        if self.on_record is not None:
            try:
                self.on_record(record)
            except Exception:  # a slow/broken subscriber must not stall the pipeline
                pass
        self._print_transcription(record)
        self._segments_done += 1
        if report_interval and self._segments_done % report_interval == 0:
            s = self.stats.summary()
            ct = s["capture_to_text_ms"]
            print(
                f"\n--- rolling stats ({s['count']} tx) "
                f"capture-to-text p50={ct['p50']:.0f}ms mean={ct['mean']:.0f}ms ---\n"
            )
        if self._max_segments and self._segments_done >= self._max_segments:
            self._running = False

    def _save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "stream_url": self.stream_url,
            "generated_at": datetime.now().isoformat(),
            "summary": self.stats.summary(),
            "transmissions": [asdict(r) for r in self.records],
        }
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nLatency report saved: {path}")


def _load_pipeline_config(config_path: Path) -> dict:
    import yaml

    if config_path.exists():
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = yaml.safe_load(f) or {}
        return cfg.get("live_pipeline", {})
    return {}


def main():
    # Make CLI output (including --help, which contains a "→") safe under the
    # Windows console / piped-stdout default encoding (cp1252).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass

    parser = argparse.ArgumentParser(
        description="Live online ATC feed → real-time transcription with latency metrics"
    )
    parser.add_argument(
        "--config",
        type=str,
        default="config.yaml",
        help="Config file (live_pipeline section)",
    )
    parser.add_argument(
        "--stream-url",
        type=str,
        default=None,
        help="Direct MP3/Icecast stream URL (overrides feed config)",
    )
    parser.add_argument(
        "--feed-config",
        type=str,
        default="airport_configs/kdfw.json",
        help="Airport feed config JSON (default: airport_configs/kdfw.json)",
    )
    parser.add_argument(
        "--feed",
        type=str,
        default="lone_star_approach_17c_final",
        help="Feed key inside feed-config streams (default: lone_star_approach_17c_final)",
    )
    parser.add_argument(
        "--liveatc-page",
        type=str,
        default=None,
        help="LiveATC listen page URL; mount is extracted to build stream URL",
    )
    parser.add_argument(
        "--simulate-file",
        type=str,
        default=None,
        help="Replay a local audio file at live pace (offline latency testing)",
    )
    parser.add_argument(
        "--fast-simulate",
        action="store_true",
        help="With --simulate-file: replay as fast as possible (skip real-time pacing)",
    )
    parser.add_argument(
        "--model-path",
        type=str,
        default=None,
        help="Fine-tuned model path (default: models/whisper-atc)",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="auto",
        choices=["cpu", "cuda", "auto"],
    )
    parser.add_argument(
        "--no-preprocessing",
        action="store_true",
        help="Disable radio preprocessing before ASR",
    )
    parser.add_argument(
        "--max-segments",
        type=int,
        default=None,
        help="Stop after N transcribed transmissions (useful for evaluation)",
    )
    parser.add_argument(
        "--report-interval",
        type=int,
        default=10,
        help="Print rolling latency stats every N transmissions (0=disable)",
    )
    parser.add_argument(
        "--output-json",
        type=str,
        default=None,
        help="Save latency report JSON (e.g. results/live/kdfw/latency_report.json)",
    )
    parser.add_argument(
        "--vad-aggressiveness",
        type=int,
        default=None,
        choices=[0, 1, 2, 3],
        help="WebRTC VAD aggressiveness (0=least, 3=most)",
    )
    parser.add_argument(
        "--silence-ms",
        type=int,
        default=None,
        help="Silence duration to end a transmission (default: 700)",
    )
    parser.add_argument(
        "--airport",
        type=str,
        default=None,
        help="Airport code (ICAO/IATA/FAA-LID) for auto-fetched airport-mode context "
        "(airport_context). Overrides the feed-config static context. "
        "Requires the DB: python -m airport_context.cli ingest",
    )
    parser.add_argument(
        "--frequency-type",
        type=str,
        default=None,
        choices=[
            "clearance", "ground", "tower", "approach",
            "departure", "center", "ctaf", "unknown",
        ],
        help="Frequency type for airport-mode context (default: unknown)",
    )
    parser.add_argument(
        "--callsigns",
        type=str,
        default=None,
        help="Comma-separated candidate callsigns for airport-mode context (e.g. DAL1234,N345AB)",
    )
    parser.add_argument(
        "--context-db",
        type=str,
        default=None,
        help="airport_context SQLite DB path (default: data/airport_context/airport_context.db)",
    )
    parser.add_argument(
        "--log-context-snapshots",
        action="store_true",
        help="Log each segment's airport-mode context snapshot to the DB (for evaluation)",
    )
    args = parser.parse_args()

    pipe_cfg = _load_pipeline_config(Path(args.config))

    if args.simulate_file:
        stream_url = args.simulate_file
        simulate = True
    else:
        stream_url = resolve_stream_url(
            stream_url=args.stream_url or pipe_cfg.get("stream_url"),
            feed_config=Path(args.feed_config or pipe_cfg.get("feed_config", "airport_configs/kdfw.json")),
            feed_key=args.feed or pipe_cfg.get("feed", "lone_star_approach_17c_final"),
            liveatc_page=args.liveatc_page or pipe_cfg.get("liveatc_page"),
        )
        simulate = False

    # Airport-mode context (airport_context). Empty/blank airport => use the
    # hand-curated feed-config context instead.
    airport = args.airport or pipe_cfg.get("airport") or None
    frequency_type = args.frequency_type or pipe_cfg.get("frequency_type", "unknown")
    if args.callsigns:
        candidate_callsigns = [c.strip() for c in args.callsigns.split(",") if c.strip()]
    else:
        candidate_callsigns = pipe_cfg.get("candidate_callsigns")

    try:
        pipeline = LiveATCPipeline(
            stream_url=stream_url,
            model_path=args.model_path or pipe_cfg.get("model_path", "models/whisper-atc"),
            device=args.device or pipe_cfg.get("device", "auto"),
            enable_preprocessing=not args.no_preprocessing
            and pipe_cfg.get("enable_preprocessing", True),
            aggressive_preprocessing=pipe_cfg.get("aggressive_preprocessing", True),
            vad_aggressiveness=args.vad_aggressiveness
            if args.vad_aggressiveness is not None
            else pipe_cfg.get("vad_aggressiveness", 2),
            silence_duration_ms=args.silence_ms
            if args.silence_ms is not None
            else pipe_cfg.get("silence_duration_ms", 700),
            min_speech_ms=pipe_cfg.get("min_speech_duration_ms", 500),
            max_segment_s=pipe_cfg.get("max_segment_duration_s", 12.0),
            simulate_file=simulate,
            fast_simulate=args.fast_simulate,
            feed_config=Path(args.feed_config or pipe_cfg.get("feed_config", "airport_configs/kdfw.json")),
            feed_key=args.feed or pipe_cfg.get("feed", "lone_star_approach_17c_final"),
            context_history=pipe_cfg.get("context_history", 3),
            airport=airport,
            frequency_type=frequency_type,
            candidate_callsigns=candidate_callsigns,
            context_db=args.context_db or pipe_cfg.get("context_db"),
            log_context_snapshots=args.log_context_snapshots
            or pipe_cfg.get("log_context_snapshots", False),
            max_prompt_words=pipe_cfg.get("max_prompt_words", 600),
        )
    except Exception as exc:  # surface airport-context errors with a friendly message
        try:
            from airport_context.live import AirportContextError
        except ImportError:
            AirportContextError = ()  # type: ignore[assignment]
        if isinstance(exc, AirportContextError):
            print(f"\n[airport context] {exc}", file=sys.stderr)
            result = getattr(exc, "result", {}) or {}
            if result.get("error") == "database_empty":
                print("  Build it first:  python -m airport_context.cli ingest", file=sys.stderr)
            for c in (result.get("candidates") or [])[:8]:
                code = c.get("icao") or c.get("faa_lid") or c.get("iata") or "?"
                print(f"  candidate: {code:<6} {c.get('name')}", file=sys.stderr)
            sys.exit(2)
        raise

    pipeline.run(
        max_segments=args.max_segments,
        report_interval=args.report_interval,
        output_json=Path(args.output_json) if args.output_json else None,
    )


if __name__ == "__main__":
    main()
