#!/usr/bin/env bash
#
# One-command setup + serve + self-test for ATC_Transcribe on a fresh
# Amazon Linux 2023 EC2 instance. Designed to be fetched and run in a single
# line from a phone terminal (EC2 Instance Connect):
#
#   curl -fsSL https://raw.githubusercontent.com/lawgorithims/ATC_Transcriptions/claude/aws-instance-connection-8zp68p/scripts/aws_test_bootstrap.sh | bash
#
# What it does:
#   1. Installs system deps (git, Python 3.11, libsndfile, best-effort ffmpeg).
#   2. Clones/updates this repo (public) and checks out the working branch.
#   3. Creates a venv and installs CPU PyTorch + project deps.
#   4. Downloads both model weights (turbo + small, ~3.9 GB) from Hugging Face.
#   5. Starts the web server with its defaults (adaptive: loads turbo, benchmarks
#      it, and auto-falls-back to small only if this device is too slow).
#   6. Runs scripts/aws_selftest.py and prints a PASS/FAIL summary.
#
# After it finishes, open  http://<this-instance-public-ip>:8000  in any browser
# (open inbound TCP 8000 in the instance's security group first).
#
# Re-running is safe/idempotent. Override defaults via env, e.g. PORT=80.
set -uo pipefail

REPO_URL="https://github.com/lawgorithims/ATC_Transcriptions.git"
BRANCH="${BRANCH:-claude/aws-instance-connection-8zp68p}"
APP_DIR="${APP_DIR:-$HOME/ATC_Transcriptions}"
PORT="${PORT:-8000}"
PY="${PY:-python3.11}"

log()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }

log "ATC_Transcribe bootstrap starting ($(date))"

# ---------------------------------------------------------------------------
# 1. System dependencies
# ---------------------------------------------------------------------------
log "[1/6] Installing system packages (git, $PY, libsndfile) ..."
sudo dnf install -y -q git python3.11 python3.11-pip libsndfile tar gzip xz >/dev/null 2>&1 \
    || sudo dnf install -y git python3.11 python3.11-pip libsndfile
command -v "$PY" >/dev/null 2>&1 || PY=python3

# ffmpeg is optional: only live online feeds need it (proof-of-life does not).
if ! command -v ffmpeg >/dev/null 2>&1; then
    log "[1b] Installing a static ffmpeg (best effort; live feeds need it) ..."
    if curl -fsSL --max-time 120 \
        https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
        -o /tmp/ffmpeg.tar.xz 2>/dev/null; then
        mkdir -p /tmp/ffmpeg && tar xf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1 \
            && sudo cp /tmp/ffmpeg/ffmpeg /tmp/ffmpeg/ffprobe /usr/local/bin/ 2>/dev/null \
            && echo "ffmpeg installed: $(ffmpeg -version 2>/dev/null | head -1)" \
            || warn "ffmpeg extract failed - live feeds disabled, proof-of-life still works."
    else
        warn "Could not fetch ffmpeg - live feeds disabled, proof-of-life still works."
    fi
fi

# ---------------------------------------------------------------------------
# 2. Get the code
# ---------------------------------------------------------------------------
log "[2/6] Fetching repo into $APP_DIR (branch $BRANCH) ..."
if [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH" && \
    git -C "$APP_DIR" checkout -B "$BRANCH" FETCH_HEAD
else
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR" \
        || git clone "$REPO_URL" "$APP_DIR"
    git -C "$APP_DIR" checkout "$BRANCH" 2>/dev/null || true
fi
cd "$APP_DIR" || { warn "cannot cd to $APP_DIR"; exit 1; }

# ---------------------------------------------------------------------------
# 3. Python environment
# ---------------------------------------------------------------------------
log "[3/6] Creating venv and installing Python deps ($($PY --version)) ..."
[ -d .venv ] || "$PY" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade -q pip wheel setuptools
# CPU-only PyTorch keeps the download small and avoids unusable CUDA libs.
log "      Installing CPU PyTorch ..."
python -m pip install -q torch --index-url https://download.pytorch.org/whl/cpu \
    || python -m pip install -q torch
log "      Installing project + web-server deps ..."
python -m pip install -q -r requirements-live.txt -r requirements-server.txt

# ---------------------------------------------------------------------------
# 4. Model weights (both: turbo default + small fallback)
# ---------------------------------------------------------------------------
log "[4/6] Downloading model weights (turbo + small, ~3.9 GB) ..."
python scripts/download_model.py \
    || warn "model download reported a problem - check the log above."

# ---------------------------------------------------------------------------
# 5. Start the server with its defaults (adaptive: turbo, auto-fallback small)
# ---------------------------------------------------------------------------
log "[5/6] Starting web server on 0.0.0.0:$PORT (adaptive, default turbo) ..."
pkill -f "server.app" 2>/dev/null && sleep 2 || true
nohup python -m server.app --host 0.0.0.0 --port "$PORT" > server.log 2>&1 &
SERVER_PID=$!
echo "server pid=$SERVER_PID, logging to $APP_DIR/server.log"

# ---------------------------------------------------------------------------
# 6. Self-test
# ---------------------------------------------------------------------------
log "[6/6] Running automated self-test ..."
python scripts/aws_selftest.py --base "http://127.0.0.1:$PORT" \
    --report "$APP_DIR/aws_selftest_report.json"
TEST_RC=$?

PUBLIC_IP="$(curl -fsS --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<this-instance-public-ip>')"
log "DONE"
cat <<EOF

  Web UI:        http://${PUBLIC_IP}:${PORT}
                 (open inbound TCP ${PORT} in the security group to reach it)
  Server log:    $APP_DIR/server.log
  Test report:   $APP_DIR/aws_selftest_report.json
  Self-test exit code: ${TEST_RC}  (0 = all checks passed)

  Server keeps running in the background. To stop it:  pkill -f server.app
EOF
exit "$TEST_RC"
