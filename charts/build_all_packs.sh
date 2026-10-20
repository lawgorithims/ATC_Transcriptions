#!/usr/bin/env bash
# build_all_packs.sh — build EVERY per-chart pack for CONUS (VFR sectionals + IFR-low enroute) as its
# own MBTiles, plus an index.json manifest carrying each pack's geographic bounds, then upload to
# HuggingFace. This is what the app's route-aware + free-pan chart loading pulls from: it fetches the
# manifest, then downloads only the packs a route crosses / the map is panned over.
#
# Resumable (skips packs already built). Run on a box bootstrapped by `bootstrap.sh build`.
#   UPLOAD=0 ./build_all_packs.sh     # build locally without pushing to HF
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
# ⚠️ DISABLE XET, OR THE APP CANNOT READ WHAT THIS UPLOADS. Hugging Face migrated this dataset to
# Xet-backed storage, which serves large files only through a chunk-reconstruction protocol the app
# does not speak — its plain anonymous `GET /resolve/main/<path>` gets 403. Every pack uploaded
# without this flag therefore publishes fine and is UNFETCHABLE, and the recovery is
# `rehost_classic_lfs.sh`: re-download and re-upload the whole ~4 GiB dataset to undo it.
# `lz/publish.py` forces the same flag for the same reason. Set BEFORE the hf CLI runs, since
# huggingface_hub reads it when it imports its Xet integration.
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=1
HF="$HOME/chartenv/bin/hf"
# ⚠️ THIS SCRIPT NO LONGER PUBLISHES. It builds packs; `publish_packs.py` publishes them.
#
# It used to do both, badly, in three ways that each shipped something broken while reporting success:
#
#   1. The manifest it wrote had NO `ifrHigh` key — only `sectional` and `ifrLow`. ChartCatalog decodes
#      ifrHigh as optional, so uploading it did not fail; it just TOOK THE IFR-HIGH LAYER AWAY from
#      every pilot until build_ifr_high_conus.sh patched it back in.
#   2. `up()` was `"$HF" upload … >/dev/null 2>&1 && echo`, under `set -uo pipefail` with no `-e`, in
#      loops that `continue` past failures. Every upload error was discarded. A pack could fail to
#      upload and still be named in the manifest.
#   3. It never set HF_HUB_DISABLE_XET, so packs landed Xet-backed and the app's plain anonymous GET
#      got 403 — published, and unreadable.
#
# publish_packs.py has the correct contract: one complete three-family manifest, Xet forced off, every
# pack verified fetchable by an anonymous ranged GET after upload, and index.json written LAST so a
# failure leaves the previous cycle whole. Keeping a second uploader here is how the three defects
# above came back after each was fixed once.
#
#   UPLOAD=0 ./build_all_packs.sh && CYCLE=<cycle> OUT=<out> ~/chartenv/bin/python3 publish_packs.py --publish
up(){
  [ "${UPLOAD:-0}" = "1" ] || return 0
  echo "!! build_all_packs.sh no longer uploads — run publish_packs.py instead (see the note above)." >&2
  exit 2
}

[ -d "$CLIP_REPO/clippingShapes" ] || git clone --depth 1 -q https://github.com/jlmcgraw/aviationCharts.git "$CLIP_REPO"

echo "== VFR sectionals (${#SECTIONALS_CONUS[@]}) =="
for name in "${SECTIONALS_CONUS[@]}"; do
  mb="$OUT/${name}_SEC.mbtiles"
  [ -s "$mb" ] || bash "$HERE/build_chart.sh" sectional "$name" || { echo "!! $name failed"; continue; }
  up "$mb" "sectional/${name}_SEC.mbtiles"
done

echo "== IFR-low enroute (DDECUS.zip is a zip-of-zips; some charts share one N/S combined zip) =="
DD="$WORK/DDECUS.zip"
[ -s "$DD" ] || { echo "↓ DDECUS.zip"; curl -fsS -A "$UA" -o "$DD" "https://aeronav.faa.gov/enroute/${CYCLE}/DDECUS.zip"; }
for n in "${IFR_LOW_CONUS[@]}"; do
  mb="$OUT/${n}.mbtiles"
  if [ ! -s "$mb" ]; then
    nx="$WORK/nx_${n}"; rm -rf "$nx"; mkdir -p "$nx"
    # Prefer a per-chart zip; charts published as split halves (e.g. ENR_L06N/S) live in ENR_L06.zip.
    zipname="${n}.zip"; unzip -l "$DD" 2>/dev/null | grep -q " ${zipname}$" || zipname="${n%[NS]}.zip"
    unzip -o -j "$DD" "$zipname" -d "$nx" >/dev/null 2>&1
    [ -s "$nx/$zipname" ] || { echo "!! $n: $zipname not in DDECUS"; rm -rf "$nx"; continue; }
    unzip -o -j "$nx/$zipname" "${n}.tif" -d "$nx" >/dev/null 2>&1
    [ -s "$nx/${n}.tif" ] || { echo "!! $n: no ${n}.tif inside $zipname"; rm -rf "$nx"; continue; }
    FROM_TIF="$nx/${n}.tif" bash "$HERE/build_chart.sh" enroute "$n" || { echo "!! $n failed"; rm -rf "$nx"; continue; }
    rm -rf "$nx"
  fi
  up "$mb" "ifr/${n}.mbtiles"
done

# The manifest is publish_packs.py's job — see the note at the top. Writing one here produced the
# ifrHigh-less index.json described in defect 1.
echo "== packs built. Publish with:  CYCLE=$CYCLE OUT=$OUT ~/chartenv/bin/python3 $HERE/publish_packs.py --publish"
echo "== done =="
