# Live ATC Transcription



Real-time transcription of live online ATC radio feeds using a fine-tuned Whisper model with **airport context** (facility, runways, fixes, and rolling call history).



Default feed: **KDFW Lone Star Approach (17/35C Final)** — 127.075 MHz.



## Quick start



**Windows (PowerShell):**



```powershell

# 1. Install

powershell -ExecutionPolicy Bypass -File scripts/install.ps1

.\.venv\Scripts\Activate.ps1



# 2. Install ffmpeg (required for live streams)

winget install Gyan.FFmpeg



# 3. Run

python live_atc_pipeline.py

```



**macOS / Linux (bash):**



```bash

# 1. Install (creates .venv, installs deps, downloads model weights)

bash scripts/install.sh

source .venv/bin/activate



# 2. Install ffmpeg (required for live streams)

brew install ffmpeg          # macOS  (Linux: sudo apt-get install ffmpeg)



# 3. Run

python live_atc_pipeline.py

```



On Apple Silicon (M-series) Macs, the default `device: "auto"` automatically uses the Metal (MPS) GPU. Override with `--device cpu` or `--device mps` if needed.



## Verify the install (proof of life)



After installing, run the diagnostic to confirm the model loads on this machine's GPU/CPU and transcribes correctly. It auto-detects CUDA (NVIDIA), Metal/MPS (Apple Silicon), or CPU, runs a few short bundled ATC snippets, and prints a PASS/FAIL verdict (exit code `0` on PASS).



```bash

# Cross-platform:

python diagnostics/diagnostic.py



# Or via the platform launcher:

bash diagnostics/diagnostic.sh                                        # macOS / Linux

powershell -ExecutionPolicy Bypass -File diagnostics/diagnostic.ps1   # Windows



# Force a backend, or save a JSON report:

python diagnostics/diagnostic.py --device cpu

python diagnostics/diagnostic.py --device mps --json report.json

```



The snippets and their reference transcripts live in `tests/diagnostic_data/`.



## How context works



Each transmission is decoded with a Whisper prompt built from:



1. **Static context** — facility name, airport, runways, fixes (from `airport_configs/kdfw.json`)

2. **Rolling history** — last 3 transcribed calls on the same feed



This biases the model toward correct ATC phraseology, call signs, and local names.



## Change the feed



Edit `airport_configs/kdfw.json` or pass flags:



```bash

python live_atc_pipeline.py --stream-url "https://d.liveatc.net/kdfw1_app_fin_17c"

python live_atc_pipeline.py --feed lone_star_approach_17l_final

```



Add new airports by creating `airport_configs/<icao>.json` with a `streams` section.



## Model



Fine-tuned Whisper-small weights are **not stored in this repo** (~922 MB). They are hosted on [Hugging Face Hub](https://huggingface.co/SingularityUS/ATC-whisper-v1) and **downloaded automatically** when you run `scripts/install.ps1`.



GitHub blocks files over 100 MB in git and ties release assets to Git LFS plan limits, so model weights are not published via GitHub Releases.



Manual download or troubleshooting: see `GITHUB.md` and `models/README.md`.



```powershell

python scripts/download_model.py          # download if missing

python scripts/download_model.py --check-only   # verify only

```



## Project layout



```

live_atc_pipeline.py   # Main entry point

atc_stream.py          # Live feed capture + VAD

atc_transcriber.py     # Fine-tuned Whisper inference

atc_context.py         # Airport + history context prompts

audio_preprocessing.py # Radio noise cleanup

airport_configs/       # Per-airport feed URLs and context

models/whisper-atc/    # Final fine-tuned model weights

config.yaml            # Default settings

scripts/               # install + run helpers

```



## Requirements



- Python 3.10+

- ffmpeg on PATH (live streams)

- GPU recommended (`--device cuda`)

- Model weights (~922 MB) — auto-downloaded on install; see `GITHUB.md` if download fails



See `LIVE_PIPELINE_README.md` and `GITHUB.md` for more details.



## License



Model training data (ATCO2, ATCoSIM) is subject to its respective licenses and is **not** included in this repository.


