#!/usr/bin/env bash
#
# Validate the Stratux client under sustained CONCURRENT load. Runs the fake Stratux server
# (stratux-pi/test/fake_stratux.py) on the Mac host (= the Simulator's 127.0.0.1) and drives the real
# StratuxAudioSource + StratuxService against it for ~40 s, measuring the sustained audio sample rate
# while the traffic WebSocket + GPS poll run at the same time, plus an audio-reconnect-after-drop check.
#
#   bash Tools/stratux_validate.sh
#
set -uo pipefail
cd "$(dirname "$0")/.."            # → ios/
export PATH=/opt/homebrew/bin:$PATH

PORT="${STRATUX_PORT:-9408}"
SIM="${SIM:-iPhone 17 Pro}"
DD="${DD:-$HOME/atc-fix-dd}"
FAKE="../stratux-pi/test/fake_stratux.py"
RESULT="$DD/stratux-validate.xcresult"

echo "== start fake Stratux on 127.0.0.1:$PORT (targets=${TRAFFIC_TARGETS:-25} hz=${TRAFFIC_HZ:-1.0}) =="
TRAFFIC_TARGETS="${TRAFFIC_TARGETS:-25}" TRAFFIC_HZ="${TRAFFIC_HZ:-1.0}" PORT="$PORT" \
  python3 "$FAKE" > /tmp/fake_stratux.log 2>&1 &
FAKE_PID=$!
trap 'kill $FAKE_PID 2>/dev/null || true' EXIT
sleep 1
if curl -s "http://127.0.0.1:$PORT/getSituation" >/dev/null; then echo "  server up"; else
  echo "  server failed to start"; cat /tmp/fake_stratux.log; exit 1; fi

echo "== xcodegen (bake STRATUX_VALIDATE=1 STRATUX_PORT=$PORT) =="
STRATUX_VALIDATE=1 STRATUX_PORT="$PORT" xcodegen generate >/dev/null

echo "== build-for-testing ($SIM) =="
xcodebuild build-for-testing -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$HOME/atc-spm" -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO -quiet

echo "== run StratuxLiveStreamTests (~40 s) =="
rm -rf "$RESULT"
xcodebuild test-without-building -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" -resultBundlePath "$RESULT" \
  -only-testing:ATCTranscribeTests/StratuxLiveStreamTests 2>&1 \
  | grep -iE "STRATUX-VALIDATE|Executed [0-9]|Test Case .*(passed|failed)|\*\* TEST"
TEST_RC=${PIPESTATUS[0]}

echo "== restore scheme (STRATUX_VALIDATE off) =="
xcodegen generate >/dev/null
echo "test exit: $TEST_RC   (fake server tail: $(tail -1 /tmp/fake_stratux.log))"
exit "$TEST_RC"
