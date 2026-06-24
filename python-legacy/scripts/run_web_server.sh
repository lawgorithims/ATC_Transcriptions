#!/usr/bin/env bash
# Launch the ATC_Transcribe browser console (macOS / Linux).
#
# On Apple Silicon the model runs on the Metal (MPS) GPU automatically.
# Open the printed URL from any browser on the same network.
#
# Usage:
#   bash scripts/run_web_server.sh                 # 0.0.0.0:8000, device auto
#   bash scripts/run_web_server.sh --port 9000
#   bash scripts/run_web_server.sh --device mps --warm
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -d "$ROOT/.venv" ]; then
    # shellcheck disable=SC1091
    source "$ROOT/.venv/bin/activate"
fi

# Ensure the web layer is installed (idempotent, fast if already present).
if ! python -c "import fastapi, uvicorn" >/dev/null 2>&1; then
    echo "Installing web server dependencies (fastapi, uvicorn) ..."
    python -m pip install -r requirements-server.txt
fi

HOST="0.0.0.0"
PORT="8000"
echo "Starting ATC_Transcribe web UI..."
echo "When it prints the URL, open it in a browser on this network."
exec python -m server.app --host "$HOST" --port "$PORT" "$@"
