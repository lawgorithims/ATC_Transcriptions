"""speaker_embed.py — fail-safe ECAPA-TDNN speaker embedding for the live harvest.

``embed(audio)`` returns a 192-dim unit vector as ``list[float]``, or ``None`` if the
embedding stack is unavailable or anything at all goes wrong. It NEVER raises: a missing
speechbrain, a corrupt clip, or an inference error must never break the live collector.

The model loads once, lazily, on the first call; after a load failure the embedder
disables itself so it doesn't retry-thrash on every segment. Enabled simply by having
``speechbrain`` importable in the running interpreter (the offline clustering pass reads
whatever embeddings show up in ``embeddings.jsonl``; segments embedded here are skipped
by the re-embed step).
"""
import os
from typing import List, Optional

import numpy as np

_MODEL = None
_DISABLED = False


def _load():
    global _MODEL, _DISABLED
    if _MODEL is not None or _DISABLED:
        return _MODEL
    try:
        import torch  # noqa: F401
        try:
            from speechbrain.inference.speaker import EncoderClassifier
        except Exception:
            from speechbrain.pretrained import EncoderClassifier
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        _MODEL = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb",
            savedir=os.path.expanduser("~/CommSight/spike-venv/ecapa"),
            run_opts={"device": os.environ.get("SPEAKER_EMBED_DEVICE", "cpu")},
        )
    except Exception:
        _DISABLED = True
        _MODEL = None
    return _MODEL


def available() -> bool:
    """True if the embedder can (probably) run — for diagnostics, never gates safety."""
    return _load() is not None


def embed(audio) -> Optional[List[float]]:
    """16 kHz mono float32 array -> 192-dim unit embedding as list[float], or None."""
    if _DISABLED:
        return None
    try:
        model = _load()
        if model is None:
            return None
        import torch
        wav = np.asarray(audio, dtype="float32")
        if wav.ndim > 1:
            wav = wav.mean(axis=1)
        if wav.size < 400:  # < ~25 ms: too short to embed meaningfully
            return None
        with torch.no_grad():
            e = model.encode_batch(torch.tensor(wav).unsqueeze(0)).squeeze().cpu().numpy()
        norm = float(np.linalg.norm(e))
        if not np.isfinite(norm) or norm == 0.0:
            return None
        return (e / norm).astype("float32").tolist()
    except Exception:
        return None
