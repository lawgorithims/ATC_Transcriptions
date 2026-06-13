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
from typing import List, Optional

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
    ):
        self.stream_url = stream_url
        self.simulate_file = simulate_file
        self.stats = LatencyStats()
        self.records: List[LatencyRecord] = []
        self._result_queue: queue.Queue = queue.Queue()
        self._transcribe_thread: Optional[threading.Thread] = None
        self._running = False
        self._max_segments: Optional[int] = None
        self._segments_done = 0

        self.context = ATCContext(
            feed_config=feed_config,
            feed_key=feed_key,
            max_history=context_history,
        )

        self.transcriber = ATCTranscriber(
            model_path=model_path,
            device=device,
            enable_preprocessing=enable_preprocessing,
            aggressive_preprocessing=aggressive_preprocessing,
        )

        capture_url = str(Path(stream_url).resolve()) if simulate_file else stream_url

        if simulate_file:
            self.capture = FileSimulator(
                capture_url, chunk_duration_s=0.5, realtime=not fast_simulate
            )  # type: ignore[assignment]
        else:
            self.capture = StreamCapture(
                capture_url,
                chunk_duration_s=0.5,
                on_status=self._status,
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
        capture_to_text_ms = (t1 - segment.finalized_wall_time) * 1000.0
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
            record = self._transcribe_segment(segment)
            if record:
                self._result_queue.put(record)

    def run(
        self,
        max_segments: Optional[int] = None,
        report_interval: int = 10,
        output_json: Optional[Path] = None,
    ) -> None:
        print("=" * 72)
        print("LIVE ATC TRANSCRIPTION PIPELINE")
        print("=" * 72)
        print(f"  Feed:   {self.stream_url}")
        if self.simulate_file:
            mode = "fast replay" if getattr(self.capture, "realtime", True) is False else "real-time replay"
            print(f"  Mode:   offline simulation ({mode})")
        print(f"  Model:  whisper-atc (with context)")
        print(f"  Device: {self.transcriber.device}")
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
                segment = self.producer.queue.get(timeout=0.5)
                if segment is None:
                    self._status("Stream producer stopped.")
                    break
                self._segment_queue.put(segment)

                while True:
                    try:
                        record = self._result_queue.get_nowait()
                    except queue.Empty:
                        break
                    self._handle_record(record, report_interval)

                if max_segments and self._segments_done >= max_segments:
                    print(f"\nReached --max-segments {max_segments}. Stopping.")
                    break

            self._segment_queue.put(None)
            if self._transcribe_thread:
                self._transcribe_thread.join(timeout=120)

            while True:
                try:
                    record = self._result_queue.get_nowait()
                except queue.Empty:
                    break
                self._handle_record(record, report_interval)
                if max_segments and self._segments_done >= max_segments:
                    break

        except KeyboardInterrupt:
            print("\n\nStopping pipeline...")
        finally:
            self._running = False
            self.producer.stop()
            self._print_summary()
            if output_json:
                self._save_json(output_json)

    def _handle_record(self, record: LatencyRecord, report_interval: int) -> None:
        self.records.append(record)
        self.stats.add(record)
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
    )

    pipeline.run(
        max_segments=args.max_segments,
        report_interval=args.report_interval,
        output_json=Path(args.output_json) if args.output_json else None,
    )


if __name__ == "__main__":
    main()
