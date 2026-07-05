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
export HF_HUB_ENABLE_HF_TRANSFER=1
HF="$HOME/chartenv/bin/hf"
up(){ [ "${UPLOAD:-1}" = "1" ] || return 0; "$HF" upload "$HF_DATASET" "$1" "$2" --repo-type dataset >/dev/null 2>&1 && echo "  up $2"; }

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

echo "== manifest (index.json) =="
CYCLE="$CYCLE" python3 - "$OUT" > "$WORK/index.json" <<'PY'
import sqlite3, glob, os, json, sys
out = sys.argv[1]
def rec(p, sub):
    m = dict(sqlite3.connect(p).execute("select name,value from metadata").fetchall())
    b = [float(x) for x in m["bounds"].split(",")]
    name = os.path.splitext(os.path.basename(p))[0]
    return {"id": name, "bounds": b, "bytes": os.path.getsize(p), "path": f"{sub}/{name}.mbtiles",
            "minzoom": int(m["minzoom"]), "maxzoom": int(m["maxzoom"])}
man = {"cycle": os.environ.get("CYCLE", ""), "sectional": [], "ifrLow": []}
for p in sorted(glob.glob(f"{out}/*_SEC.mbtiles")): man["sectional"].append(rec(p, "sectional"))
for p in sorted(glob.glob(f"{out}/ENR_L*.mbtiles")): man["ifrLow"].append(rec(p, "ifr"))
print(json.dumps(man))
PY
up "$WORK/index.json" "index.json"
python3 -c "import json;d=json.load(open('$WORK/index.json'));print('manifest:',len(d['sectional']),'sectional +',len(d['ifrLow']),'ifr')"
echo "== done =="
