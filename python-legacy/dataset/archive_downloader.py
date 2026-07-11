"""
Download real US ATC audio from LiveATC to LOCAL DISK first, then let the rest of
the pipeline process it. Decoupling acquisition from GPU work makes the run
restartable, auditable, and idempotent.

Two sources:
  * ARCHIVE (preferred for bulk): LiveATC keeps ~30 days of 30-minute MP3 blocks
    per mount. ``download_archive_range`` pulls those blocks for a feed over a UTC
    time range.
  * LIVE record (optional): ``record_live`` captures a live stream to disk in
    fixed-length chunks via the existing ``StreamCapture``.

Every downloaded block is written under ``data/raw_us/<airport>/<feed>/<date>/`` and
appended to a ``downloads.jsonl`` manifest (provenance + status) so re-runs skip
what is already present and a crash resumes cleanly.

IMPORTANT (licensing): LiveATC restricts redistribution. Audio fetched here is for
LOCAL model-training use only — do not publish or redistribute raw audio or a
derived audio dataset. See dataset/README.md.
"""

from __future__ import annotations

import hashlib
import json
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator, List, Optional

# Default LiveATC archive URL layout. Blocks are 30 min, named by mount + a
# UTC timestamp, e.g. .../kdfw1_twr1_e/kdfw1_twr1_e-Mar-15-2026-0000Z.mp3
# Overridable via config so a format change needs no code edit.
DEFAULT_ARCHIVE_TEMPLATE = (
    "https://archive.liveatc.net/{mount}/{mount}-{mon}-{day:02d}-{year}-{hhmm}Z.mp3"
)

_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 "
    "(research; local training use)"
)


@dataclass
class DownloadRecord:
    """One row of the downloads.jsonl manifest."""

    airport: str
    feed: str
    mount: str
    utc_start: str          # ISO8601, block start
    url: str
    path: str               # local path (relative to data root) or "" on failure
    bytes: int = 0
    sha256: str = ""
    status: str = "pending"  # "ok" | "missing" | "error" | "skipped"
    note: str = ""


def iter_block_starts(
    start: datetime, end: datetime, step_minutes: int = 30
) -> Iterator[datetime]:
    """Yield UTC block-start datetimes aligned to ``step_minutes`` within [start, end)."""
    if start.tzinfo is None:
        start = start.replace(tzinfo=timezone.utc)
    if end.tzinfo is None:
        end = end.replace(tzinfo=timezone.utc)
    # Align the first block down to the step grid.
    minute = (start.minute // step_minutes) * step_minutes
    cur = start.replace(minute=minute, second=0, microsecond=0)
    delta = timedelta(minutes=step_minutes)
    while cur < end:
        yield cur
        cur += delta


def archive_url(mount: str, block_start: datetime, template: str = DEFAULT_ARCHIVE_TEMPLATE) -> str:
    """Build the archive URL for one 30-minute block."""
    b = block_start.astimezone(timezone.utc)
    return template.format(
        mount=mount,
        mon=b.strftime("%b"),       # "Mar"
        day=b.day,
        year=b.year,
        hhmm=b.strftime("%H%M"),    # "0030"
    )


def _load_feed(feed_config: Path, feed_key: str) -> dict:
    cfg = json.loads(Path(feed_config).read_text(encoding="utf-8"))
    streams = cfg.get("streams") or {}
    if feed_key not in streams:
        available = ", ".join(sorted(streams)) or "(none)"
        raise ValueError(f"Feed '{feed_key}' not in {feed_config}. Available: {available}")
    entry = dict(streams[feed_key])
    entry["_airport_code"] = cfg.get("airport_code") or Path(feed_config).stem.upper()
    return entry


def _existing_manifest_keys(manifest_path: Path) -> set:
    """Return the set of (mount, utc_start) already recorded as ok/skipped."""
    keys = set()
    if not manifest_path.exists():
        return keys
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("status") in ("ok", "skipped"):
            keys.add((row.get("mount"), row.get("utc_start")))
    return keys


def _append_manifest(manifest_path: Path, rec: DownloadRecord) -> None:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with manifest_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(asdict(rec)) + "\n")


def _http_get(url: str, timeout: float = 60.0) -> bytes:
    """GET with the LiveATC-friendly User-Agent. Honors HTTP(S)_PROXY env vars."""
    req = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _status_of(exc: Exception):
    """Best-effort HTTP status from an exception (urllib HTTPError or CloudflareError)."""
    return getattr(exc, "code", None) or getattr(exc, "status", None)


def download_block(
    mount: str,
    block_start: datetime,
    out_dir: Path,
    *,
    airport: str,
    feed: str,
    template: str = DEFAULT_ARCHIVE_TEMPLATE,
    retries: int = 4,
    timeout: float = 60.0,
    fetch=None,
) -> DownloadRecord:
    """Download a single 30-minute archive block, with exponential backoff.

    A 404 means the block simply isn't archived (gaps are normal) -> status
    "missing" (not retried). Network errors retry up to ``retries`` times.

    ``fetch(url, timeout) -> bytes`` overrides the default urllib GET — pass a
    ``CloudflareSession.get`` to fetch through a browser past Cloudflare.
    """
    getter = fetch or _http_get
    url = archive_url(mount, block_start, template)
    stamp = block_start.astimezone(timezone.utc).strftime("%Y%m%dT%H%MZ")
    date_dir = out_dir / airport / feed / block_start.astimezone(timezone.utc).strftime("%Y-%m-%d")
    dest = date_dir / f"{mount}-{stamp}.mp3"
    rec = DownloadRecord(
        airport=airport, feed=feed, mount=mount,
        utc_start=block_start.astimezone(timezone.utc).isoformat(),
        url=url, path="",
    )

    if dest.exists() and dest.stat().st_size > 0:
        rec.path = str(dest)
        rec.bytes = dest.stat().st_size
        rec.status = "skipped"
        rec.note = "file already present"
        return rec

    backoff = 2.0
    for attempt in range(1, retries + 1):
        try:
            data = getter(url, timeout=timeout)
        except Exception as exc:  # urllib.error.* or CloudflareError
            status = _status_of(exc)
            if status == 404:
                rec.status = "missing"
                rec.note = "404 (block not archived)"
                return rec
            rec.status = "error"
            rec.note = (f"HTTP {status}" if status else str(exc)[:200])
            if attempt == retries:
                return rec
        else:
            if not data:
                rec.status = "missing"
                rec.note = "empty body"
                return rec
            date_dir.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            rec.path = str(dest)
            rec.bytes = len(data)
            rec.sha256 = hashlib.sha256(data).hexdigest()
            rec.status = "ok"
            return rec
        time.sleep(backoff)
        backoff *= 2
    return rec


