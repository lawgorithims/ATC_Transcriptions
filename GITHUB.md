# Push to GitHub

This repo is set up for **live inference only** — no training data, no checkpoints, no model weights in git.

## One-time setup

1. Create a new empty repo on GitHub (e.g. `ATC_Transcriptions`).

2. From the project root:
   ```powershell
   git init
   git add .
   git commit -m "Initial release: context-aware live ATC transcription"
   git branch -M main
   git remote add origin https://github.com/YOUR_USER/YOUR_REPO.git
   git push -u origin main
   ```

3. Authenticate when prompted (GitHub username + personal access token, or Git Credential Manager).

## Model weights (not in git)

The fine-tuned model (`models/whisper-atc/model.safetensors`, ~922 MB) is **excluded** from the repository because it blocks git push/LFS uploads.

After cloning, download the weights and place them here:

```
models/whisper-atc/model.safetensors
```

Options for hosting the weights:

- **GitHub Release** — attach `model.safetensors` as a release asset on this repo
- **Hugging Face** — upload to a model repo and document the download URL in README
- **Manual copy** — copy from your local training output

Tokenizer and config files in `models/whisper-atc/` are included in git.

## What is included

- Live pipeline code with airport context
- Tokenizer + config (`models/whisper-atc/` minus weights)
- KDFW feed config
- Install scripts

## What is excluded (.gitignore)

- Model weights (`model.safetensors`)
- All training data (`data/`)
- Training scripts and evaluation outputs
- Training checkpoints (`checkpoint-2200/`, etc.)
- Local recordings, results, `.venv`
