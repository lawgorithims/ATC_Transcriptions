"""
Record live ATC feeds to disk in 30-min chunks — the Cloudflare-free acquisition path.

LiveATC's archive WEBSITE is behind Cloudflare and gives no guarantee a given block
contains speech. The live Icecast STREAMS, however, sit on edge servers
(d.liveatc.net / sN-*.liveatc.net) that the existing ffmpeg path already pulls
directly — no Cloudflare. So for reliable volume we record currently-active, busy
feeds during busy local hours and keep only chunks that actually contain speech
(via the VAD speech gate).

Pick busy feeds from your airport_configs (and cross-check what's live now on
skylistening.com/liveatc), run during local daytime, and let it loop for hours/days
under tmux or cron. Each kept chunk is written like an archive block so the rest of
the pipeline (segment -> consensus -> label) treats live and archive identically.

Requires ffmpeg on PATH (already a project dependency for the live pipeline).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, List, Optional

from atc_stream import resolve_stream_url

from dataset.archive_downloader import DownloadRecord, _append_manifest, _load_feed
from dataset.speech_gate import speech_yield


def record_feed_chunks(
    feed_config: Path,
    feed_key: str,
    out_dir: Path,
    *,
    n_chunks: int = 1,
    chunk_minutes: float = 30.0,
    min_speech_s: float = 20.0,
    manifest_path: Optional[Path] = None,
    on_chunk: Optional[Callable[[DownloadRecord], None]] = None,
    on_status: Optional[Callable[[str], None]] = None,
) -> List[DownloadRecord]:
    """Record ``n_chunks`` live chunks of a feed, keeping only those with speech.

    Low-yield chunks (silent radio) are deleted to save disk and recorded in the
    manifest as status "low_speech". Kept chunks call ``on_chunk`` so the streaming
    pipeline can segment/label them immediately.
    """
    entry = _load_feed(feed_config, feed_key)
    airport = entry["_airport_code"]
    stream_url = resolve_stream_url(feed_config=Path(feed_config), feed_key=feed_key)
    out_dir = Path(out_dir)
    manifest_path = manifest_path or (out_dir / "downloads.jsonl")
    log = on_status or (lambda _m: None)

    # Imported lazily so the module imports without numpy/soundfile present.
    from dataset.archive_downloader import record_live

    records: List[DownloadRecord] = []
    for i in range(n_chunks):
        block_start = datetime.now(timezone.utc)
        stamp = block_start.strftime("%Y%m%dT%H%MZ")
        date_dir = out_dir / airport / feed_key / block_start.strftime("%Y-%m-%d")
        date_dir.mkdir(parents=True, exist_ok=True)
        dest = date_dir / f"{feed_key}-{stamp}.wav"

        log(f"recording {feed_key} chunk {i + 1}/{n_chunks} ({chunk_minutes:.0f} min)")
        # ADS-B traffic snapshot: capture who is actually around the airport WHILE
        # the block records (live-only data) — it grounds the labeler's callsign
        # snapping later (label_gate.fix_callsign). Fail-soft: no coords/network
        # → empty snapshot, and this changes nothing about recording.
        from dataset.traffic_snapshot import TrafficSnapshotter

        with TrafficSnapshotter(airport) as traffic:
            record_live(stream_url, chunk_minutes * 60.0, dest, on_status=on_status)

        rec = DownloadRecord(
            airport=airport, feed=feed_key, mount=feed_key,
            utc_start=block_start.isoformat(), url=stream_url, path=str(dest),
            bytes=dest.stat().st_size if dest.exists() else 0,
        )

        # Speech gate: drop silent chunks before they reach the GPU.
        import soundfile as sf

        audio, _ = sf.read(str(dest), dtype="float32")
        sy = speech_yield(audio)
        rec.note = f"speech={sy.speech_s:.1f}s/{sy.total_s:.0f}s"
        if sy.speech_s < min_speech_s:
            dest.unlink(missing_ok=True)
            rec.path = ""
            rec.status = "low_speech"
            log(f"  dropped (only {sy.speech_s:.1f}s speech)")
        else:
            rec.status = "ok"
            log(f"  kept ({sy.speech_s:.1f}s speech)")
            snap = traffic.write_snapshot(dest)
            if snap is not None:
                log(f"  traffic snapshot: {len(traffic.codes)} aircraft")

        _append_manifest(manifest_path, rec)
        records.append(rec)
        if rec.status == "ok" and on_chunk is not None:
            try:
                on_chunk(rec)
            except Exception:
                pass
    return records


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Record live ATC feed chunks (Cloudflare-free).")
    ap.add_argument("--feed-config", required=True, type=Path)
    ap.add_argument("--feed", required=True)
    ap.add_argument("--out-dir", default="data/raw_us", type=Path)
    ap.add_argument("--chunks", type=int, default=1)
    ap.add_argument("--minutes", type=float, default=30.0)
    ap.add_argument("--min-speech-s", type=float, default=20.0)
    args = ap.parse_args(argv)

    recs = record_feed_chunks(
        args.feed_config, args.feed, args.out_dir,
        n_chunks=args.chunks, chunk_minutes=args.minutes,
        min_speech_s=args.min_speech_s, on_status=print,
    )
    kept = sum(1 for r in recs if r.status == "ok")
    print(f"Recorded {len(recs)} chunk(s); kept {kept} with speech.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
