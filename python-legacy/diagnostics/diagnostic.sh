#!/usr/bin/env bash
# Proof-of-life diagnostic for ATC_Transcribe (macOS / Linux)
# Usage: bash diagnostics/diagnostic.sh [extra args]
#
# On Apple Silicon, device "auto" resolves to the Metal (MPS) GPU; on a CUDA box
# it resolves to the NVIDIA GPU; otherwise CPU. Transcribes a few short bundled
# ATC snippets and prints a PASS/FAIL verdict.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -f "$ROOT/.venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "$ROOT/.venv/bin/activate"
else
    echo "No .venv found - using system python. Run scripts/install.sh first."
fi

python "$ROOT/diagnostics/diagnostic.py" "$@"
