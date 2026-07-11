"""
Live ATC audio stream capture and voice-activity segmentation.

Uses ffmpeg to decode HTTP/Icecast MP3 streams into mono 16 kHz PCM.
Use --simulate-file for offline testing without ffmpeg.
"""

from __future__ import annotations

import collections
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Deque, Iterator, List, Optional
from urllib.parse import parse_qs, urlparse

import numpy as np

SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = int(SAMPLE_RATE * FRAME_MS / 1000)

LIVEATC_SERVERS = (
    "d.liveatc.net",
    "s1-dfw.liveatc.net",
    "s2-dfw.liveatc.net",
    "s1-bos.liveatc.net",
    "s2-bos.liveatc.net",
    "s1-fpl.liveatc.net",
    "s1-nyc.liveatc.net",
    "s1-lax.liveatc.net",
)


@dataclass
class SpeechSegment:
    """A contiguous speech region extracted from the live stream."""

    audio: np.ndarray
    stream_start_s: float
    stream_end_s: float
    finalized_wall_time: float


def resolve_stream_url(
    stream_url: Optional[str] = None,
    feed_config: Optional[Path] = None,
    feed_key: Optional[str] = None,
    liveatc_page: Optional[str] = None,
) -> str:
    """
    Resolve a playable stream URL from CLI args or airport feed config.

    Priority: explicit stream_url > feed_config[feed_key] > liveatc_page mount.
    """
    if stream_url:
        return _normalize_stream_url(stream_url)

    if feed_config and feed_key:
        import json

        cfg = json.loads(Path(feed_config).read_text(encoding="utf-8"))
        streams = cfg.get("streams") or {}
        if feed_key not in streams:
            available = ", ".join(sorted(streams)) or "(none)"
            raise ValueError(
                f"Feed '{feed_key}' not found in {feed_config}. Available: {available}"
            )
        entry = streams[feed_key]
        url = entry.get("url") or entry.get("stream_url")
        page = entry.get("liveatc_page")
        if url:
            return _normalize_stream_url(url)
        if page:
            return _resolve_liveatc_page(page)

    if liveatc_page:
        return _resolve_liveatc_page(liveatc_page)

    raise ValueError(
        "No stream URL. Pass --stream-url, or --feed-config + --feed, or --liveatc-page."
    )


def _resolve_liveatc_page(page_url: str) -> str:
    mount = _extract_liveatc_mount(page_url)
    if not mount:
        raise ValueError(f"Could not extract LiveATC mount from: {page_url}")
    return f"https://{LIVEATC_SERVERS[0]}/{mount}"


def _normalize_stream_url(url: str) -> str:
    url = url.strip()
    if Path(url).exists():
        return str(Path(url).resolve())
    if "liveatc.net/hlisten" in url or (
        "liveatc.net" in url and "mount=" in url
    ):
        return _resolve_liveatc_page(url)
    if url.startswith("http://") or url.startswith("https://") or url.startswith("file:"):
        return url
    raise ValueError(f"Invalid stream URL: {url}")


def _extract_liveatc_mount(page_url: str) -> Optional[str]:
    parsed = urlparse(page_url)
    qs = parse_qs(parsed.query)
    mounts = qs.get("mount") or qs.get("m")
    if mounts:
        return mounts[0]
    match = re.search(r"mount=([a-z0-9_]+)", page_url, re.I)
    return match.group(1) if match else None


def candidate_stream_urls(url: str) -> List[str]:
    """Return URLs to try, expanding LiveATC mount names across edge servers."""
    if Path(url).exists() or url.startswith("file:"):
        return [url]

    parsed = urlparse(url)
    if parsed.netloc.endswith("liveatc.net") and parsed.path.strip("/"):
        mount = parsed.path.strip("/")
        return [f"https://{host}/{mount}" for host in LIVEATC_SERVERS]

    mount = _extract_liveatc_mount(url)
    if mount and "liveatc.net" in url:
        return [f"https://{host}/{mount}" for host in LIVEATC_SERVERS]

    return [url]


class FileSimulator:
    """Replay a local audio file at live speed without ffmpeg."""

    def __init__(
        self,
        path: str,
        chunk_duration_s: float = 0.5,
        realtime: bool = True,
        on_audio: Optional[Callable[[np.ndarray], None]] = None,
    ):
        import librosa

        self.path = path
        self.chunk_samples = int(chunk_duration_s * SAMPLE_RATE)
        self.realtime = realtime
        # Optional tee of the decoded PCM (e.g. the web server's audio relay).
        self.on_audio = on_audio
        audio, _ = librosa.load(path, sr=SAMPLE_RATE, mono=True)
        self.audio = audio.astype(np.float32)
        self._stream_time_s = 0.0

    @property
    def stream_time_s(self) -> float:
        return self._stream_time_s

    def iter_chunks(self) -> Iterator[np.ndarray]:
        offset = 0
        while offset < len(self.audio):
            t0 = time.perf_counter()
            chunk = self.audio[offset : offset + self.chunk_samples]
            if len(chunk) == 0:
                break
            if len(chunk) < self.chunk_samples:
                chunk = np.pad(chunk, (0, self.chunk_samples - len(chunk)))
            offset += self.chunk_samples
            self._stream_time_s += len(chunk) / SAMPLE_RATE
            if self.on_audio is not None:
                try:
                    self.on_audio(chunk)
                except Exception:  # a listener must never kill the replay
                    pass
            yield chunk
            if self.realtime:
                elapsed = time.perf_counter() - t0
                sleep_s = (self.chunk_samples / SAMPLE_RATE) - elapsed
                if sleep_s > 0:
                    time.sleep(sleep_s)

    def stop(self) -> None:
        pass


