# Fine-tuned Models

## whisper-atc

Whisper-small fine-tuned on the combined ATCO2 + ATCoSIM training set (8,095 samples).

```
whisper-atc/
├── model.safetensors          # Final trained weights (~922 MB) — NOT in git; auto-downloaded on install
├── config.json                # Model config
├── tokenizer.json             # Tokenizer
├── checkpoint-2200/           # Training checkpoint (local only, gitignored)
└── checkpoint-2400/           # Training checkpoint (local only, gitignored)
```

Total size: ~6.3 GB (checkpoints include optimizer state).

Training checkpoints are safe to remove once satisfied with the final model.
The root-level `model.safetensors` is what inference scripts load by default.

## Download weights

Weights are **not in git**. After cloning, run install (recommended):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

Or download only the model:

```powershell
python scripts/download_model.py
```

Default source: [GitHub Release v1.0.0](https://github.com/lawgorithims/ATC_Transcriptions/releases/download/v1.0.0/model.safetensors)

Check without downloading:

```powershell
python scripts/download_model.py --check-only
```

Override URL: `$env:MODEL_DOWNLOAD_URL = "..."` or `model.download_url` in `config.yaml`.

Manual fallback: download `model.safetensors` and place it in this directory. See `GITHUB.md`.

## Train or retrain

```bash
python train_distil_whisper.py --data-dir data --train-metadata atc_combined/train_metadata.json --output-dir models/whisper-atc
```

After training, publish weights for others:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/publish_model_release.ps1
```
