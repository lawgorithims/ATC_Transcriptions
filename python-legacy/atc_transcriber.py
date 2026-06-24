"""
Lightweight fine-tuned Whisper transcriber for live ATC with optional context prompt.
"""

from __future__ import annotations

import gzip
import os
from typing import Optional

import numpy as np
import torch
from transformers import WhisperForConditionalGeneration, WhisperProcessor

from audio_preprocessing import AudioPreprocessor

# Whisper shares a single 448-token decoder window between the prompt and the
# generated text. If the prompt fills it, generation has no room and transformers
# raises ("max_new_tokens is 0"). Cap the prompt well below 448 so every segment
# always has room to decode, regardless of how long a context the caller passes.
MAX_PROMPT_TOKENS = 220


def _compression_ratio(text: str) -> float:
    """gzip compression ratio of `text` — Whisper's degeneracy signal.

    A repetition loop ("runway three right runway three right ...") compresses
    far better than natural speech, so a high ratio is a reliable tell. This is
    the same heuristic OpenAI's reference decoder uses (default threshold 2.4):
    normal ATC transmissions sit around 1.0–1.8; a stuck loop is well above 2.4.
    Returns 0.0 for empty/very short text (nothing to judge).
    """
    if not text:
        return 0.0
    data = text.encode("utf-8")
    if len(data) < 16:  # too short for the ratio to mean anything
        return 0.0
    return len(data) / max(1, len(gzip.compress(data)))


def _resolve_device(device: str) -> str:
    """Resolve 'auto' to the best available backend: CUDA, then Apple MPS, then CPU."""
    if device != "auto":
        return device
    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


class ATCTranscriber:
    """Fine-tuned Whisper inference for live ATC segments."""

    def __init__(
        self,
        model_path: str = "models/whisper-atc",
        device: str = "auto",
        enable_preprocessing: bool = True,
        aggressive_preprocessing: bool = True,
        language: str = "en",
        anti_repetition: bool = True,
        compression_ratio_threshold: float = 2.4,
        retry_temperature: float = 0.4,
        retry_repetition_penalty: float = 1.3,
        retry_no_repeat_ngram_size: int = 4,
    ):
        self.device = _resolve_device(device)
        self.model_path = model_path
        # Decode-quality controls. The first decode pass is left exactly as before
        # (greedy, no penalties) so clean-audio accuracy/WER is unchanged; these
        # only govern language pinning and the degenerate-decode retry below.
        self.language = language
        self.anti_repetition = anti_repetition
        self.compression_ratio_threshold = float(compression_ratio_threshold)
        self.retry_temperature = float(retry_temperature)
        self.retry_repetition_penalty = float(retry_repetition_penalty)
        self.retry_no_repeat_ngram_size = int(retry_no_repeat_ngram_size)
        # Metal (MPS) lacks a few ops Whisper uses; fall back to CPU per-op
        # instead of crashing. Keep weights in float32 — fp16 is unstable on MPS.
        if self.device == "mps":
            os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

        print(f"Using device: {self.device}")
        print(f"Loading model: {model_path} ...")
        self.processor = WhisperProcessor.from_pretrained(
            model_path, language=language, task="transcribe"
        )
        self.model = WhisperForConditionalGeneration.from_pretrained(model_path)
        # generate() reads forced_decoder_ids from generation_config, NOT model.config.
        # The fine-tuned config ships forced_decoder_ids with the LANGUAGE slot left
        # null (auto-detect), which lets noisy audio decode as another language. Clear
        # it on BOTH so we can pin language=en/task=transcribe per call (see transcribe).
        self.model.config.forced_decoder_ids = None
        self.model.config.suppress_tokens = []
        self.model.generation_config.forced_decoder_ids = None
        self.model = self.model.to(self.device)
        self.model.eval()
        print("[OK] Model loaded")

        self.preprocessor = (
            AudioPreprocessor(sample_rate=16000, aggressive_radio=aggressive_preprocessing)
            if enable_preprocessing
            else None
        )

    def transcribe(
        self,
        audio: np.ndarray,
        context: Optional[str] = None,
    ) -> str:
        """Transcribe mono 16 kHz audio with optional context prompt.

        Returns the transcript, or "" when the decode is degenerate (a stuck
        repetition loop) and a retry can't recover it — the caller should treat
        an empty result as "nothing usable for this segment" and skip it.
        """
        if self.preprocessor is not None:
            audio = self.preprocessor.preprocess(audio)

        input_features = self.processor(
            audio,
            sampling_rate=16000,
            return_tensors="pt",
        ).input_features.to(self.device)

        # Pin the language/task per call. Pinning is necessary because we cleared
        # forced_decoder_ids (see __init__): without it, generate() would
        # auto-detect the language and drift to non-English on low-SNR audio.
        base_kwargs: dict = {"language": self.language, "task": "transcribe"}
        context = (context or "").strip()
        if context:
            # get_prompt_ids returns a bare tensor on recent transformers (5.x)
            # and a BatchEncoding with .input_ids on older ones. Handle both.
            prompt_ids = self.processor.get_prompt_ids(context, return_tensors="pt")
            if hasattr(prompt_ids, "input_ids"):
                prompt_ids = prompt_ids.input_ids
            # Keep the prompt within budget so decoding always has room (see above).
            if prompt_ids.shape[-1] > MAX_PROMPT_TOKENS:
                prompt_ids = prompt_ids[..., :MAX_PROMPT_TOKENS]
            base_kwargs["prompt_ids"] = prompt_ids.to(self.device)

        # First pass: unchanged greedy decode (keeps clean-audio WER identical).
        text = self._generate(input_features, base_kwargs)

        # Degenerate-decode guard. Bare greedy Whisper on clipped/noisy radio can
        # lock into a repetition loop ("runway three right" x60). Such output
        # gzip-compresses far better than speech, so if it trips the threshold we
        # re-roll ONCE with sampling + anti-repetition penalties; if it's still
        # degenerate we drop it (return "") rather than emit the garbage.
        if self.anti_repetition and _compression_ratio(text) > self.compression_ratio_threshold:
            retry_kwargs = dict(
                base_kwargs,
                do_sample=True,
                temperature=self.retry_temperature,
                repetition_penalty=self.retry_repetition_penalty,
                no_repeat_ngram_size=self.retry_no_repeat_ngram_size,
            )
            retry = self._generate(input_features, retry_kwargs)
            text = retry if _compression_ratio(retry) <= self.compression_ratio_threshold else ""

        return text

    def _generate(self, input_features, generate_kwargs: dict) -> str:
        with torch.no_grad():
            predicted_ids = self.model.generate(input_features, **generate_kwargs)
        return self.processor.batch_decode(
            predicted_ids, skip_special_tokens=True
        )[0].strip()
