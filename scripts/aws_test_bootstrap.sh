#!/usr/bin/env bash
#
# One-command GPU setup + serve + self-test for ATC_Transcribe on a fresh
# Amazon Linux 2023 GPU instance (e.g. g5.2xlarge / NVIDIA A10G).
#
# Run it from a phone terminal (EC2 Instance Connect) in a single line:
#
#   curl -fsSL https://raw.githubusercontent.com/lawgorithims/ATC_Transcriptions/claude/aws-instance-connection-8zp68p/scripts/aws_test_bootstrap.sh | bash
#
# Stages (each idempotent; safe to re-run):
#   A. Base packages (git, Python 3.11, libsndfile, best-effort ffmpeg) + clone repo.
#   B. NVIDIA driver (DKMS). If the kernel module needs a reboot to load, it installs
#      a systemd one-shot that re-runs THIS script on boot, then reboots -> setup
#      continues automatically with no action from you (at most one reboot).
#   C. venv + CUDA PyTorch + project/web deps.
#   D. Download both model weights (turbo default + small fallback, ~3.9 GB).
#   E. Run the web server as a persistent systemd service (atc-web).
#   F. Run scripts/aws_selftest.py and print a PASS/FAIL summary.
#
# After it finishes, open  http://<instance-public-ip>:8000  (open inbound TCP 8000
# in the security group first). Everything is logged to ~/atc_bootstrap.log.
set -uo pipefail

REPO_URL="https://github.com/lawgorithims/ATC_Transcriptions.git"
BRANCH="${BRANCH:-claude/aws-instance-connection-8zp68p}"
APP_DIR="${APP_DIR:-$HOME/ATC_Transcriptions}"
PORT="${PORT:-8000}"
PY="${PY:-python3.11}"
LOGFILE="$HOME/atc_bootstrap.log"
REBOOT_FLAG="$HOME/.atc_gpu_reboot_done"
RESUME_UNIT="/etc/systemd/system/atc-bootstrap.service"
WEB_UNIT="/etc/systemd/system/atc-web.service"
SVC_USER="$(whoami)"

