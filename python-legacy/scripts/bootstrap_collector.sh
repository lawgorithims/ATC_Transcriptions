#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bootstrap a US ATC pseudo-label COLLECTOR on a fresh (cheap) GPU box.
# Run as root on a brand-new instance with a CLEAN public IP:
#     bash bootstrap_collector.sh
#
# Why this works where the H100 got banned: it uses the committed plain-browser
# User-Agent and runs ONE collector / ONE connection at a time (LiveATC limits
# concurrent connections per IP). A fresh box = a fresh IP = ~2x daily throughput.
#
# Recommended instance: a cheap GPU box with >=16 GB VRAM (e.g. Scaleway L4-1-24G,
# Ubuntu, driver preinstalled). The two consensus models need ~6-7 GB VRAM total;
# an H100 is wasted on collection -- reserve that for fine-tuning.
#
# Tunables (env vars):
#   STORAGE_ROOT  data dir (default /mnt/atc-data; point at your biggest disk)
#   FEEDS         comma-sep airport_config basenames to include (default: all).
#                 For disjoint coverage vs the H100, e.g.:
#                 FEEDS="katl,klax,ksfo,kewr,kbos,paed,zoa,zan,zkc,zfw,kbna,kdtw,klga,ksdf"
#   BRANCH        git branch (default: the data-collection branch)
# ---------------------------------------------------------------------------
set -uo pipefail
REPO_URL="${REPO_URL:-https://github.com/lawgorithims/ATC_Transcriptions.git}"
BRANCH="${BRANCH:-claude/whisper-atc-training-data-bv0ap2}"
STORAGE_ROOT="${STORAGE_ROOT:-/mnt/atc-data}"
FEEDS="${FEEDS:-}"
TRANSFORMERS_PIN="${TRANSFORMERS_PIN:-transformers==5.12.1}"
APP="/root/ATC_Transcriptions/python-legacy"

echo "===== [1/6] system dependencies ====="
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -q
apt-get install -y git tmux ffmpeg python3-venv python3-dev build-essential curl rsync
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L || echo "WARN: no GPU detected -- need a GPU box with >=16GB VRAM + driver."

echo "===== [2/6] repo @ $BRANCH ====="
if [ -d /root/ATC_Transcriptions/.git ]; then
  git -C /root/ATC_Transcriptions fetch origin --prune
else
  git clone "$REPO_URL" /root/ATC_Transcriptions
fi
git -C /root/ATC_Transcriptions checkout "$BRANCH"
git -C /root/ATC_Transcriptions pull --ff-only origin "$BRANCH" || true

echo "===== [3/6] python env (pinned transformers) ====="
cd "$APP"
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q -U pip
pip install -q -r requirements-live.txt
pip install -q webrtcvad jiwer "$TRANSFORMERS_PIN"
python -c "import torch;print('torch',torch.__version__,'cuda',torch.cuda.is_available())" || { echo "torch/cuda check failed"; exit 1; }

echo "===== [4/6] storage + collector config ====="
mkdir -p "$STORAGE_ROOT"
free_gb=$(df -BG --output=avail "$STORAGE_ROOT" 2>/dev/null | tail -1 | tr -dc 0-9)
echo "STORAGE_ROOT=$STORAGE_ROOT  free=${free_gb:-?}GB"
[ "${free_gb:-0}" -lt 20 ] && echo "WARN: <20GB free -- raw audio fills fast (~0.5GB/feed-hour). Point STORAGE_ROOT at a bigger disk."
python - "$STORAGE_ROOT" "$FEEDS" <<'PY'
import sys, yaml
storage, feeds_csv = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(open("dataset/config.yaml"))
cfg["storage_root"] = storage
if feeds_csv.strip():
    want = {f.strip().lower() for f in feeds_csv.split(",") if f.strip()}
    cfg["feeds"] = [f for f in cfg["feeds"]
                    if f["airport_config"].split("/")[-1].replace(".json", "").lower() in want]
yaml.safe_dump(cfg, open("dataset/collector.yaml", "w"), sort_keys=False)
print("collector feeds:", [f["airport_config"].split("/")[-1].replace(".json","") for f in cfg["feeds"]])
PY

echo "===== [5/6] service scripts ====="
cat > /root/atc-collect.sh <<EOF
#!/bin/bash
# Supervised single collector (auto-restart on crash).
cd $APP || exit 1
source .venv/bin/activate
export PYTHONUNBUFFERED=1 TRANSFORMERS_VERBOSITY=error
mkdir -p logs
while true; do
  echo "=== \$(date -u +%FT%TZ) start ===" >> logs/harvest.log
  python -u -m dataset.run_pipeline --config dataset/collector.yaml >> logs/harvest.log 2>&1
  echo "=== \$(date -u +%FT%TZ) EXITED rc=\$? ; restart in 30s ===" >> logs/harvest.log
  sleep 30
done
EOF
cat > /root/atc-sync.sh <<EOF
#!/bin/bash
# Every cycle: refresh train_metadata, mirror labels+clips to persistent /root,
# prune raw blocks >6h old (already segmented) to bound disk.
cd $APP || exit 0
source .venv/bin/activate 2>/dev/null
python -c "from dataset import emit_metadata; emit_metadata.to_train_metadata('$STORAGE_ROOT/us_pseudo/manifest.jsonl','$STORAGE_ROOT/us_pseudo/train_metadata.json')" 2>/dev/null
mkdir -p /root/atc-persist
rsync -a --exclude raw_us --exclude raw_us_eval "$STORAGE_ROOT/" /root/atc-persist/ 2>/dev/null
find "$STORAGE_ROOT/raw_us" -type f -name '*.wav' -mmin +360 -delete 2>/dev/null
EOF
cat > /root/atc-monlog.sh <<EOF
#!/bin/bash
while true; do
  echo "\$(date -u +%FT%TZ) accepted=\$(wc -l < $STORAGE_ROOT/us_pseudo/manifest.jsonl 2>/dev/null) outbound=\$(curl -s --max-time 6 https://api.ipify.org)" >> /root/atc-monitor.log
  sleep 900
done
EOF
chmod +x /root/atc-collect.sh /root/atc-sync.sh /root/atc-monlog.sh

echo "===== [6/6] sanity-check LiveATC access on THIS ip, then launch ====="
echo "outbound IP: $(curl -s --max-time 8 https://api.ipify.org)"
timeout 22 ffmpeg -hide_banner -loglevel error \
  -user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  -i https://d.liveatc.net/katl_twr -t 5 -f s16le -ac 1 -ar 16000 /tmp/_atc_test.raw 2>/dev/null
if [ "$(wc -c </tmp/_atc_test.raw 2>/dev/null || echo 0)" -gt 10000 ]; then echo "LiveATC access OK (got audio)"; else echo "WARN: no audio from LiveATC on this IP -- check the IP isn't blocked."; fi
for s in atc sync monlog; do tmux kill-session -t $s 2>/dev/null; done
tmux new-session -d -s atc "bash /root/atc-collect.sh"
tmux new-session -d -s sync "while true; do bash /root/atc-sync.sh; sleep 600; done"
tmux new-session -d -s monlog "bash /root/atc-monlog.sh"
sleep 3; tmux ls
echo
echo "Done. First run auto-downloads models (~4.6GB) then records."
echo "  watch:  tail -f $APP/logs/harvest.log"
echo "  data:   $STORAGE_ROOT   backup: /root/atc-persist   trail: /root/atc-monitor.log"
