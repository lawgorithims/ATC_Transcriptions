#!/usr/bin/env bash
#
# ship_testflight.sh — archive + upload the iOS app to App Store Connect / TestFlight
# from a HEADLESS Mac (over SSH, no GUI login, no devices registered).
#
# WHY THIS EXISTS (and why Tools/testflight.sh is NOT enough on a headless box):
#   testflight.sh does a *signed* archive that defaults to **Development** signing, which
#   over SSH fails two ways: (1) "team has no devices" — development profiles need a
#   registered device; (2) "private key is not installed" — the dev cert's private key
#   isn't in any keychain on a fresh box (0 local identities). App Store **distribution**
#   signing has neither problem (no devices needed), but Xcode only applies it at EXPORT.
#   So the working recipe is: archive UNSIGNED, then sign-for-distribution at export, where
#   `-allowProvisioningUpdates` + the ASC API key mint the cloud distribution cert + profile.
#   This is the exact process that shipped build 1 of CommSight (2026-06-27).
#
# Required env (the actual values are NOT in this public repo — see ios/RECOVERY.md):
#   ASC_KEY_ID      App Store Connect API key id   (Users and Access → Integrations)
#   ASC_ISSUER_ID   issuer id (top of the same page)
#   ASC_KEY_PATH    path to the AuthKey_XXXX.p8 file on this Mac (chmod 600)
#   TEAM_ID         10-char Apple Developer team id (developer.apple.com → Membership)
# Optional env:
#   BUILD_NUMBER    CFBundleVersion (default 1). BUMP for every re-upload — ASC rejects a
#                   build number it has already seen.
#   SCHEME          xcodebuild scheme (default ATCTranscribe)
#   LEAN            1 (default) = move Resources/Models aside so the IPA ships model-less and
#                   downloads them on first launch (HuggingFace, see Tools/publish_models.md).
#                   0 = archive whatever is in Resources/Models (a big, fully-offline build).
#   XCODEGEN        path to xcodegen (default ~/.xcodegen/.../xcodegen or PATH)
#
# Usage:
#   ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/AuthKey_XXXX.p8 TEAM_ID=... \
#   BUILD_NUMBER=2 bash Tools/ship_testflight.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

: "${ASC_KEY_ID:?set ASC_KEY_ID (see ios/RECOVERY.md)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
: "${TEAM_ID:?set TEAM_ID}"
[ -f "$ASC_KEY_PATH" ] || die "ASC_KEY_PATH not found: $ASC_KEY_PATH"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SCHEME="${SCHEME:-ATCTranscribe}"
LEAN="${LEAN:-1}"

XCODEGEN="${XCODEGEN:-$HOME/.xcodegen/xcodegen/bin/xcodegen}"
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen)" || die "xcodegen not found (run Tools/setup.sh)."

cd "$IOS_DIR" || die "cannot cd to $IOS_DIR"

# ---- throwaway CI keychain (gives a freshly-minted signing key somewhere to land) ----
KCPW="atcci-$$"
KC="$HOME/atc-ci.keychain-db"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
ORIG_DEFAULT="$(security default-keychain | sed -e 's/[" ]//g')"
MODELS_DIR="ATCTranscribe/Resources/Models"
MODELS_BAK="/tmp/atc-models-bak.$$"

