#!/usr/bin/env bash
#
# Convert the fine-tuned ATC Whisper checkpoints to WhisperKit CoreML format.
#
#   *** RUN THIS ON macOS (the Scaleway M4) ***
#   coremltools + coremlcompiler (Xcode) are required; there is no Windows path.
#
# Usage:
#   bash convert_to_coreml.sh
#   OUT_DIR=~/atc-coreml PREFILL=1 bash convert_to_coreml.sh
#
# See convert_to_coreml.md for the full guide.

set -euo pipefail

SMALL_REPO="${SMALL_REPO:-SingularityUS/ATC-whisper-v1}"
TURBO_REPO="${TURBO_REPO:-SingularityUS/ATC-whisper-turbo-v1}"
OUT_DIR="${OUT_DIR:-$HOME/atc-coreml}"
WKT_DIR="${WKT_DIR:-$HOME/whisperkittools}"
PREFILL="${PREFILL:-1}"          # 1 = also generate decoder context-prefill data
PYTHON="${PYTHON:-python3.11}"

echo "== preflight =="
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this must run on macOS. coremltools/coremlcompiler are not available elsewhere." >&2
  exit 1
fi
command -v "$PYTHON" >/dev/null || { echo "ERROR: $PYTHON not found (brew install python@3.11)." >&2; exit 1; }
if ! xcrun --find coremlcompiler >/dev/null 2>&1; then
  echo "ERROR: coremlcompiler not found. Install full Xcode, then:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
"$PYTHON" --version

echo "== whisperkittools env =="
[ -d "$WKT_DIR" ] || git clone https://github.com/argmaxinc/whisperkittools "$WKT_DIR"
[ -d "$WKT_DIR/.env" ] || "$PYTHON" -m venv "$WKT_DIR/.env"
# shellcheck disable=SC1091
source "$WKT_DIR/.env/bin/activate"
pip install -U pip >/dev/null
pip install -e "$WKT_DIR"

extra=()
[ "$PREFILL" = "1" ] && extra+=(--generate-decoder-context-prefill-data)

convert () {
  local repo="$1" name="$2"
  echo "== converting $repo -> $OUT_DIR/$name =="
  whisperkit-generate-model --model-version "$repo" --output-dir "$OUT_DIR/$name" "${extra[@]}"
}

convert "$SMALL_REPO" small
convert "$TURBO_REPO" turbo

echo "== done — converted models under $OUT_DIR =="
find "$OUT_DIR" -name '*.mlmodelc' -o -name 'config.json' | sort
