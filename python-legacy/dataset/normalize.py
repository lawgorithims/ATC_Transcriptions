"""
Transcript normalization + edit-distance metrics for the pseudo-labeling pipeline.

The training transcripts in this project are stored normalized: lowercase, no
punctuation, collapsed whitespace, with the English articles ("a"/"an"/"the")
removed (the same normalization the gitignored ``compute_normalized_wer.py`` /
``atc_normalization.py`` apply before WER). To guarantee the pseudo-labels match
that format exactly, we PREFER the canonical normalizer when it is importable and
only fall back to the local implementation below when it is not (e.g. on a fresh
checkout where the training scripts — which are gitignored — are absent).

The CER/WER helpers are pure-stdlib Levenshtein so the consensus filter needs no
``jiwer`` dependency; they operate on already-normalized text.
"""

from __future__ import annotations

import re
from typing import Callable, List, Optional

# Articles dropped during normalization (matches the project's WER normalization).
_ARTICLES = {"a", "an", "the"}


def _local_normalize(text: str) -> str:
    """Lowercase, strip punctuation, drop articles, collapse whitespace."""
    text = (text or "").lower()
    # Keep alphanumerics and spaces; everything else becomes a space.
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    tokens = [t for t in text.split() if t and t not in _ARTICLES]
    return " ".join(tokens)


def _resolve_canonical() -> Optional[Callable[[str], str]]:
    """Return the project's canonical normalizer if it can be imported, else None.

    The canonical implementation lives in the (gitignored, local-only) training
    tooling. We probe a couple of likely symbol names and fall back gracefully.
    """
    try:  # pragma: no cover - depends on local-only files being present
        import atc_normalization as _an  # type: ignore

        for name in ("normalize_transcript", "normalize_text", "normalize"):
            fn = getattr(_an, name, None)
            if callable(fn):
                return fn
    except Exception:
        pass
    return None


_CANONICAL = _resolve_canonical()


def normalize_transcript(text: str) -> str:
    """Normalize a transcript to the project's training/eval format.

    Uses the canonical normalizer when available (so pseudo-labels are byte-for-byte
    consistent with the existing data); otherwise uses the local fallback.
    """
    if _CANONICAL is not None:  # pragma: no cover
        try:
            return _CANONICAL(text)
        except Exception:
            pass
    return _local_normalize(text)


def using_canonical_normalizer() -> bool:
    """True when the canonical (local-only) normalizer is in use."""
    return _CANONICAL is not None


def _levenshtein(a: List[str], b: List[str]) -> int:
    """Classic O(len(a)*len(b)) edit distance over token/char sequences."""
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(
                min(
                    prev[j] + 1,        # deletion
                    cur[j - 1] + 1,     # insertion
                    prev[j - 1] + (ca != cb),  # substitution
                )
            )
        prev = cur
    return prev[-1]


def char_error_rate(ref: str, hyp: str, *, normalized: bool = False) -> float:
    """Character error rate between two strings, normalized to [0, inf).

    By default both inputs are normalized first (so callers can pass raw decodes).
    Spaces are ignored for the character comparison. Returns 0.0 when both are
    empty and 1.0 when only the reference is empty but the hypothesis is not.
    """
    if not normalized:
        ref, hyp = normalize_transcript(ref), normalize_transcript(hyp)
    ra = list(ref.replace(" ", ""))
    hb = list(hyp.replace(" ", ""))
    if not ra and not hb:
        return 0.0
    if not ra:
        return 1.0
    return _levenshtein(ra, hb) / len(ra)


def word_error_rate(ref: str, hyp: str, *, normalized: bool = False) -> float:
    """Word error rate between two strings (normalized first unless told otherwise)."""
    if not normalized:
        ref, hyp = normalize_transcript(ref), normalize_transcript(hyp)
    ra = ref.split()
    hb = hyp.split()
    if not ra and not hb:
        return 0.0
    if not ra:
        return 1.0
    return _levenshtein(ra, hb) / len(ra)


def agreement_cer(text_a: str, text_b: str) -> float:
    """Symmetric-ish CER used by the consensus filter (normalizes both sides)."""
    return char_error_rate(text_a, text_b)


_NUM_WORDS = {"zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "three": "3",
              "tree": "3", "four": "4", "five": "5", "fife": "5", "six": "6",
              "seven": "7", "eight": "8", "nine": "9", "niner": "9"}


def numeric_canon(text: str) -> str:
    """Canonicalize numbers for CONSENSUS COMPARISON ONLY (never for stored labels):
    map spoken digit words to digits and explode multi-digit tokens so "1408" and
    "one four zero eight" compare equal (ATC reads numbers digit-by-digit)."""
    out = []
    for t in (text or "").split():
        t = _NUM_WORDS.get(t, t)
        for run in re.findall(r"\d+|[a-z]+", t):
            out.extend(list(run)) if run.isdigit() else out.append(run)
    return " ".join(out)


def consensus_cer(a: str, b: str) -> float:
    """CER for the pseudo-label consensus gate: compares number-canonicalized,
    already-normalized text so digit/word spelling differences don't count."""
    return char_error_rate(numeric_canon(a), numeric_canon(b), normalized=True)