class StreamCapture:
    """Decode a live or file-based audio source to mono 16 kHz float32 chunks."""

    def __init__(
        self,
        url: str,
        chunk_duration_s: float = 0.5,
        on_status: Optional[Callable[[str], None]] = None,
        on_audio: Optional[Callable[[np.ndarray], None]] = None,
    ):
        self.url = url
        self.chunk_samples = int(chunk_duration_s * SAMPLE_RATE)
        self.on_status = on_status or (lambda _msg: None)
        # Optional tee of the decoded PCM (e.g. the web server's audio relay).
        self.on_audio = on_audio
        self._proc: Optional[subprocess.Popen] = None
        self._stream_time_s = 0.0
        self._running = False

    @property
    def stream_time_s(self) -> float:
        return self._stream_time_s

    def _find_ffmpeg(self) -> Optional[str]:
        return shutil.which("ffmpeg")

    def _ffmpeg_cmd(self, url: str) -> List[str]:
        is_file = Path(url).exists()
        cmd = [
            self._find_ffmpeg(),
            "-hide_banner",
            "-loglevel",
            "error",
        ]
        if not is_file:
            cmd.extend(
                [
                    "-reconnect",
                    "1",
                    "-reconnect_streamed",
                    "1",
                    "-reconnect_delay_max",
                    "5",
                    # Fail a dead/stalled stream fast: error out after 20s of no I/O instead of
                    # blocking forever (the 54-min-zombie cause). A live feed streams continuous
                    # audio even when the frequency is QUIET, so this never trips on a merely
                    # inactive/silent feed — only on genuinely dead or stalled ones. (microseconds)
                    "-rw_timeout",
                    "20000000",
                    "-user_agent",
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                ]
            )
        else:
            cmd.extend(["-stream_loop", "-1", "-re"])

        cmd.extend(
            [
                "-i",
                url,
                "-f",
                "s16le",
                "-acodec",
                "pcm_s16le",
                "-ac",
                "1",
                "-ar",
                str(SAMPLE_RATE),
                "pipe:1",
            ]
        )
        return cmd

    def iter_chunks(self) -> Iterator[np.ndarray]:
        """Yield float32 mono chunks from the stream. Reconnects on failure."""
        self._running = True
        urls = candidate_stream_urls(self.url)

        while self._running:
            started = False
            for attempt_url in urls:
                ffmpeg = self._find_ffmpeg()
                if not ffmpeg:
                    raise RuntimeError(
                        "ffmpeg not found on PATH. Install ffmpeg and add it to PATH, "
                        "or use --simulate-file for offline testing."
                    )

                self.on_status(f"Connecting: {attempt_url}")
                cmd = self._ffmpeg_cmd(attempt_url)
                cmd[0] = ffmpeg

                try:
                    self._proc = subprocess.Popen(
                        cmd,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        bufsize=self.chunk_samples * 2,
                    )
                except OSError as exc:
                    self.on_status(f"Failed to start ffmpeg: {exc}")
                    continue

                assert self._proc.stdout is not None
                started = True
                byte_buffer = b""

                while self._running:
                    raw = self._proc.stdout.read(self.chunk_samples * 2)
                    if not raw:
                        code = self._proc.poll()
                        err = (self._proc.stderr.read() if self._proc.stderr else b"").decode(
                            "utf-8", errors="replace"
                        )
                        self.on_status(
                            f"Stream ended (code={code}). "
                            f"{err.strip()[:200]}"
                        )
                        break

                    byte_buffer += raw
                    while len(byte_buffer) >= self.chunk_samples * 2:
                        frame_bytes = byte_buffer[: self.chunk_samples * 2]
                        byte_buffer = byte_buffer[self.chunk_samples * 2 :]
                        pcm = np.frombuffer(frame_bytes, dtype=np.int16).astype(np.float32)
                        pcm /= 32768.0
                        self._stream_time_s += len(pcm) / SAMPLE_RATE
                        if self.on_audio is not None:
                            try:
                                self.on_audio(pcm)
                            except Exception:  # a listener must never kill capture
                                pass
                        yield pcm

                if self._proc and self._proc.poll() is None:
                    self._proc.terminate()
                self._proc = None

                if not self._running:
                    return

            if not started:
                raise RuntimeError("Could not connect to any stream URL.")

            self.on_status("Reconnecting in 3s...")
            time.sleep(3)

    def stop(self) -> None:
        self._running = False
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()


