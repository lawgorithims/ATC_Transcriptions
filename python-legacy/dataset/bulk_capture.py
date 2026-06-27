"""
Segment a downloaded audio block into per-transmission clips using the existing
WebRTC VAD (``atc_stream.VADSegmenter``).

ATC is push-to-talk, so VAD boundaries (silence between transmissions) align with
speaker turns: one segment ~= one transmission ~= one training example. Segments
are 0.8-12 s, already inside Whisper's 30 s window — no fixed-window slicing.

Unlike the live path, we feed the whole block through the segmenter at FULL SPEED
(no realtime pacing) and pad trailing silence so a final transmission that isn't
followed by silence still gets flushed.

Each segment is written as 16 kHz mono WAV plus a sidecar JSON carrying provenance
(source block, offset, duration) so labels are auditable and the eval set can be
kept disjoint by source block.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List, Optional

import numpy as np

from atc_stream import SAMPLE_RATE, VADSegmenter

# Feed size when pushing a block through the segmenter (full speed). 0.5 s matches
# the live capture chunk size; the value only affects internal batching.
_FEED_CHUNK_S = 0.5


@dataclass
class SegmentRecord:
    """Provenance for one extracted transmission clip."""

    seg_id: str
    audio_path: str
    airport: str
    feed: str
    src_block: str
    offset_s: float
    dur_s: float


def _load_block(path: Path) -> np.ndarray:
    import librosa

    audio, _ = librosa.load(str(path), sr=SAMPLE_RATE, mono=True)
    return audio.astype(np.float32)


def segment_block(
    block_path: Path,
    out_dir: Path,
    *,
    airport: str,
    feed: str,
    vad_aggressiveness: int = 2,
    silence_duration_ms: int = 700,
    min_speech_ms: int = 500,
    max_segment_s: float = 12.0,
    write_sidecar: bool = True,
) -> List[SegmentRecord]:
    """VAD-segment one downloaded block; write clips + sidecars; return records."""
    block_path = Path(block_path)
    audio = _load_block(block_path)
    if audio.size == 0:
        return []

    seg = VADSegmenter(
        aggressiveness=vad_aggressiveness,
        silence_duration_ms=silence_duration_ms,
        min_speech_ms=min_speech_ms,
        max_segment_s=max_segment_s,
    )

    # Pad trailing silence so the last speech run is finalized by the segmenter.
    tail = np.zeros(int((silence_duration_ms / 1000.0 + 0.2) * SAMPLE_RATE), dtype=np.float32)
    audio = np.concatenate([audio, tail])

    chunk = int(_FEED_CHUNK_S * SAMPLE_RATE)
    completed = []
    for start in range(0, len(audio), chunk):
        completed.extend(seg.feed(audio[start : start + chunk]))

    block_id = block_path.stem
    seg_out = Path(out_dir) / airport / feed / block_id
    records: List[SegmentRecord] = []
    if completed:
        seg_out.mkdir(parents=True, exist_ok=True)

    import soundfile as sf

    for idx, s in enumerate(completed):
        seg_id = f"{block_id}__{idx:04d}"
        wav_path = seg_out / f"{idx:04d}.wav"
        sf.write(str(wav_path), s.audio, SAMPLE_RATE)
        rec = SegmentRecord(
            seg_id=seg_id,
            audio_path=str(wav_path),
            airport=airport,
            feed=feed,
            src_block=block_id,
            offset_s=round(float(s.stream_start_s), 3),
            dur_s=round(float(s.stream_end_s - s.stream_start_s), 3),
        )
        records.append(rec)
        if write_sidecar:
            (seg_out / f"{idx:04d}.json").write_text(
                json.dumps(asdict(rec), indent=2), encoding="utf-8"
            )
    return records


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="VAD-segment a downloaded ATC block.")
    ap.add_argument("--block", required=True, type=Path)
    ap.add_argument("--airport", required=True)
    ap.add_argument("--feed", required=True)
    ap.add_argument("--out-dir", default="data/segments", type=Path)
    args = ap.parse_args(argv)

    recs = segment_block(args.block, args.out_dir, airport=args.airport, feed=args.feed)
    print(f"Extracted {len(recs)} transmission(s) from {args.block}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
