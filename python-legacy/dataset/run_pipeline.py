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
import shutil
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


def _check_storage(storage_root: Path) -> None:
    """Ensure the storage root exists, is writable, and report free space.

    Warns loudly if it resolves under the current working directory, which on the
    H100 is the (ephemeral) root disk — data there is lost on instance teardown.
    """
    storage_root = Path(storage_root)
    storage_root.mkdir(parents=True, exist_ok=True)
    probe = storage_root / ".write_test"
    try:
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        raise RuntimeError(f"storage_root {storage_root} is not writable: {exc}")
    free_gb = shutil.disk_usage(storage_root).free / 1e9
    resolved = storage_root.resolve()
    print(f"Storage: {resolved}  (free {free_gb:.1f} GB)")
    if Path.cwd() in resolved.parents or resolved == Path.cwd():
        print("  WARNING: storage_root is on the working dir / root disk — this is "
              "EPHEMERAL on the H100. Point storage_root at a mounted block volume "
              "(e.g. /mnt/atc-data) so training data survives instance teardown.")
    if free_gb < 10:
        print(f"  WARNING: only {free_gb:.1f} GB free — raw audio fills fast (~0.5 GB/feed-hour).")


@dataclass
class _BlockItem:
    job: FeedJob
    block_path: Path


def run(cfg: dict) -> dict:
    """Execute the streaming pipeline; return a summary of the score audit."""
    from dataset.scored_transcribe import ScoredTranscriber

    acq = cfg.get("acquisition") or {}
    models = cfg.get("models") or {}
    # All outputs live under storage_root — point this at a PERSISTENT block volume
    # on the H100 so the data survives instance teardown (root disk is ephemeral).
    storage_root = Path(cfg.get("storage_root", "data"))
    out_root = Path(cfg.get("output_root") or storage_root / "us_pseudo")
    raw_dir = Path(acq.get("out_dir") or storage_root / "raw_us")
    seg_dir = Path(cfg.get("segments_dir") or storage_root / "segments")
    # start/end only needed for archive mode.
    start = _parse_dt(acq["start"]) if acq.get("start") else None
    end = _parse_dt(acq["end"]) if acq.get("end") else None
    _check_storage(storage_root)

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

            # Shuffle the feed order each pass: sequential real-time recording with a
            # fixed order systematically overweights the first airports in the config
            # (and every supervisor restart begins at the top again).
            import random

            ordered = list(jobs)
            random.shuffle(ordered)
            for job in ordered:
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
        # Airport grounding for the slot label-gate (label_gate.py), resolved once per
        # facility through the provider chain (curated configs -> OurAirports cache).
        # A failed lookup degrades to None -> the gate runs ontology-only checks.
        from airport_data import default_source
        airport_ctx_cache: dict = {}
        ctx_source = default_source(download=False)
        while True:
            item = block_q.get()
            if item is None:
                break
            job = item.job
            # Recording-time ADS-B snapshot for this block (may be absent): the
            # spoken candidates that ground the labeler's callsign snapping.
            from dataset.traffic_snapshot import load_snapshot

            block_traffic = load_snapshot(item.block_path)
            if job.airport_code not in airport_ctx_cache:
                try:
                    airport_ctx_cache[job.airport_code] = ctx_source.airport(job.airport_code)
                except Exception:
                    airport_ctx_cache[job.airport_code] = None
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
                    context_prompt=None,  # teacher prompt-free (verbose airport prompt leaked into labels)
                    thresholds=thresholds,
                    airport_ctx=airport_ctx_cache.get(job.airport_code),
                    callsign_candidates=block_traffic,
                )
                row = writer.write(seg, decision)
                processed += 1
                if row is not None:
                    accepted += 1
                    # P1: fail-safe acoustic speaker embedding for accepted clips, using
                    # the audio array already in memory. Persisted to embeddings.jsonl
                    # (keyed by seg_id) so the offline clustering pass need not re-read
                    # audio. Wrapped so it can NEVER break the collector: any failure
                    # (no speechbrain, bad clip, inference error) just skips the embedding.
                    try:
                        import json as _json
                        from dataset import speaker_embed as _spk
                        _emb = _spk.embed(audio)
                        if _emb is not None:
                            _ep = writer.manifest_path.parent / "embeddings.jsonl"
                            with _ep.open("a", encoding="utf-8") as _fh:
                                _fh.write(_json.dumps({"id": seg.seg_id, "emb": _emb}) + "\n")
                    except Exception:
                        pass
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
        # Keep training-ready metadata fresh after every pass (idempotent).
        try:
            n = emit_metadata.to_train_metadata(
                writer.manifest_path, out_root / "train_metadata.json"
            )
            print(f"  exported {n} examples -> {out_root / 'train_metadata.json'}")
        except Exception as exc:
            print(f"  (train_metadata export skipped: {exc})")
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
