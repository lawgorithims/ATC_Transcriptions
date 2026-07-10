"""
Write accepted pseudo-labels in the project's training-metadata format, plus an
audit trail of every accept/reject decision.

Outputs (under a configurable root, default ``data/us_pseudo/``):

  manifest.jsonl      one row per ACCEPTED example:
                        {id, audio_path, transcript_path, role, callsign, airport,
                         feed, src_block, offset_s, dur_s, cer, avg_logprob}
  transcripts/<id>.txt normalized lowercase-no-punct label (training format)
  scores.jsonl        per-segment audit: every decision + metrics + reason
                        (used to tune thresholds)

``to_train_metadata`` converts the accepted manifest into the existing
``train_metadata.json`` array shape ({id, audio_path, transcript_path}) consumed by
the training/combine scripts.
"""

from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path
from typing import List, Optional

from dataset.bulk_capture import SegmentRecord
from dataset.pseudo_label import LabelDecision


class MetadataWriter:
    """Append-only writer for pseudo-label manifests (crash-resumable)."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.transcripts_dir = self.root / "transcripts"
        self.manifest_path = self.root / "manifest.jsonl"
        self.scores_path = self.root / "scores.jsonl"
        self.root.mkdir(parents=True, exist_ok=True)
        self.transcripts_dir.mkdir(parents=True, exist_ok=True)
        self._seen = self._load_seen()

    def _load_seen(self) -> set:
        """IDs already written to the accepted manifest, so re-runs are idempotent."""
        seen = set()
        if self.manifest_path.exists():
            for line in self.manifest_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    seen.add(json.loads(line)["id"])
                except (ValueError, KeyError):
                    continue
        return seen

    def already_done(self, seg_id: str) -> bool:
        return seg_id in self._seen

    def write(self, seg: SegmentRecord, decision: LabelDecision) -> Optional[dict]:
        """Record one decision. Writes the accepted example (if any) + an audit row.

        Returns the manifest row dict when accepted, else None.
        """
        # Audit row for EVERY segment (accepted or not) -> threshold tuning.
        audit = {
            "id": seg.seg_id,
            "accepted": decision.accepted,
            "reason": decision.reason,
            "text_a": decision.text_a,
            "text_b": decision.text_b,
            "role": decision.role,
            "callsign": decision.callsign,
            "src_block": seg.src_block,
            **decision.metrics,
        }
        with self.scores_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(audit) + "\n")

        if not decision.accepted or seg.seg_id in self._seen:
            return None

        transcript_path = self.transcripts_dir / f"{seg.seg_id}.txt"
        transcript_path.write_text(decision.label + "\n", encoding="utf-8")

        row = {
            "id": seg.seg_id,
            "audio_path": seg.audio_path,
            "transcript_path": str(transcript_path),
            "role": decision.role,
            "callsign": decision.callsign,
            "role_confidence": decision.role_confidence,
            "airport": seg.airport,
            "feed": seg.feed,
            "src_block": seg.src_block,
            "offset_s": seg.offset_s,
            "dur_s": seg.dur_s,
            "cer": round(decision.cer, 4),
            "avg_logprob": round(decision.avg_logprob, 4),
        }
        with self.manifest_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
        self._seen.add(seg.seg_id)
        return row


def read_manifest(manifest_path: Path) -> List[dict]:
    rows = []
    p = Path(manifest_path)
    if not p.exists():
        return rows
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def to_train_metadata(
    manifest_path: Path,
    out_path: Path,
    *,
    tagged_roles: bool = False,
) -> int:
    """Convert manifest.jsonl -> train_metadata.json (existing array shape).

    With ``tagged_roles=True`` a role tag (``<ctrl>``/``<pilot>``) is PREPENDED to a
    copy of each transcript so a future fine-tune can learn to emit the speaker
    label. The tagged transcripts are written next to the originals as ``*.role.txt``
    and referenced instead — kept separate so the clean ASR variant is untouched.

    Blocks listed in ``excluded_blocks_gold.txt`` at the storage root (written by
    ``dataset/gold_builder.py``) are SKIPPED: gold-verification source blocks must
    never become training data.
    """
    rows = read_manifest(manifest_path)
    # Tier-2 acoustic speaker labels: optional sidecar written offline by
    # dataset/atc_speaker_cluster.py; joined by segment id when present (absent -> None).
    spk_path = Path(manifest_path).parent / "speaker_clusters.jsonl"
    speakers = {}
    if spk_path.exists():
        for _line in spk_path.read_text(encoding="utf-8").splitlines():
            if _line.strip():
                _s = json.loads(_line)
                speakers[_s["id"]] = _s
    excl_path = Path(manifest_path).resolve().parent.parent / "excluded_blocks_gold.txt"
    excluded = (set(excl_path.read_text(encoding="utf-8").splitlines())
                if excl_path.exists() else set())
    n_excluded = 0
    out_rows = []
    for r in rows:
        if r.get("src_block") in excluded:
            n_excluded += 1
            continue
        transcript_path = r["transcript_path"]
        if tagged_roles:
            role = r.get("role") or "unknown"
            tag = {"controller": "<ctrl>", "pilot": "<pilot>"}.get(role, "<spk>")
            src = Path(transcript_path)
            text = src.read_text(encoding="utf-8").strip()
            tagged = src.with_suffix(".role.txt")
            tagged.write_text(f"{tag} {text}\n", encoding="utf-8")
            transcript_path = str(tagged)
        sp = speakers.get(r["id"], {})
        out_rows.append({
            "id": r["id"],
            "audio_path": r["audio_path"],
            "transcript_path": transcript_path,
            # Tier-1 content attribution (passthrough from the manifest row) + Tier-2
            # acoustic speaker cluster (from the optional speaker_clusters.jsonl sidecar).
            # Consumers that only need audio/transcript ignore these extra keys.
            "role": r.get("role"),
            "callsign": r.get("callsign"),
            "role_confidence": r.get("role_confidence"),
            "speaker_id": sp.get("speaker_id"),
            "speaker_role_affinity": sp.get("speaker_role_affinity"),
        })
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text(json.dumps(out_rows, indent=2), encoding="utf-8")
    if n_excluded:
        print(f"to_train_metadata: {n_excluded} rows in gold-excluded blocks skipped")
    return len(out_rows)


def summarize_scores(scores_path: Path) -> dict:
    """Aggregate accept/reject reasons from scores.jsonl for a quick health check."""
    counts: dict = {}
    total = 0
    accepted = 0
    p = Path(scores_path)
    if not p.exists():
        return {"total": 0, "accepted": 0, "reasons": {}}
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        total += 1
        if row.get("accepted"):
            accepted += 1
        reason = row.get("reason", "?")
        counts[reason] = counts.get(reason, 0) + 1
    return {"total": total, "accepted": accepted, "reasons": counts}
