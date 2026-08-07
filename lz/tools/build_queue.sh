#!/usr/bin/env bash
# Pacific run, resumed after the previous process was killed mid-flight. Same guards as
# build_night.sh. NOT publishing at the end this time — publish is gated on verify receipts now,
# and the already-built cells need theirs minted separately.
set -uo pipefail
ROOT=/Users/bsusl/CommSight/ATC_Transcriptions
S=/private/tmp/claude-501/-Users-bsusl/9d2aac48-9e5c-4de6-a943-c605eaeb11b0/scratchpad
Q="$S/queue.log"
MIN_FREE_GB=60
CELLS="n33w116 n33w118 n35w119 n36w119 n37w119 n34w120 n35w120 n36w120 n37w120 \
       n34w121 n35w121 n36w121 n37w121 n36w122 n37w122"
# ⚠️ PREFLIGHT, BEFORE A SINGLE CELL IS TOUCHED.
#
# Under launchd the PATH is /usr/bin:/bin:/usr/sbin:/sbin — no /opt/homebrew — so `gdalinfo` and
# `ogr2ogr` vanish and `python3` resolves to Xcode's 3.9, which has no osgeo. Every cell then fails
# in the coverage gate in about 25 seconds. That part is CORRECT; the gate refused to build on
# unreadable sources rather than emit an empty hazard plane.
#
# What was not correct: `launchctl submit` respawns a job when it exits, so the queue re-attempted
# all fifteen cells every seven minutes for thirteen hours, producing nothing and saying so only in
# a log nobody was reading. Failing fast fifteen times an hour is not failing loudly.
#
# So: state the PATH rather than inherit it, and refuse to start at all if the toolchain is not
# actually there.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for tool in gdalinfo ogr2ogr; do
  command -v "$tool" >/dev/null || { echo "PREFLIGHT FAIL: $tool not on PATH — refusing to start"; exit 78; }
done
python3 -c "from osgeo import gdal" 2>/dev/null \
  || { echo "PREFLIGHT FAIL: python3 ($(command -v python3)) has no osgeo — refusing to start"; exit 78; }
echo "preflight ok: $(command -v python3), gdal $(gdalinfo --version)"

free_gb() { df -g "$ROOT" | tail -1 | awk '{print $4}'; }
echo "########## PACIFIC RESUME $(date '+%F %H:%M:%S')  free $(free_gb)GB" >> "$Q"
OK=0; FAIL=0
for cell in $CELLS; do
  [ -f "$ROOT/lz/out/$cell.lzpack" ] && { echo "skip $cell (built)" | tee -a "$Q"; continue; }
  FREE=$(free_gb)
  [ "$FREE" -lt "$MIN_FREE_GB" ] && { echo "STOPPING: ${FREE}GB free" | tee -a "$Q"; break; }
  echo "---------- $cell  $(date '+%H:%M:%S')  free ${FREE}GB" | tee -a "$Q"
  if bash "$S/build_cell.sh" "$cell" >> "$Q" 2>&1; then
    echo "DONE $cell $(date '+%H:%M:%S')  $(du -h "$ROOT/lz/out/$cell.lzpack" 2>/dev/null | cut -f1)" | tee -a "$Q"; OK=$((OK+1))
  else
    echo "FAILED $cell $(date '+%H:%M:%S')" | tee -a "$Q"; FAIL=$((FAIL+1))
    rm -rf "$ROOT/lz/work/$cell" "$ROOT/lz/data/$cell"
  fi
done
if ls "$ROOT/lz/terrain_archive"/elev10m_*.tif >/dev/null 2>&1; then
  (cd "$ROOT" && ~/chartenv/bin/python3 lz/publish_terrain.py --all >> "$Q" 2>&1) || true
fi
echo "########## PACIFIC END $(date '+%F %H:%M:%S')  ok=$OK failed=$FAIL  free $(free_gb)GB" | tee -a "$Q"
