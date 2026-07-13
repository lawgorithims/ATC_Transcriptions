#!/usr/bin/env bash
# build_ifr_high_conus.sh — build the 12 US IFR Enroute HIGH charts (ENR_H01–H12) into per-chart
# MBTiles, upload them to the HuggingFace dataset under ifrhigh/, then MERGE an `ifrHigh` array into
# the existing hosted index.json (keeping the current cycle + the already-hosted sectional/ifrLow packs
# untouched — so the app doesn't see a new cycle and re-download everything).
#
# The IFR-high charts, unlike the low set (one DDECUS.zip bundle), are published as individual per-chart
# zips at enroute/<cycle>/ENR_H##.zip, each containing ENR_H##.tif. jlmcgraw ships matching enroute
# clip shapes, so build_chart.sh's `enroute` path tiles them exactly like the low charts.
#
#   UPLOAD=0 ./build_ifr_high_conus.sh     # build locally without pushing to HF
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/charts.conf"
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"
export CLIP_REPO="${CLIP_REPO:-/tmp/aviationCharts}"
export OUT="${OUT:-/tmp/charts/packs}"
export WORK="${WORK:-/tmp/charts/work}"
export WARPDIR="${WARPDIR:-/tmp/charts/warp}"
mkdir -p "$OUT" "$WORK" "$WARPDIR"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
export HF_TOKEN="${HF_TOKEN:-$(cat "$HOME/.hf_token" 2>/dev/null || true)}"
export HF_HUB_ENABLE_HF_TRANSFER=1
HF="$HOME/chartenv/bin/hf"
DATASET_BASE="https://huggingface.co/datasets/${HF_DATASET}/resolve/main"
up(){ [ "${UPLOAD:-1}" = "1" ] || return 0; "$HF" upload "$HF_DATASET" "$1" "$2" --repo-type dataset >/dev/null 2>&1 && echo "  up $2"; }

[ -d "$CLIP_REPO/clippingShapes" ] || git clone --depth 1 -q https://github.com/jlmcgraw/aviationCharts.git "$CLIP_REPO"

echo "== IFR-high enroute (${#IFR_HIGH_CONUS[@]} charts, cycle $CYCLE) =="
built=()
for n in "${IFR_HIGH_CONUS[@]}"; do
  mb="$OUT/${n}.mbtiles"
  if [ ! -s "$mb" ]; then
    nx="$WORK/nx_${n}"; rm -rf "$nx"; mkdir -p "$nx"
    zip="$nx/${n}.zip"
    url="https://aeronav.faa.gov/enroute/${CYCLE}/${n}.zip"
    echo "↓ $url"
    curl -fsS -A "$UA" -o "$zip" "$url" || { echo "!! $n: download failed"; rm -rf "$nx"; continue; }
    unzip -o -j "$zip" "${n}.tif" -d "$nx" >/dev/null 2>&1
    [ -s "$nx/${n}.tif" ] || { echo "!! $n: no ${n}.tif inside zip"; rm -rf "$nx"; continue; }
    FROM_TIF="$nx/${n}.tif" bash "$HERE/build_chart.sh" enroute "$n" || { echo "!! $n failed"; rm -rf "$nx"; continue; }
    rm -rf "$nx"
  fi
  [ -s "$mb" ] && { up "$mb" "ifrhigh/${n}.mbtiles"; built+=("$mb"); }
done

echo "== merge ifrHigh into hosted index.json (${#built[@]} packs) =="
curl -fsSL --max-time 60 "${DATASET_BASE}/index.json" -o "$WORK/index_hosted.json" \
  || { echo "!! could not fetch hosted index.json"; exit 1; }

python3 - "$WORK/index_hosted.json" "$WORK/index.json" "${built[@]}" <<'PY'
import sqlite3, os, json, sys
hosted, outp, packs = sys.argv[1], sys.argv[2], sys.argv[3:]
def rec(p):
    m = dict(sqlite3.connect(p).execute("select name,value from metadata").fetchall())
    b = [float(x) for x in m["bounds"].split(",")]
    name = os.path.splitext(os.path.basename(p))[0]
    return {"id": name, "bounds": b, "bytes": os.path.getsize(p), "path": f"ifrhigh/{name}.mbtiles"}
idx = json.load(open(hosted))
idx["ifrHigh"] = sorted((rec(p) for p in packs), key=lambda r: r["id"])
json.dump(idx, open(outp, "w"), separators=(",", ":"))
print(f"  index.json: cycle={idx.get('cycle')} sectional={len(idx.get('sectional',[]))} "
      f"ifrLow={len(idx.get('ifrLow',[]))} ifrHigh={len(idx['ifrHigh'])}")
PY

up "$WORK/index.json" "index.json"
echo "== done =="
