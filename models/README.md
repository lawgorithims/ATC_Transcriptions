# Fine-tuned Models

## whisper-atc

Whisper-small fine-tuned on the combined ATCO2 + ATCoSIM training set (8,095 samples).

```
whisper-atc/
├── model.safetensors          # Final trained weights (~922 MB)
├── config.json                # Model config
├── tokenizer.json             # Tokenizer
├── checkpoint-2200/           # Training checkpoint (can delete to save ~2.7 GB)
└── checkpoint-2400/           # Training checkpoint (can delete to save ~2.7 GB)
```

Total size: ~6.3 GB (checkpoints include optimizer state).

Training checkpoints are safe to remove once satisfied with the final model.
The root-level `model.safetensors` is what inference scripts load by default.

## Train or retrain

```bash
python train_distil_whisper.py --data-dir data --train-metadata atc_combined/train_metadata.json --output-dir models/whisper-atc
```
