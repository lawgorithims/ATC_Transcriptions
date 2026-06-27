#!/usr/bin/env bash
#
# One-shot setup + continuous harvest on the GPU box (run inside tmux).
#
#   tmux new -s atc
#   cd ATC_Transcriptions/python-legacy && bash dataset/launch.sh
#
# Sets up the venv + deps + model, then loops: probe feeds -> record active ones ->
# segment -> two-model consensus -> write pseudo-labels, forever (Ctrl-C to stop).
# Idempotent: safe to re-run; manifests resume where they left off.
#
# Build the honest US baseline separately (different wall-clock time -> disjoint):
#   python -m dataset.eval_set build --config dataset/config.yaml
#   python -m dataset.eval_set score --config dataset/config.yaml --model models/whisper-atc-turbo

set -euo pipefail
cd "$(dirname "$0")/.."          # -> python-legacy

# System deps (root box). ffmpeg is required for live recording.
command -v ffmpeg >/dev/null 2>&1 || { apt-get update && apt-get install -y ffmpeg; }

# Python env.
[ -d .venv ] || python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -U pip
pip install -q -r requirements-live.txt
pip install -q webrtcvad jiwer        # better VAD + WER tooling

# Fine-tuned ATC model (consensus partner B). Skip if already present.
[ -d models/whisper-atc-turbo ] || python scripts/download_model.py || \
  echo "WARN: could not auto-download models/whisper-atc-turbo — set models.partner_b in dataset/config.yaml"

mkdir -p data logs
echo "GPU:"; nvidia-smi -L || true

# Continuous harvest. The pipeline itself loops (acquisition.loop: true), so models
# load once and stay resident. Logs to logs/harvest.log as well as the console.
echo "Starting continuous harvest — Ctrl-C to stop. Logging to logs/harvest.log"
exec python -m dataset.run_pipeline --config dataset/config.yaml 2>&1 | tee -a logs/harvest.log
