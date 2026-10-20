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
# ⚠️ See the note in build_all_packs.sh: without HF_HUB_DISABLE_XET these packs upload as
# Xet-backed and the app's plain anonymous GET returns 403 — published but unreadable.
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=1
# ⚠️ RESOLVE THE UPLOADER, AND FAIL IF IT IS NOT THERE. This was hardcoded to
# "$HOME/chartenv/bin/hf" — the author's own Mac venv, a path `bootstrap.sh` NEVER creates (it builds
# "$PREFIX/venv", default ~/faa-charts/venv). So on any Linux box bootstrap.sh had set up, every
# upload invoked a binary that did not exist; `up()` discarded the error and the run reported success
# having published nothing. Prefer whatever is on PATH, then the bootstrap venv, then the legacy Mac
# path, and refuse to continue if none of them is executable.
HF="${HF:-$(command -v hf 2>/dev/null || true)}"
for cand in "${PREFIX:-$HOME/faa-charts}/venv/bin/hf" "$HOME/chartenv/bin/hf"; do
  [ -n "$HF" ] && break
  [ -x "$cand" ] && HF="$cand"
done
[ -n "$HF" ] && [ -x "$HF" ] || { echo "!! no 'hf' binary found (PATH, \$PREFIX/venv/bin, ~/chartenv/bin) — refusing to pretend to upload" >&2; exit 78; }
DATASET_BASE="https://huggingface.co/datasets/${HF_DATASET}/resolve/main"
# FATAL on failure, and no `2>&1`. The old form hid every upload error behind /dev/null under
# `set -uo pipefail` with no `-e`, so a pack could fail to upload and still be named in the manifest.
# ⚠️ UPLOAD IS OFF BY DEFAULT NOW. build_all_packs.sh was retired as a publisher and this script was
# not, so it stayed a SECOND one — uploading packs and then re-publishing a rewritten index.json
# composed by the inline Python below, with no faa_cycle check anywhere. Two publishers is precisely
# how the ifrHigh-less manifest and the Xet 403 each came back after being fixed once.
#
#   UPLOAD=0 ./build_ifr_high_conus.sh && CYCLE=<cycle> OUT=<out> publish_packs.py --publish
up(){
  [ "${UPLOAD:-0}" = "1" ] || return 0
  "$HF" upload "$HF_DATASET" "$1" "$2" --repo-type dataset >/dev/null \
    || { echo "!! upload FAILED: $2" >&2; exit 1; }
  echo "  up $2"
}

[ -d "$CLIP_REPO/clippingShapes" ] || git clone --depth 1 -q https://github.com/jlmcgraw/aviationCharts.git "$CLIP_REPO"

echo "== IFR-high enroute (${#IFR_HIGH_CONUS[@]} charts, cycle $CYCLE) =="
built=(); nbuilt=0
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
  [ -s "$mb" ] && { up "$mb" "ifrhigh/${n}.mbtiles"; built+=("$mb"); nbuilt=$((nbuilt + 1)); }
done

# `set -u` makes ${#built[@]} on an EMPTY array a fatal "unbound variable" (bash 3.2, which is
# what macOS ships) — which is exactly what
# happened when all 12 charts failed: the real error scrolled past and the script died on its own
# bookkeeping. Guard the count, and refuse to rewrite the hosted manifest with zero packs (that would
# publish an empty ifrHigh array and take the layer away from every pilot).
if [ "$nbuilt" -eq 0 ]; then
  echo "!! no IFR-high packs built — leaving the hosted index.json untouched" >&2
  exit 1
fi
# ⚠️ THIS MERGE INHERITS THE HOSTED MANIFEST'S `cycle`, NOT THE ONE THESE PACKS WERE BUILT AT.
# It starts from the published index.json and replaces only `ifrHigh`, so running this after a
# cycle rebuild stamps the NEW packs with the OLD cycle — observed on 2026-09-12, where 86 packs
# built at 09-03-2026 produced a manifest reading cycle=07-09-2026. The app reads `cycle` to
# decide what is current and what to prune, so that manifest is worse than none.
# Use `publish_packs.py` for a full-cycle publish; this path is only safe for adding ifrHigh to
# an already-correct hosted cycle.
echo "== merge ifrHigh into hosted index.json ($nbuilt packs) =="
curl -fsSL --max-time 60 "${DATASET_BASE}/index.json" -o "$WORK/index_hosted.json" \
  || { echo "!! could not fetch hosted index.json"; exit 1; }

python3 - "$WORK/index_hosted.json" "$WORK/index.json" "${built[@]}" <<'PY'
import sqlite3, os, json, sys
hosted, outp, packs = sys.argv[1], sys.argv[2], sys.argv[3:]
def rec(p):
    # Refuse a pack that does not say it is this cycle. The surrounding script can still be opted
    # into publishing (UPLOAD=1), and this manifest names whatever is on disk — which on a shared
    # scratch directory is last cycle's packs.
    _m = dict(sqlite3.connect(p).execute("select name,value from metadata").fetchall())
    _want = os.environ.get("CYCLE", "")
    if _want and _m.get("faa_cycle") not in (None, _want):
        raise SystemExit(f"REFUSING {os.path.basename(p)}: stamped faa_cycle={_m.get('faa_cycle')!r}, "
                         f"publishing {_want!r}. Rebuild into a cycle-scoped OUT.")
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