def download_archive_range(
    feed_config: Path,
    feed_key: str,
    start: datetime,
    end: datetime,
    out_dir: Path,
    *,
    manifest_path: Optional[Path] = None,
    template: str = DEFAULT_ARCHIVE_TEMPLATE,
    on_block: Optional[callable] = None,
    fetch=None,
) -> List[DownloadRecord]:
    """Download every 30-min archive block for a feed over [start, end) (UTC).

    Resumable: blocks already marked ok/skipped in the manifest are not re-fetched.
    ``on_block(record)`` is called after each successful download — the streaming
    orchestrator uses this to start segmenting/transcribing immediately.
    ``fetch`` overrides the HTTP getter (e.g. a ``CloudflareSession.get``).
    """
    entry = _load_feed(feed_config, feed_key)
    airport = entry["_airport_code"]
    mount = entry.get("archive_mount") or feed_key
    out_dir = Path(out_dir)
    manifest_path = manifest_path or (out_dir / "downloads.jsonl")
    done = _existing_manifest_keys(manifest_path)

    records: List[DownloadRecord] = []
    for block_start in iter_block_starts(start, end):
        key = (mount, block_start.astimezone(timezone.utc).isoformat())
        if key in done:
            continue
        rec = download_block(
            mount, block_start, out_dir,
            airport=airport, feed=feed_key, template=template, fetch=fetch,
        )
        _append_manifest(manifest_path, rec)
        records.append(rec)
        if rec.status == "ok" and on_block is not None:
            try:
                on_block(rec)
            except Exception:
                # A downstream consumer error must not abort acquisition.
                pass
    return records


def record_live(
    stream_url: str,
    seconds: float,
    out_path: Path,
    *,
    on_status: Optional[callable] = None,
) -> Path:
    """Record a live stream to a 16 kHz mono WAV for ``seconds`` (optional source).

    Uses the existing ``StreamCapture`` (ffmpeg) so it shares the same reconnect /
    mount-fallback behavior as the live pipeline.
    """
    import numpy as np
    import soundfile as sf
    import threading

    from atc_stream import SAMPLE_RATE, StreamCapture

    cap = StreamCapture(stream_url, on_status=on_status or (lambda _m: None))
    collected: List = []
    grabbed = 0
    target = int(seconds * SAMPLE_RATE)
    # Wall-clock deadline: a dead/stalled stream yields no chunks, so the sample-count loop
    # below would block forever (iter_chunks reconnects indefinitely on no data). Force-stop
    # the capture after the intended duration + a margin — cap.stop() terminates ffmpeg, which
    # unblocks the read and ends iter_chunks — so the collector moves to the next (active) feed
    # instead of hanging for hours and holding a 2nd LiveATC connection.
    deadline_s = seconds + max(30.0, 0.2 * seconds)
    guard = threading.Timer(deadline_s, cap.stop)
    guard.daemon = True
    guard.start()
    try:
        for chunk in cap.iter_chunks():
            collected.append(chunk)
            grabbed += len(chunk)
            if grabbed >= target:
                break
    finally:
        guard.cancel()
        cap.stop()

    audio = np.concatenate(collected)[:target] if collected else np.zeros(0, dtype="float32")
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), audio, SAMPLE_RATE)
    return out_path


def _parse_dt(s: str) -> datetime:
    """Parse 'YYYY-MM-DDTHH:MM' or 'YYYY-MM-DD' as UTC."""
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(f"Unrecognized datetime: {s!r} (use YYYY-MM-DDTHH:MM)")


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Download LiveATC archive blocks to disk.")
    ap.add_argument("--feed-config", required=True, type=Path)
    ap.add_argument("--feed", required=True, help="feed key inside the config 'streams'")
    ap.add_argument("--start", required=True, help="UTC start, YYYY-MM-DDTHH:MM")
    ap.add_argument("--end", required=True, help="UTC end, YYYY-MM-DDTHH:MM")
    ap.add_argument("--out-dir", default="data/raw_us", type=Path)
    ap.add_argument("--template", default=DEFAULT_ARCHIVE_TEMPLATE)
    args = ap.parse_args(argv)

    recs = download_archive_range(
        args.feed_config, args.feed, _parse_dt(args.start), _parse_dt(args.end),
        args.out_dir, template=args.template,
    )
    ok = sum(1 for r in recs if r.status == "ok")
    missing = sum(1 for r in recs if r.status == "missing")
    err = sum(1 for r in recs if r.status == "error")
    print(f"Downloaded {ok} block(s); {missing} missing; {err} error(s); "
          f"{len(recs)} attempted (already-present blocks skipped).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
