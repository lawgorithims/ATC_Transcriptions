"""
Cheap speech-yield gate: decide whether an audio block is worth transcribing.

LiveATC archive/live blocks are 30 minutes with NO guarantee of content — a block
can be silent radio. Running the GPU consensus on dead air is pure waste, so this
module measures how many seconds of actual speech a block contains using the same
WebRTC VAD the live pipeline uses, and lets callers skip / prune low-yield blocks.

Pure-VAD and fast (no model): a 30-min block is scanned in well under a second.
Falls back to an energy threshold when ``webrtcvad`` isn't installed (mirrors
``atc_stream.VADSegmenter``).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from atc_stream import FRAME_MS, FRAME_SAMPLES, SAMPLE_RATE


@dataclass
class SpeechYield:
    """Result of scanning a block for speech."""

    total_s: float
    speech_s: float

    @property
    def ratio(self) -> float:
        return self.speech_s / self.total_s if self.total_s > 0 else 0.0


def _vad(aggressiveness: int):
    try:
        import webrtcvad

        return webrtcvad.Vad(aggressiveness), True
    except ImportError:
        return None, False


def speech_yield(audio: np.ndarray, aggressiveness: int = 2) -> SpeechYield:
    """Measure seconds of speech in mono 16 kHz ``audio`` via frame-level VAD."""
    audio = np.asarray(audio, dtype=np.float32)
    total_s = len(audio) / SAMPLE_RATE
    vad, use_webrtc = _vad(aggressiveness)
    energy_threshold = 0.012 - (aggressiveness * 0.002)

    speech_frames = 0
    n = len(audio) // FRAME_SAMPLES
    for i in range(n):
        frame = audio[i * FRAME_SAMPLES : (i + 1) * FRAME_SAMPLES]
        if use_webrtc:
            pcm16 = np.clip(frame, -1.0, 1.0)
            pcm16 = (pcm16 * 32767.0).astype(np.int16).tobytes()
            is_speech = vad.is_speech(pcm16, SAMPLE_RATE)
        else:
            is_speech = float(np.sqrt(np.mean(frame * frame))) >= energy_threshold
        if is_speech:
            speech_frames += 1

    return SpeechYield(total_s=total_s, speech_s=speech_frames * FRAME_MS / 1000.0)


def has_enough_speech(audio: np.ndarray, min_speech_s: float, aggressiveness: int = 2) -> bool:
    """True if the block contains at least ``min_speech_s`` seconds of speech."""
    return speech_yield(audio, aggressiveness).speech_s >= min_speech_s
