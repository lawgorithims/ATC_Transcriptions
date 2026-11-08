#!/usr/bin/env bash
#
# Regenerate the App Store screenshot set, headless, at exact device sizes.
#
#   bash Tools/appstore_screenshots.sh                              # iPad Pro 13-inch (M5)
#   SIM="iPhone 17 Pro Max" bash Tools/appstore_screenshots.sh      # the 6.9" iPhone set
#
# Apple needs one set per device class the app supports. This app is universal, so BOTH:
#
#   iPad 13"     2064 x 2752   iPad Pro 13-inch (M5)
#   iPhone 6.9"  1320 x 2868   iPhone 17 Pro Max
#
# Output lands in docs/appstore/<slug>/, named so it sorts into listing order.
#
# ── Why this is not Tools/screenshots.sh ──────────────────────────────────────
# That script shoots the README from the transcription console, and moves the bundled models
# aside to force the demo path. This build has transcription compiled out, so there is no console
# to shoot and no reason for the lean trick. Different set, different script.
#
# ── Position ──────────────────────────────────────────────────────────────────
# The aircraft is flown with `simctl location`, NOT the in-app flight simulator. The in-app one
# publishes a fake position and paints a "SIMULATED GPS — this position is not real" banner over
# everything, which must never reach a store page. simctl feeds CoreLocation instead, so the app
# takes an ordinary fix. A moving track also fills in ground speed and heading, which a static
# `set` leaves blank.
#
# The route below is over the New York sectional because that is what the chart cache holds; a
# location with no downloaded chart gives you a shot of an empty map. Check what is cached before
# changing it:
#   ls "$(xcrun simctl get_app_container <sim> com.flycommsight.atctranscribe data)/Library/Application Support/charts"
set -euo pipefail
cd "$(dirname "$0")/.."            # → ios/
export PATH=/opt/homebrew/bin:$PATH

SIM="${SIM:-iPad Pro 13-inch (M5)}"
SLUG="$(echo "$SIM" | tr ' ()' '-' | tr -s '-' | sed 's/-$//')"
DD="${DD:-$HOME/atc-appstore-dd}"
RESULT="$DD/shots.xcresult"
OUT="docs/appstore/$SLUG"
DEST="platform=iOS Simulator,name=$SIM"

# A short leg at ~120 kt, so GS and TRK read like an aeroplane rather than a parked iPad.
WAYPOINTS=(40.62,-73.95 40.68,-73.88 40.74,-73.81 40.80,-73.74)
SPEED=62                            # m/s ≈ 120 kt

echo "== boot $SIM =="
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null

# ⚠️ GRANT LOCATION FIRST. Without this the app never gets a fix, the map stays at continental
# zoom with no ownship, and every shot is of an EFB that does not know where it is — which is
# exactly what the first run of this script produced. Granting with simctl is deterministic;
# racing the springboard dialog from inside the test is not.
echo "== grant location to the app =="
xcrun simctl privacy "$SIM" grant location-always com.flycommsight.atctranscribe 2>/dev/null || true

echo "== fly the aircraft (simctl location, ${SPEED} m/s) =="
xcrun simctl location "$SIM" start --speed=$SPEED "${WAYPOINTS[@]}" || \
  xcrun simctl location "$SIM" set "${WAYPOINTS[1]}"

echo "== xcodegen (bake APPSTORE_SHOTS=1 into the test scheme) =="
APPSTORE_SHOTS=1 ${XCODEGEN:-xcodegen} generate

echo "== build-for-testing — $SIM =="
xcodebuild build-for-testing -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -clonedSourcePackagesDirPath "${SPM:-$HOME/atc-spm}" \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO -quiet

# build-for-testing is what installs the app, so re-grant now that the bundle id exists on
# this device — the first grant is a no-op on a simulator that has never seen the app.
xcrun simctl privacy "$SIM" grant location-always com.flycommsight.atctranscribe 2>/dev/null || true

echo "== run AppStoreScreenshotTests =="
rm -rf "$RESULT"
xcodebuild test-without-building -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -resultBundlePath "$RESULT" \
  -only-testing:ATCTranscribeUITests/AppStoreScreenshotTests 2>&1 | tail -6 || true

echo "== export attachments → $OUT =="
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
print(f"exported {n} screenshots")
PY

echo "== sizes (Apple rejects anything off-spec) =="
for f in "$OUT"/*.png; do
  printf "  %-24s " "$(basename "$f")"
  sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s ", $2} END{print ""}'
done

xcrun simctl location "$SIM" clear 2>/dev/null || true
echo "== done — $OUT =="
