#!/bin/zsh
# The whole avoid-map build, unattended: national inputs → cells → merge → gate → bands. It stops short
# of publishing: `publish.py --publish` is the owner's call, made on the gate's numbers.
#
#   nohup caffeinate -i zsh lz/avoid/build.sh > ~/avoid-work/logs/build.log 2>&1 &
#
# Writes $AVOID_WORK/logs/build.status LAST: "ok …" or "failed: <stage>". Terrain-derived intermediates
# (the cells' per-pixel slope and the merge's staging copy of it) are deleted the moment the gate passes;
# the owner keeps no terrain on this machine. Everything else in $AVOID_WORK goes after publishing.
set -u
REPO=${0:A:h:h:h}
W=${AVOID_WORK:-$HOME/avoid-work}
PY=${AVOID_PYTHON:-$(command -v python3)}        # the python with GDAL
A=$REPO/lz/avoid
mkdir -p $W/logs
rm -f $W/logs/build.status
step() { echo "=== $1 $(date +%H:%M:%S)"; }
fail() { echo "BUILD FAILED at $1 $(date +%H:%M:%S)"; echo "failed: $1" > $W/logs/build.status; exit 1; }

step fetch
zsh $A/fetch_national.sh > $W/logs/fetch.log 2>&1 || fail fetch
# get() reports a short file in the log, not in its exit code; the GeoPackage is an unused spare.
# (awk, not grep -v: this machine's grep is ugrep, and its -qv says "found" on empty input.)
awk '/^FAIL/ && !/hifld_lines\.gpkg/ { bad = 1 } END { exit !bad }' $W/logs/fetch.log && fail fetch
step prep
$PY -I $A/prep.py > $W/logs/prep.log 2>&1 || fail prep
step cells
$PY -I $A/run.py --workers 6 > $W/logs/run.log 2>&1 || fail cells
# A failed cell is a hole in the map, and a land cell gone "empty" is one too (a land-cover read that
# returned nothing): 955 cells held land on 2026-10-29, and the land does not move.
$PY -I -c 'import json, sys; s = json.load(open(sys.argv[1])); c = s["counts"]
sys.exit(0 if not s["not_ok"] and c.get("ok", 0) >= 955 else f"cells: {c}, not ok: {s['"'"'not_ok'"'"'][:20]}")' \
    $W/logs/summary.json || fail cells
step merge
$PY -I $A/merge.py > $W/logs/merge.log 2>&1 || fail merge
step gate
$PY -I $A/gate.py --json $W/logs/gate.json > $W/logs/gate.log 2>&1 || fail gate
step shard
$PY -I $A/shard.py > $W/logs/shard.log 2>&1 || fail shard
cp $W/out/avoid_conus.mbtiles.json $W/out/shards/shards.json $W/logs/
step "delete terrain-derived intermediates"
rm -rf $W/cells $W/merge_stage.sqlite
echo "ok $(date +%Y-%m-%dT%H:%M:%S) $(du -sh $W/out/shards | cut -f1) in bands" > $W/logs/build.status
step done
