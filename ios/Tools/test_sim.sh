#!/bin/bash
# Run the unit suite on a simulator DEDICATED to this checkout.
#
# WHY THIS EXISTS. Two agents/worktrees running `xcodebuild test` against the same simulator fight over
# one bundle id: installing or launching the second build TERMINATES the first, and the test host that
# just died is reported as
#
#     Restarting after unexpected exit, crash, or test timeout
#
# attributed to whichever test happened to be executing — e.g. FusionShadowLogTests, which then passes
# on its own. Hours were spent hunting a "flaky ASR test" that was really simulator contention. It also
# means crash reports in ~/Library/Logs/DiagnosticReports interleave between checkouts (they all say
# "ATCTranscribe"); tell them apart by the embedded MapLibre UUID, which differs per Vendor build:
#
#     dwarfdump --uuid ios/Vendor/MapLibre.xcframework/*/MapLibre.framework/MapLibre
#
# The device is named after this checkout, created once, and reused. Delete with:
#     xcrun simctl delete "$(basename "$PWD")-tests"
#
#     usage: Tools/test_sim.sh [extra xcodebuild args…]
#            Tools/test_sim.sh -only-testing:ATCTranscribeTests/NearestAirportsTests
set -euo pipefail

cd "$(dirname "$0")/.."                                  # ios/
NAME="$(basename "$(cd .. && pwd)")-tests"               # e.g. ATC_Transcriptions-tests
RUNTIME="${ATC_TEST_RUNTIME:-}"
# Device-type IDs carry a RAM suffix that changes with Xcode (…iPad-Pro-13-inch-M5-12GB), so resolve the
# newest available iPad by name rather than hard-coding one that stops existing on the next upgrade.
DEVICE_TYPE="${ATC_TEST_DEVICE:-}"
if [ -z "$DEVICE_TYPE" ]; then
  DEVICE_TYPE=$(xcrun simctl list devicetypes -j | python3 -c '
import json,re,sys
# The PLAIN 13-inch that RELEASING.md names, newest chip. The "(16GB)" variants are separate device types,
# so match the whole name, and sort on the chip number rather than on list order.
dts=[d for d in json.load(sys.stdin)["devicetypes"] if re.fullmatch(r"iPad Pro 13-inch \(M\d+\)", d["name"])]
dts.sort(key=lambda d: int(re.search(r"\(M(\d+)\)", d["name"]).group(1)))
print(dts[-1]["identifier"] if dts else "")')
fi
[ -n "$DEVICE_TYPE" ] || { echo "no iPad Pro simulator device type available"; exit 1; }

# Newest installed iOS runtime unless one is pinned.
if [ -z "$RUNTIME" ]; then
  RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "iOS" in r.get("name","")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')
fi
[ -n "$RUNTIME" ] || { echo "no available iOS simulator runtime"; exit 1; }

UDID=$(xcrun simctl list devices -j | python3 -c "
import json,sys
name=sys.argv[1]
for _, devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d.get('name')==name: print(d['udid']); break
" "$NAME")

if [ -z "$UDID" ]; then
  echo "creating dedicated test simulator: $NAME"
  UDID=$(xcrun simctl create "$NAME" "$DEVICE_TYPE" "$RUNTIME")
fi
echo "test simulator: $NAME ($UDID)"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

export PATH="$HOME/.xcodegen/xcodegen/bin:$PATH"
xcodegen generate
exec xcodebuild -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "${ATC_TEST_DD:-/tmp/dd-$NAME}" \
  CODE_SIGNING_ALLOWED=NO \
  "${@:--only-testing:ATCTranscribeTests}" test
