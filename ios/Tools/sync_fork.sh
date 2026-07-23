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
TIP=$(git rev-parse --short HEAD); NC=$(git rev-list --count $UPSTREAM..HEAD); NF=$(git diff --name-only $UPSTREAM..HEAD | wc -l | tr -d ' ')
echo "== update FORK.md (tip $TIP, $NC commits, $NF files) =="
sed -i '' -E "s/(\| Fork commit \| \`)[0-9a-f]+(\`)/\1$TIP\2/; s/(\| Delta vs upstream \| )[0-9]+ commits, [0-9]+ files/\1$NC commits, $NF files/" "$APP_DIR/docs/FORK.md"
echo "done. Commit ios/Vendor-src/globe-fork-delta.bundle + ios/docs/FORK.md in the app repo."
