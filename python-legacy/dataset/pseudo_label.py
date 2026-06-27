"""
Consensus + confidence filtering that turns scored decodes into clean pseudo-labels.

The core idea (noisy-student): transcribe each transmission with TWO independent
decoders and keep only the segments where they AGREE at high confidence — no human
in the loop.

  * Model A = the accurate teacher (large-v3, beam search) WITH the airport-context
    prompt. Its text becomes the label (after the deterministic corrector).
  * Model B = a DIFFERENT decode (the fine-tuned ATC turbo, or large-v3 prompt-free).
    Keep B prompt-free so agreement reflects acoustics, not a shared prompt.

A segment is accepted only if ALL gates pass (thresholds are config-tunable on the
eval set). The label is Model A's normalized text after the existing
``DeterministicCorrector`` aligns numbers/callsigns to that feed's real vocabulary.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

from atc_corrector import DeterministicCorrector

import atc_diarize
from dataset import normalize


@dataclass
class FilterThresholds:
    """Acceptance gates for a pseudo-label. Defaults match the plan's starting points."""

    max_cer: float = 0.10           # CER(A, B) — primary agreement gate
    min_avg_logprob: float = -0.55  # decode confidence (Model A)
    max_no_speech_prob: float = 0.30
    max_compression_ratio: float = 2.4
    min_duration_s: float = 0.8
    max_duration_s: float = 12.0
    min_words: int = 2
    max_words: int = 60
    max_corrector_delta: float = 0.30  # large corrector rewrite = red flag
    require_english: bool = True       # only enforced when language is detectable


@dataclass
class LabelDecision:
    """Outcome of evaluating one segment."""

    accepted: bool
    reason: str
    label: str = ""                 # normalized final label (when accepted)
    text_a: str = ""
    text_b: str = ""
    cer: float = 1.0
    avg_logprob: float = 0.0
    no_speech_prob: Optional[float] = None
    compression_ratio: float = 0.0
    corrector_delta: float = 0.0
    role: str = "unknown"
    callsign: Optional[str] = None
    role_confidence: float = 0.0
    metrics: dict = field(default_factory=dict)


def _corrector_delta(raw: str, corrected: str) -> float:
    """How much the deterministic corrector changed the text, as normalized CER."""
    if not corrected or corrected == raw:
        return 0.0
    return normalize.char_error_rate(raw, corrected)


def evaluate_segment(
    audio,
    *,
    transcriber_a,
    transcriber_b,
    corrector: Optional[DeterministicCorrector],
    context_prompt: Optional[str],
    thresholds: FilterThresholds,
    context_for_role=None,
) -> LabelDecision:
    """Decode a segment with both models and decide whether to keep it as a label.

    ``transcriber_a``/``transcriber_b`` are ``ScoredTranscriber`` instances.
    ``corrector`` may be None (then no vocab correction is applied).
    """
    res_a = transcriber_a.transcribe_scored(audio, context=context_prompt)
    res_b = transcriber_b.transcribe_scored(audio, context=None)

    norm_a = normalize.normalize_transcript(res_a.text)
    norm_b = normalize.normalize_transcript(res_b.text)
    cer = normalize.char_error_rate(norm_a, norm_b, normalized=True)
    words = norm_a.split()

    metrics = {
        "cer": round(cer, 4),
        "avg_logprob_a": round(res_a.avg_logprob, 4),
        "avg_logprob_b": round(res_b.avg_logprob, 4),
        "no_speech_prob_a": res_a.no_speech_prob,
        "compression_ratio_a": round(res_a.compression_ratio, 3),
        "duration_s": res_a.duration_s,
        "n_words": len(words),
        "language_a": res_a.language,
        "language_b": res_b.language,
    }

    def reject(reason: str) -> LabelDecision:
        return LabelDecision(
            accepted=False, reason=reason, text_a=res_a.text, text_b=res_b.text,
            cer=cer, avg_logprob=res_a.avg_logprob, no_speech_prob=res_a.no_speech_prob,
            compression_ratio=res_a.compression_ratio, metrics=metrics,
        )

    # --- gates (cheapest / strongest first) ---
    if not norm_a or not norm_b:
        return reject("empty_decode")
    if res_a.duration_s < thresholds.min_duration_s or res_a.duration_s > thresholds.max_duration_s:
        return reject("duration_out_of_range")
    if len(words) < thresholds.min_words or len(words) > thresholds.max_words:
        return reject("word_count_out_of_range")
    if res_a.compression_ratio > thresholds.max_compression_ratio:
        return reject("degenerate_decode")
    if cer > thresholds.max_cer:
        return reject("low_consensus")
    if res_a.avg_logprob < thresholds.min_avg_logprob:
        return reject("low_confidence")
    if (
        res_a.no_speech_prob is not None
        and res_a.no_speech_prob > thresholds.max_no_speech_prob
    ):
        return reject("likely_no_speech")
    if thresholds.require_english and res_b.language not in (None, "en", "english"):
        return reject("non_english")

    # --- final label: Model A text, vocab-corrected, then normalized ---
    final_text = res_a.text
    corrector_delta = 0.0
    if corrector is not None:
        correction = corrector.correct(res_a.text)
        if correction.changed and correction.corrected:
            corrector_delta = _corrector_delta(res_a.text, correction.corrected)
            if corrector_delta > thresholds.max_corrector_delta:
                metrics["corrector_delta"] = round(corrector_delta, 4)
                return reject("excessive_correction")
            final_text = correction.corrected

    label = normalize.normalize_transcript(final_text)
    if not label:
        return reject("empty_after_normalize")

    turn = atc_diarize.classify_turn(label, context_for_role)
    metrics["corrector_delta"] = round(corrector_delta, 4)

    return LabelDecision(
        accepted=True,
        reason="accepted",
        label=label,
        text_a=res_a.text,
        text_b=res_b.text,
        cer=cer,
        avg_logprob=res_a.avg_logprob,
        no_speech_prob=res_a.no_speech_prob,
        compression_ratio=res_a.compression_ratio,
        corrector_delta=corrector_delta,
        role=turn.role,
        callsign=turn.callsign,
        role_confidence=turn.confidence,
        metrics=metrics,
    )
