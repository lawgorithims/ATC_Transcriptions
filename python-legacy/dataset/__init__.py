"""
US ATC training-data creation pipeline (pseudo-labeling on real LiveATC audio).

This package builds meaningful, US-representative labeled training data WITHOUT
hand transcription, by:

  1. downloading real US ATC audio from LiveATC (archive blocks / live record) to
     local disk first (``archive_downloader``),
  2. segmenting it into per-transmission clips with the existing VAD
     (``bulk_capture``),
  3. transcribing each clip with TWO models and keeping only the segments they
     AGREE on at high confidence (``scored_transcribe`` + ``pseudo_label``),
  4. emitting the kept segments as training metadata in the existing
     ``train_metadata.json`` shape (``emit_metadata``),

with a streaming orchestrator (``run_pipeline``) that transcribes blocks as soon
as they finish downloading, and a role-attribution layer (``atc_diarize``, at the
repo top level) that puts each speaker — controller vs pilot — on its own line.

Everything here imports the existing ``python-legacy`` modules rather than
reimplementing them. Captured audio is for LOCAL training use only; see README.
"""

__all__ = [
    "normalize",
    "archive_downloader",
    "bulk_capture",
    "scored_transcribe",
    "pseudo_label",
    "emit_metadata",
    "eval_set",
]
