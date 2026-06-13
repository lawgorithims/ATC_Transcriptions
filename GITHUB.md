# Push to GitHub

This repo is set up for **live inference only** — no training data, no checkpoints.

## One-time setup

1. Install [Git LFS](https://git-lfs.com/) (required for the ~922 MB model):
   ```powershell
   git lfs install
   ```

2. Create a new empty repo on GitHub (e.g. `atc-live-transcribe`).

3. From the project root:
   ```powershell
   git init
   git lfs track "models/whisper-atc/*.safetensors"
   git add .gitattributes
   git add .
   git commit -m "Initial release: context-aware live ATC transcription"
   git branch -M main
   git remote add origin https://github.com/YOUR_USER/YOUR_REPO.git
   git push -u origin main
   ```

4. First push uploads the model via LFS (may take several minutes).

## What is included

- Live pipeline code with airport context
- Final model (`models/whisper-atc/model.safetensors` + tokenizer)
- KDFW feed config
- Install scripts

## What is excluded (.gitignore)

- All training data (`data/`)
- Training scripts and evaluation outputs
- Training checkpoints (`checkpoint-2200/`, etc.)
- Local recordings, results, `.venv`

## Clone on another machine

```bash
git clone https://github.com/YOUR_USER/YOUR_REPO.git
cd YOUR_REPO
git lfs pull
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
python live_atc_pipeline.py
```
