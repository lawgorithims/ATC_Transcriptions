"""
Find which feeds are ACTIVE right now by probing the streams directly.

skylistening.com / LiveATC's status pages are useful for humans, but the most
robust programmatic signal — and one that needs no third-party scraping or
Cloudflare — is to briefly connect to each candidate Icecast stream and measure how
much speech it carries with the same VAD gate the pipeline uses. Active feeds reveal
themselves; dead, wrong, or silent mounts are skipped.

Use it to pick feeds before a recording run, or let ``run_pipeline`` pre-filter
feeds automatically (``acquisition.probe_active: true``).

    python -m dataset.feed_prober --feed-config airport_configs/kdfw.json --seconds 90
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from atc_stream import SAMPLE_RATE, StreamCapture, resolve_stream_url


@dataclass
class ProbeResult:
    feed_key: str
    label: str
    stream_url: str
    ok: bool
    speech_s: float = 0.0
    total_s: float = 0.0
    note: str = ""

    @property
    def speech_ratio(self) -> float:
        return self.speech_s / self.total_s if self.total_s > 0 else 0.0


def probe_stream(stream_url: str, seconds: float = 90.0, connect_timeout: float = 20.0) -> ProbeResult:
    """Connect to a stream for ~``seconds`` and measure speech via VAD.

    Bounded by a hard wall-clock deadline so a stalled/dead feed can't hang the run.
    """
    import numpy as np

    from dataset.speech_gate import speech_yield

    cap = StreamCapture(stream_url)
    target = int(seconds * SAMPLE_RATE)
    box: dict = {"audio": [], "err": None, "grabbed": 0}

    def _run():
        try:
            for chunk in cap.iter_chunks():
                box["audio"].append(chunk)
                box["grabbed"] += len(chunk)
                if box["grabbed"] >= target:
                    break
        except Exception as exc:  # connection / ffmpeg failure
            box["err"] = exc

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    t.join(timeout=seconds + connect_timeout)
    cap.stop()

    if not box["audio"]:
        return ProbeResult(
            feed_key="", label="", stream_url=stream_url, ok=False,
            note=("no audio: " + str(box["err"])[:120]) if box["err"] else "no audio (timeout)",
        )
    audio = np.concatenate(box["audio"])
    sy = speech_yield(audio)
    return ProbeResult(
        feed_key="", label="", stream_url=stream_url, ok=True,
        speech_s=round(sy.speech_s, 1), total_s=round(sy.total_s, 1),
        note=f"{sy.speech_s:.0f}s speech / {sy.total_s:.0f}s",
    )


def probe_config(
    feed_config: Path, seconds: float = 90.0, feed_keys: Optional[List[str]] = None
) -> List[ProbeResult]:
    """Probe every stream in an airport config (or a subset) and return results."""
    cfg = json.loads(Path(feed_config).read_text(encoding="utf-8"))
    streams = cfg.get("streams") or {}
    keys = feed_keys or list(streams)
    results: List[ProbeResult] = []
    for key in keys:
        entry = streams.get(key) or {}
        try:
            url = resolve_stream_url(feed_config=Path(feed_config), feed_key=key)
        except Exception as exc:
            results.append(ProbeResult(key, entry.get("label", key), "", False, note=str(exc)[:120]))
            continue
        res = probe_stream(url, seconds=seconds)
        res.feed_key = key
        res.label = entry.get("label", key)
        res.stream_url = url
        results.append(res)
    return results


def active_feeds(
    results: List[ProbeResult], min_speech_s: float = 5.0
) -> List[ProbeResult]:
    """Filter to feeds that connected and carried at least ``min_speech_s`` of speech,
    ranked by speech seconds (busiest first)."""
    keep = [r for r in results if r.ok and r.speech_s >= min_speech_s]
    return sorted(keep, key=lambda r: r.speech_s, reverse=True)


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Probe ATC feeds for current activity.")
    ap.add_argument("--feed-config", required=True, type=Path)
    ap.add_argument("--seconds", type=float, default=90.0)
    ap.add_argument("--min-speech-s", type=float, default=5.0)
    args = ap.parse_args(argv)

    results = probe_config(args.feed_config, seconds=args.seconds)
    print(f"\nProbed {len(results)} feed(s) in {args.feed_config.name} "
          f"({args.seconds:.0f}s each):\n")
    for r in sorted(results, key=lambda x: (x.ok, x.speech_s), reverse=True):
        mark = "ACTIVE " if (r.ok and r.speech_s >= args.min_speech_s) else "       "
        print(f"  [{mark}] {r.feed_key:32s} {r.note}")
    act = active_feeds(results, args.min_speech_s)
    print(f"\n{len(act)} active feed(s): {[r.feed_key for r in act]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