# Mirror all output to a log so it's readable after the auto-resume reboot.
exec > >(tee -a "$LOGFILE") 2>&1

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mXX %s\033[0m\n' "$*"; }

log "ATC_Transcribe bootstrap run at $(date) (user=$SVC_USER, host=$(hostname))"

# ===========================================================================
# Stage A: base packages + clone (must run before anything references the repo)
# ===========================================================================
log "[A/F] Installing base packages (git, $PY, libsndfile) ..."
sudo dnf install -y -q git "$PY" "${PY}-pip" libsndfile tar gzip xz which curl \
    >/dev/null 2>&1 || sudo dnf install -y git "$PY" "${PY}-pip" libsndfile
command -v "$PY" >/dev/null 2>&1 || PY=python3

# ffmpeg is only needed for live online feeds (proof-of-life does not need it).
if ! command -v ffmpeg >/dev/null 2>&1; then
    log "[A] Installing a static ffmpeg (best effort; live feeds need it) ..."
    if curl -fsSL --max-time 120 \
        https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
        -o /tmp/ffmpeg.tar.xz 2>/dev/null; then
        mkdir -p /tmp/ffmpeg && tar xf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1 \
            && sudo cp /tmp/ffmpeg/ffmpeg /tmp/ffmpeg/ffprobe /usr/local/bin/ 2>/dev/null \
            && echo "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)" \
            || warn "ffmpeg extract failed - live feeds disabled, proof-of-life still works."
    else
        warn "Could not fetch ffmpeg - live feeds disabled, proof-of-life still works."
    fi
fi

log "[A] Fetching repo into $APP_DIR (branch $BRANCH) ..."
if [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" fetch --depth 1 origin "$BRANCH" \
        && git -C "$APP_DIR" checkout -B "$BRANCH" FETCH_HEAD \
        || warn "git update failed; using existing checkout."
else
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$APP_DIR" \
        || git clone "$REPO_URL" "$APP_DIR" \
        || { die "git clone failed"; exit 1; }
    git -C "$APP_DIR" checkout "$BRANCH" 2>/dev/null || true
fi
cd "$APP_DIR" || { die "cannot cd to $APP_DIR"; exit 1; }

# ===========================================================================
# finalize(): stages C-F. Called once the GPU driver is confirmed working.
# ===========================================================================
finalize() {
    cd "$APP_DIR" || return 1

    log "[C/F] Creating venv + installing CUDA PyTorch ($($PY --version)) ..."
    [ -d .venv ] || "$PY" -m venv .venv
    # shellcheck disable=SC1091
    source .venv/bin/activate
    python -m pip install --upgrade -q pip wheel setuptools
    # Default PyTorch index ships the CUDA build on Linux x86_64.
    python -m pip install -q torch || { die "torch install failed"; return 1; }
    python - <<'PYCHK'
import torch
ok = torch.cuda.is_available()
print(f"torch {torch.__version__} | cuda_available={ok} | "
      f"device={torch.cuda.get_device_name(0) if ok else 'cpu'}")
PYCHK

    log "[C] Installing project + web-server deps ..."
    python -m pip install -q -r requirements-live.txt -r requirements-server.txt \
        || { die "dependency install failed"; return 1; }

    log "[D/F] Downloading model weights (turbo + small, ~3.9 GB) ..."
    python scripts/download_model.py || warn "model download reported a problem - see log."

    log "[E/F] Installing + (re)starting the web server systemd service (atc-web) ..."
    sudo tee "$WEB_UNIT" >/dev/null <<UNIT
[Unit]
Description=ATC_Transcribe web UI
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python -m server.app --host 0.0.0.0 --port $PORT
Restart=on-failure
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable atc-web.service >/dev/null 2>&1 || true
    sudo systemctl restart atc-web.service

    log "[F] Running automated self-test ..."
    python scripts/aws_selftest.py --base "http://127.0.0.1:$PORT" \
        --report "$APP_DIR/aws_selftest_report.json"
    local rc=$?

    local token ip
    token="$(curl -fsS -X PUT --max-time 5 'http://169.254.169.254/latest/api/token' \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)"
    ip="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $token" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<instance-public-ip>')"

    log "DONE (self-test exit code: $rc)"
    cat <<EOF

  Web UI:        http://$ip:$PORT      (open inbound TCP $PORT in the security group)
  Web service:   sudo systemctl status atc-web    |    logs: journalctl -u atc-web -e
  GPU:           $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo 'n/a')
  Bootstrap log: $LOGFILE
  Test report:   $APP_DIR/aws_selftest_report.json
  Self-test exit code: $rc  (0 = all checks passed)
EOF
    return "$rc"
}

# ===========================================================================
# Stage B: NVIDIA driver / CUDA
# ===========================================================================
cleanup_resume_unit() {
    sudo systemctl disable atc-bootstrap.service >/dev/null 2>&1 || true
    sudo rm -f "$RESUME_UNIT"
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
}

log "[B/F] Checking for a working NVIDIA GPU ..."
if nvidia-smi >/dev/null 2>&1; then
    log "GPU already available:"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    cleanup_resume_unit
    finalize; exit $?
fi

log "[B] No GPU yet - installing NVIDIA driver (DKMS) for Amazon Linux 2023 ..."
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo \
    https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
sudo dnf clean expire-cache
# Build toolchain + kernel headers matching the running kernel (fallback to latest).
sudo dnf install -y gcc make dkms kernel-devel-"$(uname -r)" kernel-headers-"$(uname -r)" \
    || sudo dnf install -y gcc make dkms kernel-devel kernel-headers
# Driver only (PyTorch ships its own CUDA runtime; no full toolkit needed).
sudo dnf module install -y nvidia-driver:latest-dkms \
    || sudo dnf install -y cuda-drivers kmod-nvidia-latest-dkms nvidia-driver-cuda \
    || warn "NVIDIA driver package install hit an error - see log above."

# Try to load the freshly built module without a reboot.
sudo modprobe nvidia 2>/dev/null || true
sudo modprobe nvidia_uvm 2>/dev/null || true
if nvidia-smi >/dev/null 2>&1; then
    log "GPU is up without a reboot:"
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    cleanup_resume_unit
    finalize; exit $?
fi

# Module not loadable yet -> a reboot is required.
if [ -f "$REBOOT_FLAG" ]; then
    die "GPU still unavailable after a reboot - the driver build likely failed."
    echo "------ diagnostics (send me ~/atc_bootstrap.log) ------"
    dkms status 2>/dev/null
    lsmod | grep -i nvidia || echo "(no nvidia kernel module loaded)"
    sudo dmesg 2>/dev/null | grep -i nvidia | tail -20
    cleanup_resume_unit
    exit 1
fi

log "[B] Driver installed; scheduling auto-resume after reboot ..."
touch "$REBOOT_FLAG"
sudo tee "$RESUME_UNIT" >/dev/null <<UNIT
[Unit]
Description=ATC_Transcribe bootstrap auto-resume after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SVC_USER
Environment=HOME=$HOME
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash $APP_DIR/scripts/aws_test_bootstrap.sh
KillMode=process
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable atc-bootstrap.service

log "Rebooting now to load the NVIDIA driver."
log "Setup will CONTINUE AUTOMATICALLY after reboot - no action needed."
log "Reconnect in ~3-5 min and watch progress with:   tail -f $LOGFILE"
sync
sleep 3
sudo reboot
