#!/usr/bin/env bash
# Compile the offline plate-georef tool (macOS). It shares PlateSimilarity.swift with the app, and
# swiftc needs top-level code in a file named main.swift, so we stage both into a build dir.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$DIR/build_plate_georef}"
B="$(mktemp -d)"
cp "$DIR/build_plate_georef.swift" "$B/main.swift"
cp "$DIR/../ATCTranscribe/Core/PlateSimilarity.swift" "$B/PlateSimilarity.swift"
swiftc -O "$B/main.swift" "$B/PlateSimilarity.swift" -o "$OUT"
rm -rf "$B"
echo "built: $OUT"
