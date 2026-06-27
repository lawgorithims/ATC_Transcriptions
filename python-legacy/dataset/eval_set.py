"""
Build an honest US evaluation set and score models against it.

The project's existing validation split is ~95% clean European studio audio
(ATCoSIM), so its WER hugely understates real US performance. This module reserves
a small US eval set from a HIGH-CONSENSUS subset of LiveATC — segments where the
two models agree very strongly (strict thresholds) — drawn from feeds/time-windows
kept DISJOINT from training.

Caveat (documented, by design): a consensus-built eval set is model-biased — it
favors segments the models already get right — so treat its WER as a RELATIVE
before/after signal across noisy-student rounds, not an absolute ground truth.
Swap in a small hand-labeled or LDC ATCC eval later for an unbiased number.

Usage:
    # 1) reserve the eval set (uses the cfg['eval'] section: feeds + time window)
    python -m dataset.eval_set build --config dataset/config.yaml
    # 2) score a model (baseline today, fine-tuned later)
    python -m dataset.eval_set score --config dataset/config.yaml \
        --model models/whisper-atc-turbo
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

import yaml

from atc_context import ATCContext
from atc_corrector import DeterministicCorrector

from dataset import bulk_capture, emit_metadata, normalize
from dataset.archive_downloader import download_archive_range
from dataset.pseudo_label import FilterThresholds, evaluate_segment

# Strict gates: eval labels must be near-certain (much tighter than training).
STRICT = FilterThresholds(
    max_cer=0.03,
    min_avg_logprob=-0.35,
    max_no_speech_prob=0.20,
)


def _parse_dt(s: str) -> datetime:
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(str(s), fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(f"Bad datetime: {s!r}")


def build_eval_set(cfg: dict) -> dict:
    """Reserve a strict high-consensus US eval set from the cfg['eval'] section."""
    from dataset.scored_transcribe import ScoredTranscriber

    ev = cfg.get("eval") or {}
    if not ev.get("feeds"):
        raise ValueError("config 'eval' section needs 'feeds', 'start', 'end'.")
    models = cfg.get("models") or {}
    storage_root = Path(cfg.get("storage_root", "data"))
    out_root = Path(ev.get("output_root") or storage_root / "us_eval")
    raw_dir = Path(ev.get("out_dir") or storage_root / "raw_us_eval")
    seg_dir = Path(ev.get("segments_dir") or storage_root / "segments_eval")
    # start/end only needed for archive mode.
    start = _parse_dt(ev["start"]) if ev.get("start") else None
    end = _parse_dt(ev["end"]) if ev.get("end") else None

    transcriber_a = ScoredTranscriber(
        models.get("teacher_a", "openai/whisper-large-v3"),
        device=models.get("device", "auto"),
        num_beams=int(models.get("num_beams_a", 5)),
    )
    transcriber_b = ScoredTranscriber(
        models.get("partner_b", "models/whisper-atc-turbo"),
        device=models.get("device", "auto"),
        num_beams=int(models.get("num_beams_b", 1)),
    )

    writer = emit_metadata.MetadataWriter(out_root)
    excluded_blocks = set()
    # Acquire the same way as training (live = Cloudflare-free) unless told otherwise.
    mode = (ev.get("mode") or (cfg.get("acquisition") or {}).get("mode") or "live").lower()
    min_speech_s = float(ev.get("min_block_speech_s", 20.0))

    for feed in ev["feeds"]:
        config_path = Path(feed["airport_config"])
        airport_code = json.loads(config_path.read_text(encoding="utf-8")).get(
            "airport_code", config_path.stem.upper()
        )
        for feed_key in feed["feed_keys"]:
            ctx = ATCContext(feed_config=config_path, feed_key=feed_key)
            corrector = DeterministicCorrector(ctx.vocab)
            prompt = ctx.build_prompt()
            if mode == "archive":
                recs = download_archive_range(
                    config_path, feed_key, start, end, raw_dir,
                    manifest_path=out_root / "downloads.jsonl",
                )
            else:  # live recording — run this at a different wall-clock time than
                   # training so the eval set stays time-disjoint.
                from dataset.live_recorder import record_feed_chunks

                recs = record_feed_chunks(
                    config_path, feed_key, raw_dir,
                    n_chunks=int(ev.get("chunks_per_feed", 4)),
                    chunk_minutes=float(ev.get("chunk_minutes", 30.0)),
                    min_speech_s=min_speech_s,
                    manifest_path=out_root / "downloads.jsonl",
                    on_status=lambda m: print("   ", m),
                )
            for rec in recs:
                if rec.status not in ("ok", "skipped") or not rec.path:
                    continue
                segments = bulk_capture.segment_block(
                    Path(rec.path), seg_dir, airport=airport_code, feed=feed_key,
                )
                import soundfile as sf

                for seg in segments:
                    if writer.already_done(seg.seg_id):
                        continue
                    audio, _ = sf.read(seg.audio_path, dtype="float32")
                    decision = evaluate_segment(
                        audio,
                        transcriber_a=transcriber_a,
                        transcriber_b=transcriber_b,
                        corrector=corrector,
                        context_prompt=prompt,
                        thresholds=STRICT,
                    )
                    row = writer.write(seg, decision)
                    if row is not None:
                        excluded_blocks.add(seg.src_block)

    # Record which source blocks are reserved for eval so training can exclude them.
    (out_root / "excluded_blocks.txt").write_text(
        "\n".join(sorted(excluded_blocks)) + "\n", encoding="utf-8"
    )
    summary = emit_metadata.summarize_scores(writer.scores_path)
    print(f"Eval set: {summary['accepted']} segments reserved "
          f"from {len(excluded_blocks)} blocks (excluded from training).")
    return summary


def _corpus_wer(refs: List[str], hyps: List[str]) -> float:
    """Corpus WER = total word edits / total reference words."""
    total_edits, total_ref = 0, 0
    for ref, hyp in zip(refs, hyps):
        r, h = ref.split(), hyp.split()
        total_edits += normalize._levenshtein(r, h)
        total_ref += len(r)
    return total_edits / max(1, total_ref)


def _corpus_cer(refs: List[str], hyps: List[str]) -> float:
    total_edits, total_ref = 0, 0
    for ref, hyp in zip(refs, hyps):
        r, h = list(ref.replace(" ", "")), list(hyp.replace(" ", ""))
        total_edits += normalize._levenshtein(r, h)
        total_ref += len(r)
    return total_edits / max(1, total_ref)


def score_model(
    eval_root: Path,
    model_path: str,
    *,
    device: str = "auto",
    use_prompt: bool = False,
) -> dict:
    """Transcribe the eval set with ``model_path`` and report corpus WER/CER.

    By default decodes prompt-free (a fair, context-free accuracy number). The eval
    label is the strict-consensus pseudo-label from ``build_eval_set``.
    """
    from dataset.scored_transcribe import ScoredTranscriber

    rows = emit_metadata.read_manifest(Path(eval_root) / "manifest.jsonl")
    if not rows:
        raise FileNotFoundError(f"No eval manifest under {eval_root}. Run 'build' first.")

    model = ScoredTranscriber(model_path, device=device, num_beams=1)
    import soundfile as sf

    refs, hyps = [], []
    for r in rows:
        audio, _ = sf.read(r["audio_path"], dtype="float32")
        ref = Path(r["transcript_path"]).read_text(encoding="utf-8").strip()
        res = model.transcribe_scored(audio, context=None)
        hyp = normalize.normalize_transcript(res.text)
        refs.append(ref)
        hyps.append(hyp)

    result = {
        "model": model_path,
        "n": len(rows),
        "wer": round(_corpus_wer(refs, hyps), 4),
        "cer": round(_corpus_cer(refs, hyps), 4),
    }
    print(json.dumps(result, indent=2))
    return result


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Build/score the honest US eval set.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="reserve a strict high-consensus US eval set")
    b.add_argument("--config", required=True, type=Path)

    s = sub.add_parser("score", help="score a model against the eval set")
    s.add_argument("--config", required=True, type=Path)
    s.add_argument("--model", required=True)
    s.add_argument("--use-prompt", action="store_true")

    args = ap.parse_args(argv)
    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))

    if args.cmd == "build":
        build_eval_set(cfg)
    elif args.cmd == "score":
        ev = cfg.get("eval") or {}
        storage_root = Path(cfg.get("storage_root", "data"))
        eval_root = Path(ev.get("output_root") or storage_root / "us_eval")
        score_model(
            eval_root,
            args.model,
            device=(cfg.get("models") or {}).get("device", "auto"),
            use_prompt=args.use_prompt,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
