#!/usr/bin/env bash
# build_sectional_conus.sh — build ONE seamless CONUS VFR sectional mosaic MBTiles from all 37
# conterminous-US sectionals, then (optionally) upload it to HuggingFace.
#
# Disk-careful: each chart is downloaded, cropped+reprojected to a compressed GeoTIFF, then its
# source zip is deleted before moving on — so peak disk is ~(all warped tifs) not ~(all sources).
# Resumable: a chart whose warped tif already exists is skipped.
#
#   ./build_sectional_conus.sh              # build the mosaic
#   UPLOAD=1 ./build_sectional_conus.sh     # build + push to HF ($HF_DATASET)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/charts.conf"

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"   # macOS: put gdal on PATH
export WORK="${WORK:-/tmp/charts/work}"
export WARPDIR="${WARPDIR:-/tmp/charts/warp}"
export OUT="${OUT:-/tmp/charts/mbtiles}"
export CLIP_REPO="${CLIP_REPO:-/tmp/aviationCharts}"
mkdir -p "$WORK" "$WARPDIR" "$OUT"

# Clip shapes (jlmcgraw) — clone once if missing.
[ -d "$CLIP_REPO/clippingShapes" ] || git clone --depth 1 -q https://github.com/jlmcgraw/aviationCharts.git "$CLIP_REPO"

echo "== CONUS sectional mosaic :: cycle $CYCLE :: ${#SECTIONALS_CONUS[@]} charts :: fmt $TILE_FORMAT =="
i=0
for name in "${SECTIONALS_CONUS[@]}"; do
  i=$((i+1)); warp="$WARPDIR/${name}_SEC.tif"
  if [ -s "$warp" ]; then echo "[$i/${#SECTIONALS_CONUS[@]}] $name — already warped, skip"; continue; fi
  echo "[$i/${#SECTIONALS_CONUS[@]}] $name"
  if CYCLE="$CYCLE" bash "$HERE/build_chart.sh" warp sectional "$name"; then
    rm -rf "$WORK/${name}.zip" "$WORK/${name}"          # reclaim disk immediately
  else
    echo "  !! $name failed — continuing (mosaic will omit it)"; fi
done

echo "== mosaic → MBTiles =="
vrt="$WORK/conus_sectional.vrt"
mb="$OUT/conus_sectional.mbtiles"
gdalbuildvrt -q -overwrite "$vrt" "$WARPDIR"/*_SEC.tif
rm -f "$mb"
gdal_translate -q -of MBTILES -co "TILE_FORMAT=${TILE_FORMAT}" -co "QUALITY=${QUALITY}" "$vrt" "$mb"
gdaladdo -q -r average "$mb" 2 4 8 16 32 64 128 256
python3 - "$mb" <<'PY'
import sqlite3, sys, os
c = sqlite3.connect(sys.argv[1]); m = dict(c.execute("select name,value from metadata").fetchall())
n, zmin, zmax = c.execute("select count(*),min(zoom_level),max(zoom_level) from tiles").fetchone()
print(f"  {sys.argv[1]}  {os.path.getsize(sys.argv[1])//(1<<20)} MB  z{zmin}-{zmax}  {n} tiles  fmt={m.get('format')}")
PY

if [ "${UPLOAD:-0}" = "1" ]; then
  echo "== upload → HF $HF_DATASET =="
  export HF_TOKEN="${HF_TOKEN:-$(cat "$HOME/.hf_token" 2>/dev/null || true)}"
  export HF_HUB_ENABLE_HF_TRANSFER=1
  "$HOME/chartenv/bin/hf" upload "$HF_DATASET" "$mb" "sectional/conus_sectional.mbtiles" --repo-type dataset
fi
echo "== done =="
