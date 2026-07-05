#!/usr/bin/env bash
# bootstrap.sh — stand up the FAA chart tile server on a FRESH box (macOS or Debian/Ubuntu).
#
# Two roles, combine as needed:
#   serve  (default) — install runtime deps, pull the built MBTiles from HuggingFace, run tileserver.py
#   build            — also install GDAL + a Python venv so you can (re)build tiles from FAA source
#
#   HF_TOKEN=hf_xxx ./bootstrap.sh serve            # quickest: just host what's already on HF
#   HF_TOKEN=hf_xxx ./bootstrap.sh build serve      # full node that can rebuild + host
#
# The HF token is read from $HF_TOKEN or ~/.hf_token and is NEVER written into the repo. For a public
# HF dataset the pull needs no token at all — only the upload side (building) does.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/charts.conf" 2>/dev/null || true

ROLES=" ${*:-serve} "
PREFIX="${PREFIX:-$HOME/faa-charts}"
export MBTILES_DIR="${MBTILES_DIR:-$PREFIX/mbtiles}"
PORT="${PORT:-8088}"
HF_DATASET="${HF_DATASET:-SingularityUS/faa-charts}"
mkdir -p "$MBTILES_DIR"

# ---- package manager abstraction ---------------------------------------------------------------
if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || brew shellenv)"
  PKG_INSTALL() { brew list "$1" >/dev/null 2>&1 || brew install "$1"; }
elif command -v apt-get >/dev/null 2>&1; then
  SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
  $SUDO apt-get update -qq
  PKG_INSTALL() { dpkg -s "$1" >/dev/null 2>&1 || $SUDO apt-get install -y -qq "$1"; }
else
  echo "unsupported OS (need brew or apt-get)"; exit 1
fi

echo "== base deps =="
PKG_INSTALL python3; PKG_INSTALL git; PKG_INSTALL curl

# ---- build role: GDAL + Python venv for the pipeline -------------------------------------------
if [[ "$ROLES" == *" build "* ]]; then
  echo "== build deps (GDAL) =="
  if command -v apt-get >/dev/null 2>&1; then PKG_INSTALL gdal-bin; PKG_INSTALL python3-venv; else PKG_INSTALL gdal; fi
  python3 -m venv "$PREFIX/venv"
  "$PREFIX/venv/bin/pip" install -q --upgrade pip huggingface_hub hf_transfer
  [ -d "$PREFIX/aviationCharts/clippingShapes" ] || \
    git clone --depth 1 -q https://github.com/jlmcgraw/aviationCharts.git "$PREFIX/aviationCharts"
  echo "  build tools ready — run: CLIP_REPO=$PREFIX/aviationCharts OUT=$MBTILES_DIR $HERE/build_sectional_conus.sh"
fi

# ---- pull built tiles from HF -----------------------------------------------------------------
echo "== pull MBTiles from HF ($HF_DATASET) =="
export HF_TOKEN="${HF_TOKEN:-$(cat "$HOME/.hf_token" 2>/dev/null || true)}"
export HF_HUB_ENABLE_HF_TRANSFER=1
HF_BIN="$PREFIX/venv/bin/hf"
if [ ! -x "$HF_BIN" ]; then
  python3 -m venv "$PREFIX/venv"; "$PREFIX/venv/bin/pip" install -q --upgrade pip huggingface_hub hf_transfer
fi
# Download every *.mbtiles in the dataset into MBTILES_DIR (flattened).
"$HF_BIN" download "$HF_DATASET" --repo-type dataset --include "*.mbtiles" \
  --local-dir "$PREFIX/hf_cache" || echo "  (nothing to pull yet — build + upload first)"
find "$PREFIX/hf_cache" -name '*.mbtiles' -exec cp -f {} "$MBTILES_DIR/" \; 2>/dev/null || true
echo "  layers in $MBTILES_DIR: $(ls "$MBTILES_DIR"/*.mbtiles 2>/dev/null | wc -l | tr -d ' ')"

# ---- run the server ---------------------------------------------------------------------------
if [[ "$ROLES" == *" serve "* ]]; then
  echo "== launch tile server on :$PORT =="
  echo "   (foreground; for production wrap in systemd/launchd — see charts/README.md)"
  MBTILES_DIR="$MBTILES_DIR" PORT="$PORT" exec python3 "$HERE/tileserver.py"
fi
