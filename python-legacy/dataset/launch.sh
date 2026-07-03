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

mkdir -p logs
echo "GPU:"; nvidia-smi -L || true

# Persistent storage reminder: data goes under config 'storage_root'. On the H100,
# mount your block volume and set storage_root to it so data survives teardown, e.g.:
#   lsblk; mkdir -p /mnt/atc-data
#   mount /dev/sdb /mnt/atc-data        # (format once: mkfs.ext4 /dev/sdb)
#   # set  storage_root: /mnt/atc-data  in dataset/config.yaml
echo "Storage root from config:"; grep -E '^storage_root:' dataset/config.yaml || echo "  (defaults to ./data — EPHEMERAL; set storage_root to a mounted volume)"
echo "Monitor data health any time:  python -m dataset.monitor --config dataset/config.yaml --watch 30"

# Continuous harvest. The pipeline itself loops (acquisition.loop: true), so models
# load once and stay resident. Logs to logs/harvest.log as well as the console.
echo "Starting continuous harvest — Ctrl-C to stop. Logging to logs/harvest.log"
exec python -m dataset.run_pipeline --config dataset/config.yaml 2>&1 | tee -a logs/harvest.log
