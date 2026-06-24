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

## Model weights (Hugging Face Hub, not in git)

The fine-tuned model (`models/whisper-atc/model.safetensors`, ~922 MB) is **excluded** from the repository.

**Why not GitHub?** GitHub blocks individual files over **100 MB** in git. Release assets are also subject to per-file Git LFS limits on your plan, which is why a ~922 MB `model.safetensors` cannot be reliably hosted on GitHub Releases.

**Hugging Face Hub** supports large model files (hard limit **500 GB** per file; ~922 MB is well within limits) and is the standard host for ML weights.

Default model repo: **[SingularityUS/ATC-whisper-v1](https://huggingface.co/SingularityUS/ATC-whisper-v1)**

### Clone + install (auto-download)

```powershell
git clone https://github.com/lawgorithims/ATC_Transcriptions.git
cd ATC_Transcriptions
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

Install runs `scripts/download_model.py`, which:

- Skips download if `models/whisper-atc/model.safetensors` already exists with the correct size (~922 MB)
- Otherwise downloads `model.safetensors` from Hugging Face Hub (`SingularityUS/ATC-whisper-v1` by default)

Override the Hugging Face repo:

```powershell
$env:MODEL_HF_REPO = "your-org/your-model"
python scripts/download_model.py
```

Or set `model.hf_repo` in `config.yaml`.

### Direct URL fallback

For mirrors or offline mirrors, set a direct download URL (skips Hugging Face):

```powershell
$env:MODEL_DOWNLOAD_URL = "https://example.com/custom/model.safetensors"
python scripts/download_model.py
```

Or set `model.download_url` in `config.yaml`.

### Manual download fallback

If the automatic download fails:

1. Download `model.safetensors` from [Hugging Face](https://huggingface.co/SingularityUS/ATC-whisper-v1/tree/main)
2. Place it at `models/whisper-atc/model.safetensors`
3. Verify: `python scripts/download_model.py --check-only`

### Maintainers: publish weights to Hugging Face

**One-time auth:**

```powershell
pip install huggingface_hub
huggingface-cli login
```

Create a write token at https://huggingface.co/settings/tokens if prompted.

**Upload:**

```powershell
python scripts/publish_model_hf.py
```

Optional flags: `--repo SingularityUS/ATC-whisper-v1`, `--private`

This creates the public model repo (if needed) and uploads `models/whisper-atc/model.safetensors`. Default target is the **SingularityUS** org repo; maintainers need write access to that org.

#### Legacy: GitHub Release (not recommended)

GitHub Releases cannot reliably host ~922 MB assets on free/default plans. `scripts/publish_model_release.ps1` remains for reference only.

Tokenizer and config files in `models/whisper-atc/` are included in git.

## What is included

- Live pipeline code with airport context
- Tokenizer + config (`models/whisper-atc/` minus weights)
- KDFW feed config
- Install scripts + model download helper

## What is excluded (.gitignore)

- Model weights (`model.safetensors`)
- All training data (`data/`)
- Training scripts and evaluation outputs
- Training checkpoints (`checkpoint-2200/`, etc.)
- Local recordings, results, `.venv`
