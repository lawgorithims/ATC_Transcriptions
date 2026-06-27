"""
Streaming orchestrator: download -> segment -> two-model consensus -> pseudo-labels.

A background thread downloads LiveATC archive blocks; the main thread segments each
finished block and runs the GPU consensus labeler — so transcription starts as soon
as the first block lands and the GPU stays busy while later blocks download.

Run:
    python -m dataset.run_pipeline --config dataset/config.yaml
    python -m dataset.run_pipeline --config dataset/config.yaml --summary   # just print score stats

Models are loaded once (teacher A + partner B). Everything else is config-driven.
"""

from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

import yaml

from atc_context import ATCContext
from atc_corrector import DeterministicCorrector

from dataset import bulk_capture, emit_metadata
from dataset.archive_downloader import DEFAULT_ARCHIVE_TEMPLATE, download_archive_range
from dataset.pseudo_label import FilterThresholds, evaluate_segment


@dataclass
class FeedJob:
    """A feed to harvest, with its precomputed prompt + corrector."""

    airport_config: Path
    feed_key: str
    airport_code: str
    prompt: str
    corrector: Optional[DeterministicCorrector]


def _parse_dt(s: str) -> datetime:
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(str(s), fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(f"Bad datetime in config: {s!r}")


def _build_feed_jobs(cfg: dict) -> List[FeedJob]:
    jobs: List[FeedJob] = []
    correction_enabled = (cfg.get("correction") or {}).get("enabled", True)
    for feed in cfg.get("feeds", []):
        config_path = Path(feed["airport_config"])
        for feed_key in feed["feed_keys"]:
            ctx = ATCContext(feed_config=config_path, feed_key=feed_key)
            corrector = (
                DeterministicCorrector(ctx.vocab) if correction_enabled else None
            )
            import json as _json

            airport_code = _json.loads(config_path.read_text(encoding="utf-8")).get(
                "airport_code", config_path.stem.upper()
            )
            jobs.append(FeedJob(
                airport_config=config_path,
                feed_key=feed_key,
                airport_code=airport_code,
                prompt=ctx.build_prompt(),
                corrector=corrector,
            ))
    return jobs


def _thresholds(cfg: dict) -> FilterThresholds:
    t = cfg.get("thresholds") or {}
    base = FilterThresholds()
    for field_name in vars(base):
        if field_name in t:
            setattr(base, field_name, t[field_name])
    return base


@dataclass
class _BlockItem:
    job: FeedJob
    block_path: Path


def run(cfg: dict) -> dict:
    """Execute the streaming pipeline; return a summary of the score audit."""
    from dataset.scored_transcribe import ScoredTranscriber

    acq = cfg.get("acquisition") or {}
    models = cfg.get("models") or {}
    out_root = Path(cfg.get("output_root", "data/us_pseudo"))
    raw_dir = Path(acq.get("out_dir", "data/raw_us"))
    seg_dir = Path(cfg.get("segments_dir", "data/segments"))
    start, end = _parse_dt(acq["start"]), _parse_dt(acq["end"])

    jobs = _build_feed_jobs(cfg)
    thresholds = _thresholds(cfg)
    writer = emit_metadata.MetadataWriter(out_root)

    print(f"Loading teacher A: {models.get('teacher_a', 'openai/whisper-large-v3')}")
    transcriber_a = ScoredTranscriber(
        models.get("teacher_a", "openai/whisper-large-v3"),
        device=models.get("device", "auto"),
        num_beams=int(models.get("num_beams_a", 5)),
    )
    print(f"Loading partner B: {models.get('partner_b', 'models/whisper-atc-turbo')}")
    transcriber_b = ScoredTranscriber(
        models.get("partner_b", "models/whisper-atc-turbo"),
        device=models.get("device", "auto"),
        num_beams=int(models.get("num_beams_b", 1)),
    )

    mode = (acq.get("mode") or "live").lower()       # "live" (Cloudflare-free) or "archive"
    min_block_speech_s = float(acq.get("min_block_speech_s", 0.0))

    def _producer(block_q):
        """Acquire each feed's blocks; enqueue each as it lands."""
        cf = None
        try:
            if mode == "archive" and acq.get("cloudflare"):
                # Lazily open one warmed browser session for the whole run.
                from dataset.cf_session import CloudflareSession

                cf = CloudflareSession(headless=True).__enter__()

            for job in jobs:
                def _on_block(rec, _job=job):
                    block_q.put(_BlockItem(_job, Path(rec.path)))

                if mode == "archive":
                    download_archive_range(
                        job.airport_config, job.feed_key, start, end, raw_dir,
                        manifest_path=out_root / "downloads.jsonl",
                        template=acq.get("template") or DEFAULT_ARCHIVE_TEMPLATE,
                        on_block=_on_block,
                        fetch=(cf.get if cf is not None else None),
                    )
                else:  # live recording (no Cloudflare)
                    from dataset.live_recorder import record_feed_chunks

                    # Optionally probe the feed first and skip it if it's not active
                    # right now (push-to-talk: nothing transmits when there's no traffic).
                    if acq.get("probe_active"):
                        from atc_stream import resolve_stream_url
                        from dataset.feed_prober import probe_stream

                        url = resolve_stream_url(
                            feed_config=job.airport_config, feed_key=job.feed_key
                        )
                        pr = probe_stream(url, seconds=float(acq.get("probe_seconds", 60)))
                        if not (pr.ok and pr.speech_s >= float(acq.get("probe_min_speech_s", 3))):
                            print(f"    skip {job.feed_key}: inactive ({pr.note})")
                            continue
                        print(f"    {job.feed_key} active ({pr.note}) -> recording")

                    record_feed_chunks(
                        job.airport_config, job.feed_key, raw_dir,
                        n_chunks=int(acq.get("chunks_per_feed", 1)),
                        chunk_minutes=float(acq.get("chunk_minutes", 30.0)),
                        min_speech_s=float(acq.get("min_block_speech_s", 20.0)),
                        manifest_path=out_root / "downloads.jsonl",
                        on_chunk=_on_block, on_status=lambda m: print("   ", m),
                    )
        finally:
            if cf is not None:
                cf.__exit__(None, None, None)
            block_q.put(None)  # sentinel

    def harvest_once():
        """One pass over all feeds: acquire (background) + segment/label (here)."""
        block_q: "queue.Queue" = queue.Queue(maxsize=int(acq.get("queue_size", 16)))
        producer = threading.Thread(target=_producer, args=(block_q,), daemon=True)
        producer.start()
        accepted = processed = 0
        while True:
            item = block_q.get()
            if item is None:
                break
            job = item.job
            segments = bulk_capture.segment_block(
                item.block_path, seg_dir, airport=job.airport_code, feed=job.feed_key,
                min_block_speech_s=min_block_speech_s,
            )
            for seg in segments:
                if writer.already_done(seg.seg_id):
                    continue
                import soundfile as sf

                audio, _ = sf.read(seg.audio_path, dtype="float32")
                decision = evaluate_segment(
                    audio,
                    transcriber_a=transcriber_a,
                    transcriber_b=transcriber_b,
                    corrector=job.corrector,
                    context_prompt=job.prompt,
                    thresholds=thresholds,
                )
                row = writer.write(seg, decision)
                processed += 1
                if row is not None:
                    accepted += 1
            print(f"  block {item.block_path.name}: {len(segments)} segs "
                  f"(running: {accepted} accepted / {processed} processed)")
        producer.join(timeout=5)

    # Loop continuously (re-probing + recording each pass) so models stay loaded,
    # or run a single pass. Stop with Ctrl-C / killing the process.
    loop = bool(acq.get("loop"))
    loop_sleep_s = float(acq.get("loop_sleep_s", 30.0))
    pass_n = 0
    while True:
        pass_n += 1
        print(f"\n=== harvest pass {pass_n} ===")
        try:
            harvest_once()
        except KeyboardInterrupt:
            print("Interrupted — stopping.")
            break
        if not loop:
            break
        time.sleep(loop_sleep_s)

    summary = emit_metadata.summarize_scores(writer.scores_path)
    print(f"\nTotals so far: accepted {summary['accepted']} / {summary['total']} segments.")
    print("Reasons:", summary["reasons"])
    return summary


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Streaming US ATC pseudo-labeling pipeline.")
    ap.add_argument("--config", required=True, type=Path)
    ap.add_argument("--summary", action="store_true", help="print score audit and exit")
    args = ap.parse_args(argv)

    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    if args.summary:
        out_root = Path(cfg.get("output_root", "data/us_pseudo"))
        s = emit_metadata.summarize_scores(out_root / "scores.jsonl")
        print(s)
        return 0
    run(cfg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
