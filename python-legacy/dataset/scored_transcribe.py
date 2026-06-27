"""
Confidence-scored Whisper decoding for the pseudo-labeling consensus filter.

``ATCTranscriber.transcribe`` returns ONLY text, so it can't drive a confidence
filter. ``ScoredTranscriber`` adds a decode path that also returns:

  * ``avg_logprob``       — mean per-token log-probability (decode confidence)
  * ``compression_ratio`` — gzip degeneracy signal (reuses atc_transcriber._compression_ratio)
  * ``no_speech_prob``    — P(<|nospeech|>) at the first decoder step (best-effort; None if
                            the running transformers build doesn't expose the token)
  * ``language``          — detected language (best-effort; None if unavailable)

It reuses the project's ``AudioPreprocessor`` and mirrors ``ATCTranscriber``'s
language pinning + forced_decoder_ids handling so decode quality matches the live
path. Beam search is supported (``num_beams``) since accuracy — not latency —
matters for a teacher/labeler and the H100/L40S can afford it.

For higher throughput you can later swap the backend to faster-whisper/CTranslate2
or WhisperX with the same weights; the returned fields are the contract.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import numpy as np
import torch
from transformers import WhisperForConditionalGeneration, WhisperProcessor

from atc_transcriber import MAX_PROMPT_TOKENS, _compression_ratio, _resolve_device
from audio_preprocessing import AudioPreprocessor

SAMPLE_RATE = 16000

# Candidate special-token spellings for the "no speech" token across Whisper
# checkpoints / transformers versions.
_NO_SPEECH_TOKENS = ("<|nospeech|>", "<|nocaptions|>")


@dataclass
class ScoredResult:
    """A scored decode of one audio segment."""

    text: str
    avg_logprob: float
    compression_ratio: float
    no_speech_prob: Optional[float]
    language: Optional[str]
    n_tokens: int
    duration_s: float


class ScoredTranscriber:
    """Whisper inference that returns text AND decode-confidence signals."""

    def __init__(
        self,
        model_path: str,
        device: str = "auto",
        language: str = "en",
        num_beams: int = 5,
        enable_preprocessing: bool = True,
        aggressive_preprocessing: bool = True,
    ):
        self.device = _resolve_device(device)
        self.language = language
        self.num_beams = int(num_beams)
        self.processor = WhisperProcessor.from_pretrained(
            model_path, language=language, task="transcribe"
        )
        self.model = WhisperForConditionalGeneration.from_pretrained(model_path)
        # Mirror ATCTranscriber: clear forced_decoder_ids so we can pin per call.
        self.model.config.forced_decoder_ids = None
        self.model.config.suppress_tokens = []
        self.model.generation_config.forced_decoder_ids = None
        self.model = self.model.to(self.device)
        self.model.eval()
        self.preprocessor = (
            AudioPreprocessor(sample_rate=SAMPLE_RATE, aggressive_radio=aggressive_preprocessing)
            if enable_preprocessing
            else None
        )
        self._no_speech_id = self._resolve_no_speech_id()

    def _resolve_no_speech_id(self) -> Optional[int]:
        tok = self.processor.tokenizer
        unk = getattr(tok, "unk_token_id", None)
        for name in _NO_SPEECH_TOKENS:
            try:
                tid = tok.convert_tokens_to_ids(name)
            except Exception:
                tid = None
            if tid is not None and tid != unk and tid >= 0:
                return int(tid)
        # Some generation configs expose it directly.
        gid = getattr(self.model.generation_config, "no_speech_token_id", None)
        return int(gid) if isinstance(gid, int) else None

    def _input_features(self, audio: np.ndarray) -> torch.Tensor:
        if self.preprocessor is not None:
            audio = self.preprocessor.preprocess(audio)
        feats = self.processor(
            audio, sampling_rate=SAMPLE_RATE, return_tensors="pt"
        ).input_features.to(self.device)
        return feats

    def _prompt_ids(self, context: Optional[str]) -> Optional[torch.Tensor]:
        context = (context or "").strip()
        if not context:
            return None
        prompt_ids = self.processor.get_prompt_ids(context, return_tensors="pt")
        if hasattr(prompt_ids, "input_ids"):
            prompt_ids = prompt_ids.input_ids
        if prompt_ids.shape[-1] > MAX_PROMPT_TOKENS:
            prompt_ids = prompt_ids[..., :MAX_PROMPT_TOKENS]
        return prompt_ids.to(self.device)

    def _no_speech_prob(self, input_features: torch.Tensor) -> Optional[float]:
        """P(no-speech) read at the first decoder position. Best-effort."""
        if self._no_speech_id is None:
            return None
        try:
            start = self.model.config.decoder_start_token_id
            dec = torch.tensor([[start]], device=self.device)
            with torch.no_grad():
                logits = self.model(
                    input_features=input_features, decoder_input_ids=dec
                ).logits[0, -1]
            probs = torch.softmax(logits.float(), dim=-1)
            return float(probs[self._no_speech_id].item())
        except Exception:
            return None

    def transcribe_scored(
        self, audio: np.ndarray, context: Optional[str] = None
    ) -> ScoredResult:
        """Decode one mono 16 kHz segment, returning text + confidence signals."""
        duration_s = float(len(audio)) / SAMPLE_RATE
        input_features = self._input_features(audio)

        gen_kwargs: dict = {
            "language": self.language,
            "task": "transcribe",
            "num_beams": self.num_beams,
            "return_dict_in_generate": True,
            "output_scores": True,
        }
        prompt_ids = self._prompt_ids(context)
        if prompt_ids is not None:
            gen_kwargs["prompt_ids"] = prompt_ids

        with torch.no_grad():
            out = self.model.generate(input_features, **gen_kwargs)

        sequences = out.sequences
        text = self.processor.batch_decode(sequences, skip_special_tokens=True)[0].strip()

        avg_logprob, n_tokens = self._avg_logprob(out)
        return ScoredResult(
            text=text,
            avg_logprob=avg_logprob,
            compression_ratio=_compression_ratio(text),
            no_speech_prob=self._no_speech_prob(input_features),
            language=self._detect_language(input_features),
            n_tokens=n_tokens,
            duration_s=round(duration_s, 3),
        )

    def _avg_logprob(self, out) -> tuple:
        """Mean per-token log-prob over the generated tokens (batch size 1)."""
        try:
            beam_indices = getattr(out, "beam_indices", None)
            transition = self.model.compute_transition_scores(
                out.sequences, out.scores, beam_indices, normalize_logits=True
            )
            row = transition[0]
            # Drop -inf / nan padding positions (post-EOS in beam search).
            finite = row[torch.isfinite(row)]
            if finite.numel() == 0:
                return 0.0, 0
            return float(finite.mean().item()), int(finite.numel())
        except Exception:
            return 0.0, 0

    def _detect_language(self, input_features: torch.Tensor) -> Optional[str]:
        """Best-effort language detection; returns an ISO code or None."""
        detect = getattr(self.model, "detect_language", None)
        if not callable(detect):
            return None
        try:
            with torch.no_grad():
                lang_ids = detect(input_features)
            tok = self.processor.tokenizer
            token = tok.convert_ids_to_tokens(int(lang_ids[0]))
            # token looks like "<|en|>"
            return token.strip("<|>") if token else None
        except Exception:
            return None
