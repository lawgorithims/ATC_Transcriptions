#!/usr/bin/env bash
#
# fetch_gps_almanac.sh — refresh the bundled GPS almanac used by the Satellites page.
#
# WHY AN ALMANAC AT ALL
#   iOS exposes NO measured satellite data: no DOP, no satellite count, no per-satellite SNR, and no
#   raw GNSS measurements (that is Android's GnssMeasurement API, and there is no Apple entitlement
#   for it). So the Satellites page computes the constellation from published orbital elements — the
#   same thing an aviation RAIM-prediction tool does. Everything derived from this file is PREDICTED
#   geometry, never a measurement, and the UI must keep saying so.
#
# SOURCE
#   CelesTrak's YUMA-format GPS almanac (https://celestrak.org/GPS/almanac/Yuma/), which republishes
#   the US Coast Guard NAVCEN broadcast almanac. US government-produced GNSS almanac data is public
#   domain; CelesTrak asks for attribution, which the Satellites page carries.
#
# STALENESS
#   An almanac degrades slowly — it stays usable for weeks and is still broadly right after a couple
#   of months, because it describes orbits that barely change. The app compares the file's GPS week
#   against the current date and DOWNGRADES the page (and refuses to claim jamming, which depends on
#   trusting the predicted geometry) once it is too old, rather than quietly showing stale geometry.
#   Re-run this script whenever you ship a build; it is a ~19 KB text file.
#
# USAGE
#   bash Tools/fetch_gps_almanac.sh            # newest almanac -> Resources/gps/almanac.yuma.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../ATCTranscribe/Resources/gps"
DEST="$DEST_DIR/almanac.yuma.txt"
YEAR="$(date -u +%Y)"
INDEX="https://celestrak.org/GPS/almanac/Yuma/$YEAR/"

log() { printf '\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$DEST_DIR"

log "listing $INDEX"
# The index lists almanac.yuma.week<WWWW>.<SSSSSS>.txt; the last one sorted is the newest.
NEWEST="$(curl -fsS --max-time 60 "$INDEX" \
          | grep -oE 'almanac\.yuma\.week[0-9]+\.[0-9]+\.txt' \
          | sort -u | tail -1)" || die "could not list the almanac index (network?)"
[ -n "$NEWEST" ] || die "no almanac files found at $INDEX"

log "downloading $NEWEST"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsS --max-time 120 -o "$TMP" "$INDEX$NEWEST" || die "download failed"

# Refuse to install something that is not an almanac: it must have ID/Health/SQRT(A) records for a
# plausible number of satellites. A truncated or HTML error page must never reach the bundle.
SVS="$(grep -c '^ID:' "$TMP" || true)"
[ "$SVS" -ge 24 ] || die "only $SVS SV records parsed from $NEWEST — refusing to install"
grep -q 'SQRT(A)' "$TMP" || die "no SQRT(A) field — not a YUMA almanac"

mv "$TMP" "$DEST"
trap - EXIT
WEEK="$(grep -m1 -oE 'week[[:space:]]*:?[[:space:]]*[0-9]+' "$DEST" | grep -oE '[0-9]+' | tail -1 || echo '?')"
log "installed $SVS SVs (GPS week $WEEK) -> $DEST"
echo "Remember: this is PREDICTED geometry. iOS reports no measured satellites."
