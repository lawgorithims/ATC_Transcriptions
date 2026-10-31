#!/bin/zsh
# National inputs for the avoid map (lz/avoid/), fetched ONCE into $AVOID_WORK/shared, then prep.py.
# Transient: delete them after the build — the published map is the product, not these.
set -u
mkdir -p "${AVOID_WORK:-$HOME/avoid-work}/shared" && cd "${AVOID_WORK:-$HOME/avoid-work}/shared" || exit 1
get() {  # url file min_bytes
  local url=$1 f=$2 min=$3
  if [ -f "$f" ] && [ $(stat -f%z "$f") -ge $min ]; then echo "have $f"; return 0; fi
  for i in 1 2 3; do
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -sS -o "$f.part" "$url" && mv "$f.part" "$f" && break
    echo "retry $i for $f"; sleep 10
  done
  local sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  if [ "$sz" -lt "$min" ]; then echo "FAIL $f: $sz bytes < $min"; return 1; fi
  echo "ok $f $sz"
}
get "https://storage.googleapis.com/hifld-next-datasets-prod/hifld/transmission-lines-1/transmission-lines-1/v1.0.0/geoparquet/transmission-lines-1.parquet" hifld_lines.parquet 30000000
get "https://storage.googleapis.com/hifld-next-datasets-prod/hifld/transmission-lines-1/transmission-lines-1/v1.0.0/gpkg/transmission-lines-1.gpkg" hifld_lines.gpkg 60000000 || true
get "https://energy.usgs.gov/uspvdb/assets/data/uspvdbGeoJSON.zip" uspvdb.zip 5000000
get "https://energy.usgs.gov/uswtdb/assets/data/uswtdbGeoJSON.zip" uswtdb.zip 800000
get "https://aeronav.faa.gov/Obst_Data/DAILY_DOF_CSV.ZIP" dof.zip 10000000
get "https://www.mrlc.gov/downloads/sciweb1/shared/mrlc/data-bundles/Annual_NLCD_LndCov_2025_CU_C1V2.zip" nlcd2025.zip 1000000000
get "https://www.nass.usda.gov/Research_and_Science/Cropland/Release/datasets/2025_30m_cdls.zip" cdl2025.zip 1000000000
echo "=== downloads done $(date +%H:%M:%S)"
for z in uspvdb.zip uswtdb.zip dof.zip nlcd2025.zip cdl2025.zip; do mkdir -p "${z%.zip}" && unzip -o -q "$z" -d "${z%.zip}" && echo "unzipped $z"; done
echo "=== all done $(date +%H:%M:%S)"
