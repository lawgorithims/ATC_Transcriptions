#!/usr/bin/env bash
#
# Fetch the local context-fixer LLM (a small instruct GGUF) into the app bundle's model
# folder, so LocalLLMCorrector / LlamaContext can load it on the CPU. No CoreML conversion is
# needed — llama.cpp consumes GGUF directly — so unlike the Whisper model this runs anywhere
# (Mac or Linux), not just the M4 build box.
#
# Default: Qwen2.5-0.5B-Instruct, Q4_K_M (~0.4 GB) — the "tiny" footprint chosen for the app.
# Override the model with MODEL_URL=... (any HF GGUF resolve URL).
#
#   bash Tools/fetch_llm_model.sh
#   MODEL_URL=https://huggingface.co/<repo>/resolve/main/<file>.gguf bash Tools/fetch_llm_model.sh
#
# The file lands at ATCTranscribe/Resources/Models/llm/<name>.gguf and is git-ignored; the
# `Models` folder reference in project.yml bundles it into the app automatically.

set -euo pipefail

MODEL_URL="${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf}"

# Resolve the destination relative to this script (Tools/ -> ../ATCTranscribe/Resources/Models/llm).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../ATCTranscribe/Resources/Models/llm"
FILE_NAME="$(basename "$MODEL_URL")"
DEST="$DEST_DIR/$FILE_NAME"

mkdir -p "$DEST_DIR"

if [[ -f "$DEST" ]]; then
  echo "Model already present: $DEST"
  echo "Delete it to re-download, or set MODEL_URL to fetch a different model."
  exit 0
fi

echo "Downloading $FILE_NAME"
echo "  from: $MODEL_URL"
echo "  to:   $DEST"

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 -o "$DEST.partial" "$MODEL_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$DEST.partial" "$MODEL_URL"
else
  echo "error: need curl or wget on PATH" >&2
  exit 1
fi

mv "$DEST.partial" "$DEST"

# Sanity: GGUF files start with the magic bytes "GGUF".
if [[ "$(head -c 4 "$DEST")" != "GGUF" ]]; then
  echo "error: downloaded file is not a GGUF (bad magic) — removing" >&2
  rm -f "$DEST"
  exit 1
fi

BYTES="$(wc -c < "$DEST" | tr -d ' ')"
echo "Done: $DEST (${BYTES} bytes)"
echo "Rebuild the app (xcodegen generate && xcodebuild ...) to bundle it; the On-device backend"
echo "in Settings will then activate. Without it the app runs deterministic-only / Foundation Models."
