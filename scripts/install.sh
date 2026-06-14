#!/usr/bin/env bash
# Fresh install for ATC_Transcribe (macOS / Linux)
# Usage: bash scripts/install.sh
#
# On Apple Silicon (M-series) the live pipeline uses the Metal (MPS) GPU
# automatically when device is "auto". ffmpeg is installed via Homebrew.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
echo "========================================"
echo " ATC_Transcribe - Fresh Install"
echo "========================================"
echo "Project root: $ROOT"
echo
# Prefer python3; fall back to python.
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
    echo "ERROR: Python not found on PATH. Install Python 3.10+ (brew install python)." >&2
    exit 1
fi
echo "[1/6] Python: $("$PY" --version)"
VENV="$ROOT/.venv"
if [ ! -d "$VENV" ]; then
    echo "[2/6] Creating virtual environment .venv ..."
    "$PY" -m venv "$VENV"
else
    echo "[2/6] Using existing .venv"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
echo "[3/6] Upgrading pip ..."
python -m pip install --upgrade pip wheel setuptools
echo "[4/6] Installing Python dependencies ..."
python -m pip install -r requirements-live.txt
echo "      Trying optional webrtcvad (may need C/C++ build tools) ..."
if python -m pip install webrtcvad >/dev/null 2>&1; then
    echo "      webrtcvad installed."
else
    echo "      webrtcvad skipped - live pipeline will use energy-based VAD fallback."
fi
echo "[5/6] Downloading model weights (if needed) ..."
python scripts/download_model.py
echo "[6/6] Checking ffmpeg (required for live online feeds) ..."
if command -v ffmpeg >/dev/null 2>&1; then
    echo "      ffmpeg OK: $(ffmpeg -version 2>&1 | head -n 1)"
else
    echo "      ffmpeg NOT found."
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "      Install with:  brew install ffmpeg"
    else
        echo "      Install with:  sudo apt-get install -y ffmpeg"
    fi
    echo "      Offline testing works without ffmpeg via --simulate-file"
fi
echo
echo "========================================"
echo " Install complete"
echo "========================================"
echo
echo "Activate the environment:"
echo "  source .venv/bin/activate"
echo
echo "Start live KDFW Lone Star Approach feed:"
echo "  python live_atc_pipeline.py"
echo
echo "Offline smoke test (no ffmpeg / no live feed needed):"
echo "  python live_atc_pipeline.py --simulate-file <recording.mp3> --fast-simulate --max-segments 5"
