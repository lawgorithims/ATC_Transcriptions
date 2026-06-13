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

## Model weights (GitHub Release, not in git)

The fine-tuned model (`models/whisper-atc/model.safetensors`, ~922 MB) is **excluded** from the repository because it blocks git push/LFS uploads.

Weights are hosted on **GitHub Releases** and downloaded automatically during install.

### Clone + install (auto-download)

```powershell
git clone https://github.com/lawgorithims/ATC_Transcriptions.git
cd ATC_Transcriptions
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

Install runs `scripts/download_model.py`, which:

- Skips download if `models/whisper-atc/model.safetensors` already exists with the correct size (~922 MB)
- Otherwise downloads from the default release URL:
  `https://github.com/lawgorithims/ATC_Transcriptions/releases/download/v1.0.0/model.safetensors`

Override the URL with an environment variable:

```powershell
$env:MODEL_DOWNLOAD_URL = "https://example.com/custom/model.safetensors"
python scripts/download_model.py
```

Or set `model.download_url` in `config.yaml`.

### Manual download fallback

If the automatic download fails:

1. Download `model.safetensors` from the [v1.0.0 release](https://github.com/lawgorithims/ATC_Transcriptions/releases/tag/v1.0.0)
2. Place it at `models/whisper-atc/model.safetensors`
3. Verify: `python scripts/download_model.py --check-only`

### Maintainers: publish a new release

**With GitHub CLI (`gh`):**

```powershell
powershell -ExecutionPolicy Bypass -File scripts/publish_model_release.ps1
```

Optional flags: `-Tag v1.0.0`, `-Repo lawgorithims/ATC_Transcriptions`

**Without `gh` (manual):**

1. Open https://github.com/lawgorithims/ATC_Transcriptions/releases/new
2. Tag: `v1.0.0` (create on publish)
3. Title: e.g. `Model weights v1.0.0`
4. Attach `models/whisper-atc/model.safetensors` as release asset (name: `model.safetensors`)
5. Publish release

After publishing, update `config.yaml` / default URL in `scripts/download_model.py` if the tag changes.

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
