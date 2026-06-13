# Scripts

Batch helpers. All scripts `cd` to the project root before running.

| Script | Purpose |
|--------|---------|
| `install.bat` / `install.ps1` | Fresh install: venv, pip deps, ffmpeg check |
| `run_live_pipeline.bat` | Live KDFW Lone Star Approach feed + latency |
| `run_latency_eval.bat` | Offline latency eval on recorded JFK feed (fast replay) |
| `run_full_transcription.bat` | Transcribe full JFK recording with fine-tuned model |
| `run_atcosim_250.bat` | Quick 250-sample ATCoSIM evaluation |
| `check_gpu_driver.bat` | GPU driver diagnostics |

Run from anywhere:

```bat
scripts\install.bat
scripts\run_live_pipeline.bat
```
