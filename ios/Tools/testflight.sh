#!/usr/bin/env bash
#
# testflight.sh — archive the iOS app and upload it to App Store Connect / TestFlight.
#
# Runs on the Mac (Apple Silicon, FULL Xcode). Fully headless via an App Store Connect
# API key, so it needs no interactive Apple-ID GUI login — works over SSH on the build box.
#
# Prereqs handled elsewhere:
#   • Toolchain + iOS SDK installed (Tools/setup.sh).
#   • The `small` CoreML model converted and copied into
#     ATCTranscribe/Resources/Models/small/<id>/ (Tools/setup.sh --models, then copy).
#   • An app record for PRODUCT_BUNDLE_IDENTIFIER exists in App Store Connect.
#
# Required env:
#   ASC_KEY_ID      App Store Connect API key id      (Users and Access → Integrations)
#   ASC_ISSUER_ID   issuer id (same page)
#   ASC_KEY_PATH    path to the AuthKey_XXXX.p8 file
#   TEAM_ID         10-char Apple Developer team id
# Optional env:
#   BUILD_NUMBER    CFBundleVersion (default 1). BUMP for every re-upload — App Store
#                   Connect rejects a build number it has already seen.
#   SCHEME          xcodebuild scheme (default ATCTranscribe)
#   XCODEGEN        path to the xcodegen binary (default ~/.xcodegen/.../xcodegen or PATH)
#
#   ASC_KEY_ID=ABC123 ASC_ISSUER_ID=... ASC_KEY_PATH=~/AuthKey_ABC123.p8 \
#   TEAM_ID=XXXXXXXXXX bash Tools/testflight.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$IOS_DIR"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

: "${ASC_KEY_ID:?set ASC_KEY_ID}";   : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"; : "${TEAM_ID:?set TEAM_ID}"
[ -f "$ASC_KEY_PATH" ] || die "ASC_KEY_PATH not found: $ASC_KEY_PATH"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SCHEME="${SCHEME:-ATCTranscribe}"

XCODEGEN="${XCODEGEN:-$HOME/.xcodegen/xcodegen/bin/xcodegen}"
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen)" || die "xcodegen not found (run Tools/setup.sh)."

# 1. the bundled CoreML model MUST be present (it is added as a folder reference). Without
#    it the app would ship demo-only — fail loudly rather than upload a useless build.
if ! find ATCTranscribe/Resources/Models -name AudioEncoder.mlmodelc -print -quit 2>/dev/null | grep -q .; then
  die "no CoreML model under ATCTranscribe/Resources/Models/.
       Convert it (Tools/setup.sh --models) and copy the small/<id>/ dir there first:
         SRC=\$(find \$HOME/atc-coreml/small -name AudioEncoder.mlmodelc -exec dirname {} \;)
         mkdir -p ATCTranscribe/Resources/Models/small
         cp -R \"\$SRC\" ATCTranscribe/Resources/Models/small/"
fi

# 2. (re)generate the Xcode project from project.yml
log "xcodegen generate"
"$XCODEGEN" generate

ARCHIVE="build/ATCTranscribe.xcarchive"
EXPORT_DIR="build/export"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p build

AUTH=( -authenticationKeyID "$ASC_KEY_ID"
       -authenticationKeyIssuerID "$ASC_ISSUER_ID"
       -authenticationKeyPath "$ASC_KEY_PATH"
       -allowProvisioningUpdates )

# 3. archive a real-device (ANE) build with automatic signing
log "archive (build $BUILD_NUMBER, team $TEAM_ID)"
xcodebuild archive \
  -project ATCTranscribe.xcodeproj -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$HOME/atc-dd" -clonedSourcePackagesDirPath "$HOME/atc-spm" \
  -skipMacroValidation -skipPackagePluginValidation \
  "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# 4. export + upload to App Store Connect (destination: upload in the plist)
log "export + upload"
sed "s/__TEAM_ID__/$TEAM_ID/" ExportOptions.plist > build/ExportOptions.plist
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  "${AUTH[@]}"

log "done"
echo "Uploaded build $BUILD_NUMBER. It will appear under App Store Connect → your app →"
echo "TestFlight once processing finishes (~10–30 min). Add yourself as an internal tester,"
echo "then install via the TestFlight app on your iPad."
