#!/usr/bin/env bash
#
# Build and run the native macOS probe (ATCKitProbe) on the Mac's REAL Neural Engine:
# WER self-checks + an on-ANE proof-of-life through the engine. Runs headless over SSH
# (unlike macOS XCTest, whose runner daemon needs a GUI session). Run on the Mac.
#
#   bash Tools/probe.sh
#   ATC_MODEL_DIR=/path/to/model ATC_AUDIO_DIR=/path/to/diagnostic_data bash Tools/probe.sh
#
set -eo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

DD="${DD:-$HOME/atc-dd}"
SPM="${SPM:-$HOME/atc-spm}"

# Resolve xcodegen from PATH or the usual install locations.
XCODEGEN="${XCODEGEN:-}"
if [ -z "$XCODEGEN" ]; then
  for p in "$(command -v xcodegen 2>/dev/null)" "$HOME/.xcodegen/xcodegen/bin/xcodegen" "$HOME/xcodegen-dist/xcodegen/bin/xcodegen"; do
    if [ -n "$p" ] && [ -x "$p" ]; then XCODEGEN="$p"; break; fi
  done
fi
[ -x "$XCODEGEN" ] || { echo "xcodegen not found (set XCODEGEN=...)" >&2; exit 1; }

# Default to the converted small model + bundled diagnostic clips if not provided.
export ATC_MODEL_DIR="${ATC_MODEL_DIR:-$(find "$HOME/atc-coreml/small" -name AudioEncoder.mlmodelc -exec dirname {} \; 2>/dev/null | head -1)}"
export ATC_AUDIO_DIR="${ATC_AUDIO_DIR:-$HOME/ATC_Transcribe/python-legacy/tests/diagnostic_data}"

"$XCODEGEN" generate >/dev/null
xcodebuild build -scheme ATCKitProbe -destination 'platform=macOS' \
  -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  >/tmp/atckitprobe_build.log 2>&1 || { echo "BUILD FAILED — tail:"; tail -25 /tmp/atckitprobe_build.log; exit 1; }

BIN="$DD/Build/Products/Debug/ATCKitProbe"
echo "== running $BIN =="
echo "   ATC_MODEL_DIR=$ATC_MODEL_DIR"
"$BIN"
