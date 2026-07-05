# Self-hosted FAA chart tiles

A pipeline + tile server that turns official FAA raster aeronautical charts (VFR **sectionals** and
IFR **enroute low**) into a seamless Web-Mercator tile set (MBTiles + XYZ) that CommSight renders as a
real chart base layer — the same charts a pilot uses, working fully offline in the cockpit.

## Why self-hosted

The public chart-tile services are dead (ChartBundle) or hobby/donation efforts inappropriate to
depend on (vfrmap.com). The FAA source rasters are public domain, so we build our own tiles and host
them ourselves — on the Mac mini today, on a dedicated box later via [`bootstrap.sh`](bootstrap.sh).

## Data sources & licensing

| Piece | Source | License |
|-------|--------|---------|
| Sectional / IFR raster charts | [FAA Aeronautical Information Services digital products](https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/) | US Government — public domain |
| Chart collar/neatline clip shapes | [jlmcgraw/aviationCharts](https://github.com/jlmcgraw/aviationCharts) | GPL-3.0 (we reuse only the clip geometry) |

Charts are on a **56-day cycle**; bump `CYCLE` in [`charts.conf`](charts.conf) to the current
effective date and rerun. Built tiles live in the HuggingFace dataset
[`SingularityUS/faa-charts`](https://huggingface.co/datasets/SingularityUS/faa-charts).

## How it works

```
FAA GeoTIFF (Lambert Conformal, with legend collar)
   │  gdal_translate -expand rgba         → full-colour + alpha
   │  gdalwarp -t_srs EPSG:3857 -cutline <clip>.shp -crop_to_cutline   → collar removed, reprojected
   │  gdal_translate -of MBTILES + gdaladdo                            → spec MBTiles + overview zooms
   ▼
per-chart .mbtiles ──(gdalbuildvrt mosaic)──▶ conus_sectional.mbtiles ──▶ HuggingFace + tileserver.py
```

Cropping to each chart's neatline makes the transparent-edged charts mosaic seamlessly; that clip
geometry is the one genuinely hard-to-produce input, which is why we reuse jlmcgraw's shapes.

## Files

- [`build_chart.sh`](build_chart.sh) — the atomic unit: one chart → one `.mbtiles` (or a `warp`-only GeoTIFF for mosaics).
- [`build_sectional_conus.sh`](build_sectional_conus.sh) — all 37 CONUS sectionals → one seamless mosaic, disk-careful + resumable, optional HF upload.
- [`charts.conf`](charts.conf) — cycle, tile format, and the CONUS chart lists.
- [`tileserver.py`](tileserver.py) — zero-dependency XYZ server over the MBTiles (`/<layer>/<z>/<x>/<y>`, `/<layer>.json` TileJSON, `/health`). stdlib only.
- [`bootstrap.sh`](bootstrap.sh) — stand the whole thing up on a fresh macOS/Debian box (`serve` and/or `build` roles).

## Quick start

Build one chart and serve it:

```bash
git clone --depth 1 https://github.com/jlmcgraw/aviationCharts.git /tmp/aviationCharts
./build_chart.sh sectional New_York                 # -> /tmp/charts/mbtiles/New_York_SEC.mbtiles
MBTILES_DIR=/tmp/charts/mbtiles PORT=8088 python3 tileserver.py
# tiles at  http://<host>:8088/New_York_SEC/{z}/{x}/{y}
```

Build the whole CONUS sectional mosaic and push to HuggingFace:

```bash
UPLOAD=1 ./build_sectional_conus.sh
```

Stand up a fresh hosting box (pulls the built tiles from HF, no rebuild):

```bash
HF_TOKEN=hf_xxx ./bootstrap.sh serve
```

## Secrets

The HuggingFace token is **never** committed. It's read from `$HF_TOKEN` or `~/.hf_token`
(`chmod 600`). Pulling a public dataset needs no token; only building/uploading does.

## Production serving

`tileserver.py` runs fine standalone. For a real host, front it with a caching reverse proxy
(nginx/Caddy) and keep it alive with `launchd` (macOS) or a `systemd` unit (Linux) — the tiles are
immutable per cycle, so cache aggressively (`Cache-Control: public, max-age=604800`, already set).
