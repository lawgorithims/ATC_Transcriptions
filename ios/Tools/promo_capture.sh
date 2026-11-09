#!/usr/bin/env bash
#
# Shoot the source frame for App Store promotional artwork, then rebuild the artwork from it.
#
#   bash Tools/promo_capture.sh
#
# Output: docs/appstore/promo-src/promo-chart-landscape.png  (the frame, 2752x2064)
#         docs/appstore/promo/*.png                          (the five assets, via make_promo_art.py)
#
# ⚠️ STATUS: THIS DOES NOT YET PRODUCE A USABLE FRAME. The capture runs, rotates and exports, but
# the location track does not reach the app, so the map stays at continental zoom with no chart in
# it and the test asserts its way out rather than saving a picture of an EFB nobody is flying. The
# shipping artwork still comes from the portrait screenshot set. The three findings that cost a run
# each are written up in ATCTranscribeUITests/PromoArtCaptureTests.swift; read them before resuming.
#
# ── Why this is not Tools/appstore_screenshots.sh ─────────────────────────────
# That script shoots the five STORE SCREENSHOTS: portrait, chrome and all, at exact device sizes,
# because that is what a product page shows. Featuring artwork is a different job with opposite
# rules — wide, chrome-free, no logo, no text, no device frame — so it is a different capture and
# a different file. See the header of ATCTranscribeUITests/PromoArtCaptureTests.swift.
#
# ── Landscape is the point ────────────────────────────────────────────────────
# The portrait set is 2064 px across. The same iPad in landscape is 2752, and the artwork is
# cropped to 2.33:1 at its widest, so width is the only dimension that survives. Shooting portrait
# cost a 3.1x upscale on the 5244-wide targets; this brings it to about 2x.
#
# ── Position ──────────────────────────────────────────────────────────────────
# Same as the screenshot runner, and for the same reason: `simctl location` feeds CoreLocation so
# the app takes an ordinary fix, while the in-app simulator paints "SIMULATED GPS — this position
# is not real" over everything. The ownship is the focal point of the artwork, so it has to be real
# enough to draw. The frame itself is set by --chart-center/--chart-span in the test, NOT by where
# the aeroplane is: the aeroplane only has to be somewhere in it.
set -euo pipefail
cd "$(dirname "$0")/.."            # → ios/
export PATH=/opt/homebrew/bin:$PATH

SIM="${SIM:-iPad Pro 13-inch (M5)}"
DD="${DD:-$HOME/atc-promo-dd}"
RESULT="$DD/promo.xcresult"
OUT="docs/appstore/promo-src"
DEST="platform=iOS Simulator,name=$SIM"
PY="${PY:-$HOME/CommSight/plate-georef-venv/bin/python3}"

case "$SIM" in
  *iPad*) ;;
  *) echo "!! '$SIM' is not an iPad. The artwork is cut from a 13-inch landscape frame; a phone"
     echo "!! gives 2868x1320 and a different chart layout entirely."; exit 1 ;;
esac

echo "== boot $SIM =="
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null

# ⚠️ GRANT LOCATION FIRST, and again after the build installs the app — the first grant is a no-op
# on a simulator that has never seen this bundle id.
xcrun simctl privacy "$SIM" grant location-always com.flycommsight.atctranscribe 2>/dev/null || true

echo "== xcodegen (PromoArtCaptureTests is a new file; the globs run at generate time) =="
${XCODEGEN:-$HOME/.xcodegen/xcodegen/bin/xcodegen} generate

echo "== build-for-testing — $SIM =="
xcodebuild build-for-testing -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -clonedSourcePackagesDirPath "${SPM:-$HOME/atc-spm}" \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO -quiet

xcrun simctl privacy "$SIM" grant location-always com.flycommsight.atctranscribe 2>/dev/null || true

# ⚠️ THE FRAMING COMES FROM THE AEROPLANE, so this is not optional dressing.
# `--chart-center`/`--chart-span` look like the right tool and are read only by the CLASSIC
# MKMapView engine; the app defaults to MapLibre and ignores them. Without a fix the map sits at
# continental zoom saying "Zoom in to load the chart here", which is what the first attempt shot.
# A moving track also fills in ground speed and heading, which a static `set` leaves blank.
WAYPOINTS=(40.62,-73.95 40.68,-73.88 40.74,-73.81 40.80,-73.74)
SPEED=62                            # m/s ≈ 120 kt

# Start from Shutdown so the device is clean: a simulator left booted by an earlier run keeps its
# background work going, and XCTest's waits time out into something reported as a failing test.
echo "== shutting down $SIM so it boots clean =="
xcrun simctl shutdown "$SIM" 2>/dev/null || true

echo "== fly the aircraft (simctl location, ${SPEED} m/s) =="
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl location "$SIM" start --speed=$SPEED "${WAYPOINTS[@]}" || \
  xcrun simctl location "$SIM" set "${WAYPOINTS[1]}"

echo "== run PromoArtCaptureTests =="
rm -rf "$RESULT"
TEST_RUNNER_PROMO_ART=1 xcodebuild test-without-building \
  -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -resultBundlePath "$RESULT" \
  -only-testing:ATCTranscribeUITests/PromoArtCaptureTests 2>&1 | tail -8

echo "== export the frame → $OUT =="
TMP="$DD/attachments"; rm -rf "$TMP"; mkdir -p "$TMP" "$OUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$TMP" >/dev/null

python3 - "$TMP" "$OUT" <<'PY'
import json, os, re, shutil, sys
tmp, out = sys.argv[1], sys.argv[2]
data = json.load(open(os.path.join(tmp, "manifest.json")))
suffix = re.compile(r'_\d+_[0-9A-Fa-f-]{36}\.png$')
def walk(o):
    if isinstance(o, dict):
        if "exportedFileName" in o and "suggestedHumanReadableName" in o: yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
n = 0
for a in walk(data):
    src = os.path.join(tmp, a["exportedFileName"])
    base = suffix.sub("", a["suggestedHumanReadableName"])
    if not base or not os.path.exists(src): continue
    shutil.copyfile(src, os.path.join(out, base + ".png"))
    n += 1
print(f"exported {n} frame(s)")
if n == 0:
    raise SystemExit("no attachment came back — did the test skip? it needs TEST_RUNNER_PROMO_ART=1")
PY

FRAME="$OUT/promo-chart-landscape.png"

# ⚠️ THE EXPORTED FRAME IS PORTRAIT EVEN THOUGH THE APP WAS LANDSCAPE. `app.screenshot()` captures
# the device framebuffer, which stays in the device's physical orientation, so the landscape
# content arrives turned a quarter turn. Turn it back here, and refuse to carry on if the result is
# not landscape — a portrait frame is the thing this whole capture exists to stop producing.
echo "== square the frame up =="
"$PY" - "$FRAME" <<'PY'
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p)
if im.width < im.height:
    im = im.transpose(Image.ROTATE_90)          # landscapeLeft: counter-clockwise puts it upright
    im.save(p)
    print(f"rotated to {im.width}x{im.height}")
else:
    print(f"already landscape at {im.width}x{im.height}")
assert im.width > im.height, f"frame is {im.width}x{im.height} after rotation — still not landscape"
PY

printf "== frame: "; sips -g pixelWidth -g pixelHeight "$FRAME" | awk '/pixel/{printf "%s ", $2} END{print ""}'

echo "== rebuild the artwork from it =="
"$PY" Tools/make_promo_art.py

xcrun simctl location "$SIM" clear 2>/dev/null || true
echo "== done =="
