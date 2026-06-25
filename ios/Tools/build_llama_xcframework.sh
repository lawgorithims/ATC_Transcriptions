#!/usr/bin/env bash
#
# Build the vendored llama.xcframework that powers the local CPU context-fixer LLM
# (LocalLLMCorrector / LlamaContext, behind `import llama`).
#
# Why this instead of a SwiftPM package: upstream ggml-org/llama.cpp removed its
# Package.swift, and the StanfordBDHG SwiftPM mirror leaks C++ headers (grammar-parser.h)
# into the C `llama` module so Swift can't import it. llama.cpp's own build-xcframework.sh
# emits a framework that exposes ONLY the pure-C llama.h with a proper `framework module
# llama` modulemap — a clean Swift import, at a recent commit (so the modern C API matches
# LlamaContext.swift).
#
# Mac only. One-time deps: full Xcode + `brew install cmake`.
#
#   bash Tools/build_llama_xcframework.sh              # builds at LLAMA_REF (default: master)
#   LLAMA_REF=bXXXX bash Tools/build_llama_xcframework.sh   # pin a tag for reproducibility
#
# Output: ios/Vendor/llama.xcframework (git-ignored — large binary). After it exists,
# uncomment the `Vendor/llama.xcframework` framework dependency in project.yml, regenerate
# (xcodegen generate) and rebuild; the On-device LLM backend then activates.

set -euo pipefail

LLAMA_REF="${LLAMA_REF:-master}"
WORK="${WORK:-$HOME/llama-build}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$SCRIPT_DIR/../Vendor"

command -v cmake >/dev/null 2>&1 || { echo "error: cmake not found — brew install cmake" >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "error: Xcode not found" >&2; exit 1; }

echo "Cloning llama.cpp ($LLAMA_REF) -> $WORK"
rm -rf "$WORK"
if [ "$LLAMA_REF" = "master" ]; then
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$WORK"
else
  git clone --depth 1 --branch "$LLAMA_REF" https://github.com/ggml-org/llama.cpp.git "$WORK"
fi
cd "$WORK"
echo "llama.cpp at $(git rev-parse --short HEAD)"

echo "Building llama.xcframework (iOS / iOS-sim / macOS / visionOS / tvOS — takes a while)…"
./build-xcframework.sh

[ -d build-apple/llama.xcframework ] || { echo "error: build-apple/llama.xcframework not produced" >&2; exit 1; }

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/llama.xcframework"
cp -R build-apple/llama.xcframework "$DEST_DIR/llama.xcframework"
echo "Done: $DEST_DIR/llama.xcframework"
echo "Slices: $(ls "$DEST_DIR/llama.xcframework" | tr '\n' ' ')"
echo
echo "Next: uncomment the Vendor/llama.xcframework dependency in project.yml, then"
echo "  cd ios && xcodegen generate && xcodebuild ... build"
