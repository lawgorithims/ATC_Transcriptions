---
license: other
language:
- en
library_name: transformers
pipeline_tag: automatic-speech-recognition
base_model: openai/whisper-large-v3-turbo
tags:
- whisper
- automatic-speech-recognition
- air-traffic-control
- atc
- aviation
metrics:
- wer
- cer
---

# Whisper large-v3-turbo — ATC fine-tune

Fine-tuned [`openai/whisper-large-v3-turbo`](https://huggingface.co/openai/whisper-large-v3-turbo) for **air traffic control (ATC) radio transcription**.

## Results

Held-out validation (2,024 samples, ATCO2 + ATCoSIM), normalized WER/CER (lowercase, punctuation- and article-stripped):

| Model | WER | CER |
|------|:---:|:---:|
| **This model (large-v3-turbo)** | **7.83%** | **3.58%** |
| whisper-small fine-tune (prior) | 12.82% | 9.24% |

≈39% relative WER and ≈61% relative CER reduction vs the small fine-tune — mostly from eliminating hallucinated insertions. Inference is ~2× the small model's latency (still faster than real-time on Apple Silicon / a modern GPU).

## Training

| | |
|---|---|
| Base model | `openai/whisper-large-v3-turbo` (809M params) |
| Data | ATCO2 + ATCoSIM — 8,095 train / 2,024 val (80/20, seed 42), transcripts normalized |
| Recipe | lr 5e-6, effective batch 4, warmup 500, fp16, early-stopping (patience 2) on eval loss |
| Best checkpoint | step 1,100 — eval_loss 0.0975 |
| Hardware | single NVIDIA H100 |

## Usage

```python
import librosa, torch
from transformers import WhisperProcessor, WhisperForConditionalGeneration

repo = "SingularityUS/ATC-whisper-turbo-v1"
processor = WhisperProcessor.from_pretrained(repo, language="en", task="transcribe")
model = WhisperForConditionalGeneration.from_pretrained(repo).eval()

audio, _ = librosa.load("atc_clip.wav", sr=16000)
features = processor(audio, sampling_rate=16000, return_tensors="pt").input_features
with torch.no_grad():
    ids = model.generate(features)
print(processor.batch_decode(ids, skip_special_tokens=True)[0])
```

## Intended use & limitations

For English ATC VHF radio transcription. The validation set is predominantly clean studio-quality audio (ATCoSIM), so real-world noisy-VHF error rates will be higher. Research / non-safety-critical use only.

## License & data

Base model is MIT-licensed (OpenAI Whisper). Training data (ATCO2, ATCoSIM) is subject to its respective licenses; this fine-tune is intended for research use — confirm the applicable terms before any commercial use.
