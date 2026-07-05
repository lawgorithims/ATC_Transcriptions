#!/usr/bin/env bash
# build_chart.sh — turn ONE FAA raster aeronautical chart into a spec-compliant, Web-Mercator
# MBTiles with the map collar/legend cropped away (transparent edges) so charts mosaic seamlessly.
#
# This is the atomic unit of the FAA chart pipeline. build_sectional_conus.sh / build_ifr_low.sh
# call it in a loop and then mosaic the results.
#
# Provenance / licensing:
#   * Chart rasters  — FAA Aeronautical Information Services "digital products" (US Gov, public domain).
#   * Collar clip shapes — jlmcgraw/aviationCharts (GPL-3.0), cloned to $CLIP_REPO. Attribution kept
#     in charts/README.md. We reuse only the clip geometry, not their pipeline.
#
# Usage:
#   build_chart.sh sectional New_York                  # -> $OUT/New_York_SEC.mbtiles
#   build_chart.sh warp     sectional New_York         # only produce the cropped 3857 GeoTIFF (for mosaics)
#   FROM_TIF=/path/ENR_L01.tif build_chart.sh enroute ENR_L01   # IFR: chart tif already extracted
#
# Key env (all optional): CYCLE, TILE_FORMAT(PNG|WEBP), QUALITY, ZOOM_OVERVIEWS, OUT, WORK, CLIP_REPO
set -euo pipefail

CYCLE="${CYCLE:-05-14-2026}"                         # FAA 56-day effective date (MM-DD-YYYY)
TILE_FORMAT="${TILE_FORMAT:-PNG}"                     # PNG (universal) or WEBP (≈5× smaller; needs iOS 14+)
QUALITY="${QUALITY:-75}"                              # WEBP/JPEG quality
ZOOM_OVERVIEWS="${ZOOM_OVERVIEWS:-2 4 8 16 32 64 128}" # gdaladdo factors → lower zoom levels
WORK="${WORK:-/tmp/charts/work}"
OUT="${OUT:-/tmp/charts/mbtiles}"
WARPDIR="${WARPDIR:-/tmp/charts/warp}"
CLIP_REPO="${CLIP_REPO:-/tmp/aviationCharts}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

mode="mbtiles"
if [ "${1:-}" = "warp" ]; then mode="warp"; shift; fi
type="${1:?usage: build_chart.sh [warp] <sectional|enroute> <ChartName>}"
name="${2:?missing chart name}"

mkdir -p "$WORK" "$OUT" "$WARPDIR"

# Resolve source raster + clip shape per chart type.
case "$type" in
  sectional)
    clip="${CLIP_REPO}/clippingShapes/sectional/${name}_SEC.shp"
    warp="${WARPDIR}/${name}_SEC.tif"
    mb="${OUT}/${name}_SEC.mbtiles"
    if [ -z "${FROM_TIF:-}" ]; then
      zip="${WORK}/${name}.zip"; dir="${WORK}/${name}"
      # FAA sectional zip names carry the chart title's hyphen where our clip/pack names use underscores
      # (clip Dallas_Ft_Worth_SEC.shp ↔ download Dallas-Ft_Worth.zip). Map the known exceptions.
      urlname="$name"; case "$name" in Dallas_Ft_Worth) urlname="Dallas-Ft_Worth" ;; esac
      url="https://aeronav.faa.gov/visual/${CYCLE}/sectional-files/${urlname}.zip"
      [ -s "$zip" ] || { echo "↓ $url"; curl -fsS -A "$UA" -o "$zip" "$url"; }
      mkdir -p "$dir"; unzip -o -q "$zip" -d "$dir"
      src="$(ls "$dir"/*.tif | head -1)"
    else src="$FROM_TIF"; fi ;;
  enroute)
    clip="${CLIP_REPO}/clippingShapes/enroute/${name}.shp"
    warp="${WARPDIR}/${name}.tif"
    mb="${OUT}/${name}.mbtiles"
    src="${FROM_TIF:?enroute mode needs FROM_TIF=<extracted ENR_*.tif> (from DDECUS.zip)}" ;;
  *) echo "unknown chart type: $type" >&2; exit 2 ;;
esac

[ -f "$clip" ] || { echo "missing clip shape: $clip (clone jlmcgraw/aviationCharts to $CLIP_REPO)" >&2; exit 3; }
[ -f "$src" ]  || { echo "missing source raster: $src" >&2; exit 3; }

echo "▸ $name : $(basename "$src")  clip=$(basename "$clip")"

# 1) Paletted charts (VFR sectionals) expand to RGBA so tiles come out full-colour + alpha; RGB charts
#    (IFR enroute) have no colour table, so they instead get an alpha band added during the warp.
if gdalinfo "$src" 2>/dev/null | grep -q "Color Table"; then
  warpsrc="${WORK}/${name}.rgba.vrt"; dstalpha=""
  gdal_translate -q -of vrt -expand rgba "$src" "$warpsrc"
else
  warpsrc="$src"; dstalpha="-dstalpha"
fi

# 2) Reproject to Web Mercator and crop to the chart neatline; outside-cutline pixels become
#    transparent (alpha 0) so adjacent charts show through — the seamless-mosaic trick.
gdalwarp -q -t_srs EPSG:3857 -r bilinear -co TILED=YES -co COMPRESS=DEFLATE $dstalpha \
  -cutline "$clip" -crop_to_cutline -wo CUTLINE_ALL_TOUCHED=TRUE -multi -overwrite \
  "$warpsrc" "$warp"
echo "  warped → $warp ($(du -h "$warp" | cut -f1))"

if [ "$mode" = "warp" ]; then echo "  (warp-only; mosaic step will consume $warp)"; exit 0; fi

# 3) Pack into a spec-compliant MBTiles (base zoom from raster resolution) + build overview zoom levels.
rm -f "$mb"
gdal_translate -q -of MBTILES -co "TILE_FORMAT=${TILE_FORMAT}" -co "QUALITY=${QUALITY}" "$warp" "$mb"
gdaladdo -q -r average "$mb" $ZOOM_OVERVIEWS
python3 - "$mb" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
m = dict(c.execute("select name,value from metadata").fetchall())
n, zmin, zmax = c.execute("select count(*),min(zoom_level),max(zoom_level) from tiles").fetchone()
print(f"  mbtiles → {sys.argv[1]}  z{zmin}-{zmax}  {n} tiles  fmt={m.get('format')}  bounds={m.get('bounds')}")
PY
