"""
Lightweight fine-tuned Whisper transcriber for live ATC with optional context prompt.
"""

from __future__ import annotations

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
    ):
        self.device = _resolve_device(device)
        self.model_path = model_path
        # Metal (MPS) lacks a few ops Whisper uses; fall back to CPU per-op
        # instead of crashing. Keep weights in float32 — fp16 is unstable on MPS.
        if self.device == "mps":
            os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

        print(f"Using device: {self.device}")
        print(f"Loading model: {model_path} ...")
        self.processor = WhisperProcessor.from_pretrained(
            model_path, language="en", task="transcribe"
        )
        self.model = WhisperForConditionalGeneration.from_pretrained(model_path)
        self.model.config.forced_decoder_ids = None
        self.model.config.suppress_tokens = []
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
        """Transcribe mono 16 kHz audio with optional context prompt."""
        if self.preprocessor is not None:
            audio = self.preprocessor.preprocess(audio)

        input_features = self.processor(
            audio,
            sampling_rate=16000,
            return_tensors="pt",
        ).input_features.to(self.device)

        generate_kwargs = {}
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
            generate_kwargs["prompt_ids"] = prompt_ids.to(self.device)

        with torch.no_grad():
            predicted_ids = self.model.generate(input_features, **generate_kwargs)

        return self.processor.batch_decode(
            predicted_ids, skip_special_tokens=True
        )[0].strip()