cleanup() {
  # ALWAYS restore the default keychain and the models dir, even on failure.
  [ -n "${ORIG_DEFAULT:-}" ] && security default-keychain -s "$ORIG_DEFAULT" 2>/dev/null || security default-keychain -s "$LOGIN_KC" 2>/dev/null
  security list-keychains -d user -s "$LOGIN_KC" 2>/dev/null
  security delete-keychain "$KC" 2>/dev/null || true
  if [ "$LEAN" = "1" ] && [ -d "$MODELS_BAK" ]; then
    rm -rf "$MODELS_DIR"
    mv "$MODELS_BAK" "$MODELS_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "setup throwaway signing keychain"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security list-keychains -d user -s "$KC" "$LOGIN_KC"
security default-keychain -s "$KC"

# ---- lean build: move the heavy models out so the IPA ships model-less ----
if [ "$LEAN" = "1" ]; then
  log "LEAN build — moving $MODELS_DIR aside (app downloads models on first launch)"
  rm -rf "$MODELS_BAK"
  mv "$MODELS_DIR" "$MODELS_BAK" 2>/dev/null || true
  mkdir -p "$MODELS_DIR/llm"
  touch "$MODELS_DIR/.gitkeep" "$MODELS_DIR/llm/.gitkeep"
fi

log "xcodegen generate"
"$XCODEGEN" generate >/dev/null || die "xcodegen generate failed"

ARCHIVE="build/ATCTranscribe.xcarchive"
EXPORT_DIR="build/export"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p build

AUTH=( -authenticationKeyID "$ASC_KEY_ID"
       -authenticationKeyIssuerID "$ASC_ISSUER_ID"
       -authenticationKeyPath "$ASC_KEY_PATH"
       -allowProvisioningUpdates )

# ---- 1. archive UNSIGNED (skips Development provisioning/devices entirely) ----
log "archive UNSIGNED (build $BUILD_NUMBER, team $TEAM_ID)"
xcodebuild archive \
  -project ATCTranscribe.xcodeproj -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$HOME/atc-dd" -clonedSourcePackagesDirPath "$HOME/atc-spm" \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
ARC_RC=$?
[ "$ARC_RC" -eq 0 ] || die "archive failed (rc=$ARC_RC)"

# ---- 1b. fold the MapLibre fork dSYM into the archive ----
# The map renderer is a PREBUILT xcframework, so Xcode generates no dSYM for it and App Store
# Connect cannot symbolicate crashes inside it — which is most of the map code every pilot runs.
# The fork is built with --apple_generate_dsym; the matching bundle is staged next to the
# xcframework it belongs to. The UUID guard is the point: a stale dSYM silently mis-symbolicates,
# which is worse than none, so a mismatch warns and ships without rather than shipping a lie.
MAPLIBRE_DSYM="${MAPLIBRE_DSYM:-Vendor/MapLibre.framework.dSYM}"
APP_ML="$ARCHIVE/Products/Applications/$SCHEME.app/Frameworks/MapLibre.framework/MapLibre"
if [ -d "$MAPLIBRE_DSYM" ] && [ -f "$APP_ML" ]; then
  BIN_UUID="$(dwarfdump --uuid "$APP_ML" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
  SYM_UUID="$(dwarfdump --uuid "$MAPLIBRE_DSYM" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
  if [ -n "$BIN_UUID" ] && [ "$BIN_UUID" = "$SYM_UUID" ]; then
    mkdir -p "$ARCHIVE/dSYMs"
    rm -rf "$ARCHIVE/dSYMs/MapLibre.framework.dSYM"
    cp -R "$MAPLIBRE_DSYM" "$ARCHIVE/dSYMs/MapLibre.framework.dSYM"
    log "folded MapLibre dSYM into archive (uuid ${BIN_UUID% })"
  else
    printf '\033[1;33mWARNING: MapLibre dSYM UUID mismatch (binary=%s dSYM=%s) — shipping WITHOUT\n\
renderer symbols. Rebuild the fork and re-stage %s.\033[0m\n' "$BIN_UUID" "$SYM_UUID" "$MAPLIBRE_DSYM" >&2
  fi
else
  printf '\033[1;33mWARNING: no MapLibre dSYM at %s — ASC cannot symbolicate renderer crashes.\n\
See ios/docs/FORK.md.\033[0m\n' "$MAPLIBRE_DSYM" >&2
fi

# ---- 2. export signed-for-App-Store + upload ----
# ExportOptions.plist is method=app-store-connect, destination=upload, signingStyle=automatic.
# -allowProvisioningUpdates mints the cloud DISTRIBUTION cert + profile (no devices needed).
log "export + upload (App Store distribution)"
sed "s/__TEAM_ID__/$TEAM_ID/" ExportOptions.plist > build/ExportOptions.plist
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  "${AUTH[@]}"
EXP_RC=$?
[ "$EXP_RC" -eq 0 ] || die "export/upload failed (rc=$EXP_RC). If 'private key is not installed', \
an orphaned Development cert must be revoked in the portal first (see ios/RECOVERY.md)."

log "done"
echo "Uploaded build $BUILD_NUMBER. It appears under App Store Connect → CommSight → TestFlight"
echo "after ~10-30 min of processing. Add yourself as an internal tester, then install via the"
echo "TestFlight app. (cleanup trap restores the keychain + Resources/Models on exit.)"
