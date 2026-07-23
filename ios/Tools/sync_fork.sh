#!/usr/bin/env bash
# sync_fork.sh — back up the MapLibre fork after a renderer rebuild.
# Pushes globe/main to the private backup repo, refreshes the in-repo delta bundle, and updates FORK.md.
set -uo pipefail
FORK="${FORK:-$HOME/CommSight/maplibre-native}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # ios/
UPSTREAM=4ec05558c849954b551c55300b31a48616d4da35
cd "$FORK" || { echo "fork not found: $FORK"; exit 1; }
git remote get-url backup >/dev/null 2>&1 || git remote add backup git@github.com:lawgorithims/maplibre-native.git
echo "== push globe/main -> backup =="
git push backup globe/main:globe/main
echo "== refresh delta bundle =="
git bundle create "$APP_DIR/Vendor-src/globe-fork-delta.bundle" "$UPSTREAM..globe/main"
# Stage the device dSYM beside the xcframework it belongs to, so ship_testflight.sh can fold it
# into the archive. Renamed/re-identified to read as MapLibre.framework's rather than bazel's
# target name; the UUID is what ASC matches on, and ship_testflight.sh re-checks it before use.
DSYM_SRC="$FORK/bazel-bin/platform/ios/MapLibre.dynamic_dsyms/MapLibre_ios_device.framework.dSYM"
DSYM_DST="$APP_DIR/Vendor/MapLibre.framework.dSYM"
if [ -d "$DSYM_SRC" ]; then
  echo "== stage device dSYM -> Vendor =="
  rm -rf "$DSYM_DST" && cp -R "$DSYM_SRC" "$DSYM_DST" && chmod -R u+w "$DSYM_DST"
  mv "$DSYM_DST/Contents/Resources/DWARF/MapLibre_ios_device" "$DSYM_DST/Contents/Resources/DWARF/MapLibre" 2>/dev/null
  plutil -replace CFBundleIdentifier -string "com.apple.xcode.dsym.com.maplibre.mapbox" "$DSYM_DST/Contents/Info.plist"
  dwarfdump --uuid "$DSYM_DST" | head -1
else
  echo "WARNING: no dSYM at $DSYM_SRC — rebuild with --output_groups=+dsyms --apple_generate_dsym"
fi
TIP=$(git rev-parse --short HEAD); NC=$(git rev-list --count $UPSTREAM..HEAD); NF=$(git diff --name-only $UPSTREAM..HEAD | wc -l | tr -d ' ')
echo "== update FORK.md (tip $TIP, $NC commits, $NF files) =="
sed -i '' -E "s/(\| Fork commit \| \`)[0-9a-f]+(\`)/\1$TIP\2/; s/(\| Delta vs upstream \| )[0-9]+ commits, [0-9]+ files/\1$NC commits, $NF files/" "$APP_DIR/docs/FORK.md"
echo "done. Commit ios/Vendor-src/globe-fork-delta.bundle + ios/docs/FORK.md in the app repo."
