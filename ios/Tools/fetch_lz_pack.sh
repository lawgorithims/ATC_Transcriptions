#!/usr/bin/env bash
#
# Install a landability pack into a Simulator so the LZ tests can actually run.
#
# WHY THIS EXISTS. `LZLayerUITests.testTheRankedListNamesSeveralDistinctPlaces` holds the aeroplane
# over KLRU (32.2894 / -106.9219) and asserts the ranked list names at least three distinct places.
# It was failing on a green iPad with "only 0 candidate(s)", which reads exactly like the search
# regression the test was written to catch — and was not one. The Simulator had a pack installed, so
# the test's "no .lzpack" guard passed, but the pack was n32w112 (Arizona). Nothing covered Las
# Cruces, so the search honestly found nothing.
#
# CELL NAMING, because getting it backwards is the whole trap: the name marks a cell's NORTH-WEST
# corner and the cell extends one degree SOUTH and one degree EAST (USGS 3DEP; lz/lzcommon.py:89).
# So KLRU at 32.29°N / 106.92°W is covered by n33w107 — which runs 32–33°N, 106–107°W — NOT by a
# cell called n32w107, which does not exist in the published dataset.
#
#   bash Tools/fetch_lz_pack.sh                       # n33w107 (KLRU) into the booted Simulator
#   bash Tools/fetch_lz_pack.sh n32w112               # some other cell
#   SIM="iPad Pro 13-inch (M5)" bash Tools/fetch_lz_pack.sh
#
# The pack is ~92 MB and is NOT in this repo (see the HuggingFace dataset in lz/publish.py). The app
# downloads packs itself in normal use; this is only to seed a Simulator for a test run.
#
set -euo pipefail
cd "$(dirname "$0")/.."            # → ios/

CELL="${1:-n33w107}"
BASE="https://huggingface.co/datasets/SingularityUS/commsight-lz/resolve/main"
BUNDLE_ID="com.flycommsight.atctranscribe"

# Which Simulator: $SIM by name, else the booted one.
if [ -n "${SIM:-}" ]; then
  DEV=$(xcrun simctl list devices available | grep -F "$SIM (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -z "$DEV" ] && { echo "!! no available simulator named '$SIM'"; exit 1; }
else
  DEV=$(xcrun simctl list devices | grep "(Booted)" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -z "$DEV" ] && { echo "!! no booted simulator. Boot one, or set SIM='iPad Pro 13-inch (M5)'."; exit 1; }
fi

# The container only exists once the app has been installed on that device at least once.
CONTAINER=$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" data 2>/dev/null || true)
if [ -z "$CONTAINER" ]; then
  echo "!! $BUNDLE_ID is not installed on $DEV. Run the suite once first (bash Tools/uitests.sh),"
  echo "!! then re-run this script and run it again."
  exit 1
fi

DEST="$CONTAINER/Library/Application Support/lz"
mkdir -p "$DEST"

if [ -f "$DEST/$CELL.lzpack" ]; then
  echo "== $CELL.lzpack already installed in $DEST"
  exit 0
fi

echo "== fetching $CELL.lzpack (~92 MB for n33w107) =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar "$BASE/cells/$CELL.lzpack" -o "$TMP/$CELL.lzpack"

# Verify against the catalog the app already keeps next to the packs, when one is there. A pack that
# is really an HTML error page saved under a .lzpack name is a documented failure mode
# (LZPackLibrary.swift:236), and it would land here as a test failure rather than a download failure.
if [ -f "$DEST/catalog.json" ]; then
  WANT=$(python3 -I -c "
import json,sys
cells = json.load(open(sys.argv[1]))['cells']
print(next((c.get('sha256','') for c in cells if c.get('id') == sys.argv[2]), ''))
" "$DEST/catalog.json" "$CELL")
  if [ -n "$WANT" ]; then
    GOT=$(shasum -a 256 "$TMP/$CELL.lzpack" | cut -d' ' -f1)
    if [ "$WANT" != "$GOT" ]; then
      echo "!! sha256 mismatch for $CELL — refusing to install."
      echo "!!   catalog: $WANT"
      echo "!!   fetched: $GOT"
      exit 1
    fi
    echo "== sha256 matches the catalog"
  fi
fi

mv "$TMP/$CELL.lzpack" "$DEST/$CELL.lzpack"
echo "== installed → $DEST/$CELL.lzpack"
