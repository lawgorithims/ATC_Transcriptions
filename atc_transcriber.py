"""
Lightweight fine-tuned Whisper transcriber for live ATC with optional context prompt.
"""

from __future__ import annotations

from typing import Optional

import numpy as np
import torch
from transformers import WhisperForConditionalGeneration, WhisperProcessor

from audio_preprocessing import AudioPreprocessor


class ATCTranscriber:
    """Fine-tuned Whisper inference for live ATC segments."""

    def __init__(
        self,
        model_path: str = "models/whisper-atc",
        device: str = "auto",
        enable_preprocessing: bool = True,
        aggressive_preprocessing: bool = True,
    ):
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        self.device = device
        self.model_path = model_path

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
            prompt_ids = self.processor.get_prompt_ids(
                context, return_tensors="pt"
            ).input_ids.to(self.device)
            generate_kwargs["prompt_ids"] = prompt_ids

        with torch.no_grad():
            predicted_ids = self.model.generate(input_features, **generate_kwargs)

        return self.processor.batch_decode(
            predicted_ids, skip_special_tokens=True
        )[0].strip()
