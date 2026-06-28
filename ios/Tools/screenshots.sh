#!/usr/bin/env bash
#
# Regenerate the README screenshots from the demo console, headless on an iPad simulator.
#
# Runs ATCTranscribeUITests/ScreenshotTests (gated behind SCREENSHOTS=1 so it's inert in the normal
# suite), then exports the attached PNGs into docs/screenshots/. No model or network needed — the
# demo console seeds a representative transcript (callsign chips + correction edits) on its own.
#
#   bash Tools/screenshots.sh                       # default iPad Pro 13-inch (M5)
#   SIM="iPad Air 11-inch (M3)" bash Tools/screenshots.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."            # → ios/
export PATH=/opt/homebrew/bin:$PATH

SIM="${SIM:-iPad Pro 13-inch (M5)}"
DD="${DD:-$HOME/atc-shots-dd}"
RESULT="$DD/shots.xcresult"
OUT="docs/screenshots"
DEST="platform=iOS Simulator,name=$SIM"

# The screenshots come from the DEMO console (seeded transcript with callsign chips + corrections),
# which the app only takes when no Whisper model is bundled. Move Resources/Models aside for the
# build so the app is model-less; restore it on exit. (Mirrors the lean ship build.)
MODELS_DIR="ATCTranscribe/Resources/Models"
MODELS_BAK="/tmp/atc-shots-models.$$"
restore_models() { if [ -d "$MODELS_BAK" ]; then rm -rf "$MODELS_DIR"; mv "$MODELS_BAK" "$MODELS_DIR"; fi; }
trap restore_models EXIT
echo "== lean: move bundled models aside (force the demo console) =="
rm -rf "$MODELS_BAK"
[ -d "$MODELS_DIR" ] && mv "$MODELS_DIR" "$MODELS_BAK"
mkdir -p "$MODELS_DIR/llm"

echo "== xcodegen (bake SCREENSHOTS=1 into the test scheme) =="
SCREENSHOTS=1 ${XCODEGEN:-xcodegen} generate

echo "== build-for-testing — $SIM =="
xcodebuild build-for-testing -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -clonedSourcePackagesDirPath "${SPM:-$HOME/atc-spm}" \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO -quiet

echo "== run ScreenshotTests =="
rm -rf "$RESULT"
xcodebuild test-without-building -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -resultBundlePath "$RESULT" \
  -only-testing:ATCTranscribeUITests/ScreenshotTests 2>&1 | tail -6 || true

echo "== export attachments → $OUT =="
TMP="$DD/attachments"; rm -rf "$TMP"; mkdir -p "$TMP" "$OUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$TMP" >/dev/null

# The manifest maps each exported file to the suggestedHumanReadableName we set as the shot name
# (e.g. "console"); copy each newest-named PNG to docs/screenshots/<name>.png.
python3 - "$TMP" "$OUT" <<'PY'
import json, os, re, shutil, sys
tmp, out = sys.argv[1], sys.argv[2]
data = json.load(open(os.path.join(tmp, "manifest.json")))
# XCUITest names an attachment "<name>_<index>_<UUID>.png"; strip that suffix back to "<name>".
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
    print("  ", base + ".png"); n += 1
print(f"exported {n} screenshots")
PY

echo "== done — $OUT =="
ls -1 "$OUT"
