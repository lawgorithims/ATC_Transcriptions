"""
Live audio relay for the browser console.

The capture layer (atc_stream.StreamCapture / FileSimulator) already decodes the
live feed to continuous 16 kHz mono PCM for the model — including the silence and
static between transmissions. We *tee* that same PCM here and re-encode it to MP3
on demand so a browser can listen to whatever feed is being transcribed.

Why tee instead of a second pull: it reuses the single upstream connection the
pipeline already holds, so there is no second connection to LiveATC (which may be
rate-limited per IP), no CORS, and no hotlink/referer problems. If transcription
is connected, audio works — the browser hears exactly what the model hears.
"""

from __future__ import annotations

import queue
import shutil
import subprocess
import threading
from typing import Iterator, List, Optional

import numpy as np

SAMPLE_RATE = 16000
# ~32 s of 0.5 s PCM chunks buffered per listener before we drop the oldest.
# A slow/paused listener must never back-pressure the capture thread.
_SUB_MAXLEN = 64


class AudioBroadcaster:
    """Fan continuous PCM (float32 mono 16 kHz) out to MP3 listeners.

    ``publish`` is called from the capture thread and must never block it, so each
    subscriber gets a bounded queue and we drop the oldest chunk when a listener
    can't keep up. Conversion to bytes is skipped entirely when nobody is
    listening, so the relay is zero-cost until a browser opens the audio stream.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._subs: List[queue.Queue] = []

    def subscribe(self) -> "queue.Queue":
        q: queue.Queue = queue.Queue(maxsize=_SUB_MAXLEN)
        with self._lock:
            self._subs.append(q)
        return q

    def unsubscribe(self, q: "queue.Queue") -> None:
        with self._lock:
            if q in self._subs:
                self._subs.remove(q)

    def has_listeners(self) -> bool:
        with self._lock:
            return bool(self._subs)

    def publish(self, pcm: np.ndarray) -> None:
        """Push one PCM chunk to every listener (called from the capture thread)."""
        with self._lock:
            if not self._subs:
                return  # nobody listening -> skip the encode work entirely
            subs = list(self._subs)
        # float32 [-1, 1] -> little-endian s16 PCM, once for all subscribers.
        data = (np.clip(pcm, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
        for q in subs:
            try:
                q.put_nowait(data)
            except queue.Full:
                try:
                    q.get_nowait()  # drop oldest, keep the live edge
                    q.put_nowait(data)
                except (queue.Empty, queue.Full):
                    pass

    def close(self) -> None:
        """End every listener stream with a sentinel (call when a session stops)."""
        with self._lock:
            subs = list(self._subs)
            self._subs.clear()
        for q in subs:
            try:
                q.put_nowait(None)
            except queue.Full:
                pass


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def mp3_chunks(broadcaster: AudioBroadcaster, bitrate: str = "64k") -> Iterator[bytes]:
    """Subscribe to the PCM tee, encode to MP3 with ffmpeg, yield MP3 bytes.

    Returned from a StreamingResponse; Starlette iterates it in a worker thread so
    the blocking reads never touch the event loop. Cleans up ffmpeg and the
    subscription when the client disconnects (GeneratorExit) or the session ends.
    """
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return
    q = broadcaster.subscribe()
    proc = subprocess.Popen(
        [
            ffmpeg, "-hide_banner", "-loglevel", "error",
            "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "pipe:0",
            # mp3 over a non-seekable pipe: disable the Xing TOC (needs a seek-back)
            # and flush each frame so the browser starts playing with low latency.
            "-f", "mp3", "-write_xing", "0", "-b:a", bitrate, "-ac", "1",
            "-flush_packets", "1", "pipe:1",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    def _pump() -> None:
        try:
            while True:
                item = q.get()
                if item is None:
                    break
                try:
                    proc.stdin.write(item)  # type: ignore[union-attr]
                except (BrokenPipeError, OSError, ValueError):
                    break
        finally:
            try:
                proc.stdin.close()  # type: ignore[union-attr]
            except OSError:
                pass

    writer = threading.Thread(target=_pump, daemon=True)
    writer.start()

    out = proc.stdout
    assert out is not None
    try:
        while True:
            chunk = out.read1(4096) if hasattr(out, "read1") else out.read(4096)
            if not chunk:
                break
            yield chunk
    finally:
        broadcaster.unsubscribe(q)
        try:
            q.put_nowait(None)  # unblock the writer thread
        except queue.Full:
            pass
        try:
            proc.kill()
        except OSError:
            pass