class VADSegmenter:
    """Accumulate PCM chunks and emit speech segments using WebRTC VAD."""

    def __init__(
        self,
        aggressiveness: int = 2,
        silence_duration_ms: int = 700,
        min_speech_ms: int = 500,
        max_segment_s: float = 12.0,
        pre_roll_ms: int = 200,
    ):
        self.silence_frames = max(1, silence_duration_ms // FRAME_MS)
        self.min_speech_frames = max(1, min_speech_ms // FRAME_MS)
        self.max_segment_samples = int(max_segment_s * SAMPLE_RATE)
        self.pre_roll_frames = max(0, pre_roll_ms // FRAME_MS)
        self._use_webrtc = True
        self._energy_threshold = 0.012 - (aggressiveness * 0.002)

        try:
            import webrtcvad

            self.vad = webrtcvad.Vad(aggressiveness)
        except ImportError:
            self._use_webrtc = False
            self.vad = None

        self._pending = np.array([], dtype=np.float32)
        self._segment_frames: List[np.ndarray] = []
        self._pre_roll: Deque[np.ndarray] = collections.deque(maxlen=self.pre_roll_frames)
        self._speech_active = False
        self._silence_count = 0
        self._speech_frames = 0
        self._segment_start_s = 0.0
        self._stream_cursor_s = 0.0

    def _is_speech_frame(self, frame: np.ndarray) -> bool:
        if self._use_webrtc and self.vad is not None:
            return self.vad.is_speech(self._frame_bytes(frame), SAMPLE_RATE)
        return float(np.sqrt(np.mean(frame * frame))) >= self._energy_threshold

    def _frame_bytes(self, frame: np.ndarray) -> bytes:
        pcm16 = np.clip(frame, -1.0, 1.0)
        pcm16 = (pcm16 * 32767.0).astype(np.int16)
        return pcm16.tobytes()

    def _finalize(self, end_s: float) -> Optional[SpeechSegment]:
        if self._speech_frames < self.min_speech_frames or not self._segment_frames:
            self._segment_frames = []
            self._speech_frames = 0
            return None

        audio = np.concatenate(self._segment_frames)
        seg = SpeechSegment(
            audio=audio,
            stream_start_s=self._segment_start_s,
            stream_end_s=end_s,
            finalized_wall_time=time.time(),
        )
        self._segment_frames = []
        self._speech_frames = 0
        return seg

    def feed(self, chunk: np.ndarray) -> List[SpeechSegment]:
        """Feed PCM and return any completed speech segments."""
        self._pending = np.concatenate([self._pending, chunk])
        completed: List[SpeechSegment] = []

        while len(self._pending) >= FRAME_SAMPLES:
            frame = self._pending[:FRAME_SAMPLES]
            self._pending = self._pending[FRAME_SAMPLES:]
            frame_start_s = self._stream_cursor_s
            self._stream_cursor_s += FRAME_SAMPLES / SAMPLE_RATE

            is_speech = self._is_speech_frame(frame)

            if is_speech:
                if not self._speech_active:
                    self._speech_active = True
                    self._segment_start_s = max(
                        0.0, frame_start_s - self.pre_roll_frames * FRAME_MS / 1000.0
                    )
                    self._segment_frames = list(self._pre_roll)
                self._segment_frames.append(frame)
                self._speech_frames += 1
                self._silence_count = 0

                if sum(len(f) for f in self._segment_frames) >= self.max_segment_samples:
                    end_s = self._stream_cursor_s
                    seg = self._finalize(end_s)
                    if seg:
                        completed.append(seg)
                    self._speech_active = True
                    self._segment_start_s = end_s
            else:
                self._pre_roll.append(frame)
                if self._speech_active:
                    self._segment_frames.append(frame)
                    self._silence_count += 1
                    if self._silence_count >= self.silence_frames:
                        end_s = self._stream_cursor_s
                        seg = self._finalize(end_s)
                        if seg:
                            completed.append(seg)
                        self._speech_active = False
                        self._silence_count = 0

        return completed


class AsyncSegmentProducer:
    """Background thread: capture -> VAD -> queue segments."""

    def __init__(
        self,
        capture: StreamCapture,
        segmenter: VADSegmenter,
        max_queue: int = 8,
    ):
        import queue

        self.capture = capture
        self.segmenter = segmenter
        self.queue: queue.Queue = queue.Queue(maxsize=max_queue)
        self._thread: Optional[threading.Thread] = None
        self._running = False

    def start(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        try:
            for chunk in self.capture.iter_chunks():
                if not self._running:
                    break
                for seg in self.segmenter.feed(chunk):
                    self.queue.put(seg)
        finally:
            self.queue.put(None)

    def stop(self) -> None:
        self._running = False
        self.capture.stop()
