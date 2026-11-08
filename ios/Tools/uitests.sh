#!/usr/bin/env bash
#
# Run the UI suite on an iPad — WHICH IS NOT A PREFERENCE.
#
# Obelisk is universal, but it is not the same app at both widths. ConsoleView.homeArea is
# `if hSize == .regular { FloatingCanvas } else { … }`, so floating widgets, the docked side panes
# and the NRST panel DO NOT EXIST on an iPhone, and TopBar drops the bar clock at compact width.
# Nine tests assert that chrome. Run on an iPhone 17 Pro they fail with messages that each read like
# a product bug — "no clock in the top bar", "left side pane did not render", "the NRST panel has no
# close control" — and every one of them passes on an iPad in the same build.
#
# Measured on 2026-10-29, same build, same commit:
#     iPad Pro 13-inch (M5)   53 passed   0 failed   (before this script existed: 2 flaky/data)
#     iPhone 17 Pro           43 passed   9 failed
#
# That iPad row was taken on a box under heavy load and the runner kept dying, so it went in as the
# best available guess. Re-measured on main (`fa9f7b1`) on 2026-10-30 with the shutdown step below
# in place, it is 64 executed / 10 skipped / 0 failed — i.e. 54 passed, and the suite is green.
#
# This script exists so a future run picks the destination up instead of having to know it. The
# tests also guard themselves now (UITestLayout.requireRegularWidth) and XCTSkip with a reason on a
# phone, so running it the wrong way is slow and honest rather than a page of red.
#
#   bash Tools/uitests.sh                                   # whole suite, iPad Pro 13-inch (M5)
#   SIM="iPad Air 11-inch (M4)" bash Tools/uitests.sh        # another iPad
#   bash Tools/uitests.sh ATCTranscribeUITests/MapControlsUITests   # one class or one test
#
set -euo pipefail
cd "$(dirname "$0")/.."            # → ios/
export PATH=/opt/homebrew/bin:$PATH

SIM="${SIM:-iPad Pro 13-inch (M5)}"
DD="${DD:-$HOME/atc-uitests-dd}"
DEST="platform=iOS Simulator,name=$SIM"

case "$SIM" in
  *iPad*) ;;
  *) echo "!! '$SIM' is not an iPad. The UI suite asserts regular-width chrome that the app does"
     echo "!! not build at compact width; the width-gated tests will XCTSkip and the rest may fail."
     echo "!! See the note at the top of this script and ios/README.md." ;;
esac

# Vendored xcframeworks are git-ignored (Vendor/* in .gitignore) and live only in the checkout they
# were built in. A fresh clone or a git worktree has an empty Vendor/ and the build fails with "There
# is no XCFramework found at …" — which, under -quiet and a piped exit code, can look like a test
# failure. Say so plainly instead.
for fw in MapLibre.xcframework llama.xcframework; do
  if [ ! -e "Vendor/$fw" ]; then
    echo "!! Vendor/$fw is missing. It is git-ignored and built locally; see Tools/build_llama_xcframework.sh"
    echo "!! and ios/README.md. In a git worktree, symlink them from the main checkout's ios/Vendor/."
    exit 1
  fi
done

ONLY=()
for t in "$@"; do ONLY+=(-only-testing:"$t"); done
if [ ${#ONLY[@]} -eq 0 ]; then ONLY=(-only-testing:ATCTranscribeUITests); fi

echo "== build-for-testing =="
xcodebuild build-for-testing -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" -clonedSourcePackagesDirPath "${SPM:-$HOME/atc-spm}" \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO -quiet

# Start the device from Shutdown, every time.
#
# A simulator left booted by an earlier run keeps its own background work going — on the iPad Pro
# that is News and Screen Time widget extensions, plus a `diagnosticd` that had been accumulating for
# an hour. Reusing it is what a UI run looks like when it goes wrong: XCTest's waits time out, and a
# timed-out wait is reported as "Restarting after unexpected exit, crash, or test timeout", which
# lands in the summary as a failing test with partial totals rather than as anything resembling a
# timeout.
#
# Measured on 2026-10-30, same commit (`fa9f7b1`), same destination, back to back:
#     leftover booted device    10 restarts, 10 "failures", 46 of 64 tests executed
#     shut down first            0 restarts,  0 failures,   64 of 64 — and that run ENDED at load
#                                98, higher than the one that fell apart
#
# So this is not about a quiet machine, which is something you have to wait for. It is about a clean
# device, which a script can guarantee. Only "$SIM" is touched, so another simulator you are using
# elsewhere is left alone; `xcrun simctl shutdown all` is the bigger hammer if you want it.
echo "== shutting down $SIM so it boots clean =="
xcrun simctl shutdown "$SIM" 2>/dev/null || true   # already-shutdown is an error; it is not one here

echo "== UI tests — $SIM =="
xcodebuild test-without-building -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination "$DEST" -derivedDataPath "$DD" "${ONLY[@]}"
