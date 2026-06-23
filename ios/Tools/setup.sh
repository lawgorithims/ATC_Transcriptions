#!/usr/bin/env bash
#
# setup.sh — one-shot bootstrap for a fresh macOS (Apple Silicon) box to build the
# ATC_Transcribe iOS app and convert its fine-tuned Whisper models to CoreML.
# Idempotent and user-space (no sudo). Codifies the provisioning we otherwise do by hand.
#
#   bash Tools/setup.sh            # toolchain only: uv + Python 3.11, whisperkittools,
#                                  #   xcodegen, and the iOS simulator runtime
#   bash Tools/setup.sh --models   # also convert both Whisper models -> CoreML
#   bash Tools/setup.sh --build    # also generate the Xcode project and compile it
#   bash Tools/setup.sh --all      # toolchain + models + build
#
# Prerequisite that can't be scripted: full **Xcode** must be installed (App Store / xip)
# — it provides coremlcompiler (for CoreML conversion) and the iOS toolchain (for builds).
# Everything else is downloaded into user space by this script.
#
# Overridable via env: OUT_DIR, TURBO_REPO, SMALL_REPO, SMALL_BASE, WKT_DIR, VENV.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TURBO_REPO="${TURBO_REPO:-SingularityUS/ATC-whisper-turbo-v1}"   # complete HF repo
SMALL_REPO="${SMALL_REPO:-SingularityUS/ATC-whisper-v1}"         # weights only (no config/tokenizer)
SMALL_BASE="${SMALL_BASE:-openai/whisper-small}"                 # config + tokenizer for small
OUT_DIR="${OUT_DIR:-$HOME/atc-coreml}"
WKT_DIR="${WKT_DIR:-$HOME/whisperkittools}"
VENV="${VENV:-$HOME/wkt-env}"
XCODEGEN_DIR="${XCODEGEN_DIR:-$HOME/.xcodegen}"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

DO_MODELS=0; DO_BUILD=0
for a in "$@"; do
  case "$a" in
    --models) DO_MODELS=1 ;;
    --build)  DO_BUILD=1 ;;
    --all)    DO_MODELS=1; DO_BUILD=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) die "unknown flag: $a (try --help)" ;;
  esac
done

preflight() {
  log "preflight"
  [ "$(uname -s)" = "Darwin" ] || die "macOS only."
  command -v git >/dev/null || die "git not found."
  xcode-select -p >/dev/null 2>&1 || die "Xcode not selected. Install Xcode, then: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  xcrun --find coremlcompiler >/dev/null 2>&1 || die "coremlcompiler missing — install FULL Xcode (not just Command Line Tools)."
  echo "macOS $(sw_vers -productVersion 2>/dev/null), Xcode at $(xcode-select -p)"
}

setup_python() {
  log "uv + Python 3.11"
  if [ ! -x "$HOME/.local/bin/uv" ] && ! command -v uv >/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$HOME/.local/bin:$PATH"
  uv python install 3.11

  log "whisperkittools ($VENV)"
  [ -d "$WKT_DIR" ] || git clone --depth 1 https://github.com/argmaxinc/whisperkittools "$WKT_DIR"
  [ -d "$VENV" ] || uv venv --python 3.11 "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  uv pip install -e "$WKT_DIR"
  command -v whisperkit-generate-model >/dev/null || die "whisperkittools install failed."
}

setup_xcodegen() {
  log "xcodegen"
  if [ ! -x "$XCODEGEN_DIR/xcodegen/bin/xcodegen" ]; then
    curl -fsSL -o /tmp/xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
    rm -rf "$XCODEGEN_DIR"; mkdir -p "$XCODEGEN_DIR"
    unzip -oq /tmp/xcodegen.zip -d "$XCODEGEN_DIR"
  fi
  "$XCODEGEN_DIR/xcodegen/bin/xcodegen" --version
}

setup_ios_runtime() {
  log "iOS simulator runtime"
  if xcrun simctl list runtimes 2>/dev/null | grep -qi "iOS "; then
    echo "iOS runtime already installed."
  else
    echo "Downloading the iOS platform (multi-GB, one-time)…"
    xcodebuild -downloadPlatform iOS
  fi
}

convert_models() {
  export PATH="$HOME/.local/bin:$PATH"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  mkdir -p "$OUT_DIR"

  log "convert turbo ($TURBO_REPO)"
  whisperkit-generate-model --model-version "$TURBO_REPO" \
    --output-dir "$OUT_DIR/turbo" --generate-decoder-context-prefill-data

  log "convert small ($SMALL_BASE metadata + $SMALL_REPO weights)"
  # The fine-tuned small HF repo ships ONLY model.safetensors (no config/tokenizer), so we
  # rebuild a complete model dir from the matching base before converting. Permanent fix:
  # upload config.json + tokenizer files to $SMALL_REPO, then convert it directly.
  local SRC="$HOME/.atc-small-src"
  rm -rf "$SRC"; mkdir -p "$SRC"
  python - "$SMALL_BASE" "$SMALL_REPO" "$SRC" <<'PY'
import sys
from huggingface_hub import snapshot_download, hf_hub_download
base, repo, dst = sys.argv[1:4]
snapshot_download(base, local_dir=dst, allow_patterns=["*.json", "*.txt"])  # config + tokenizer
hf_hub_download(repo, "model.safetensors", local_dir=dst)                    # fine-tuned weights
print("reconstructed small model dir at", dst)
PY
  whisperkit-generate-model --model-version "$SRC" \
    --output-dir "$OUT_DIR/small" --generate-decoder-context-prefill-data

  log "converted models"
  find "$OUT_DIR" -name '*.mlmodelc' | sort
}

build_app() {
  log "generate + build"
  cd "$PROJECT_DIR"
  "$XCODEGEN_DIR/xcodegen/bin/xcodegen" generate
  xcodebuild -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$HOME/atc-dd" -clonedSourcePackagesDirPath "$HOME/atc-spm" \
    -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
    build-for-testing
}

preflight
setup_python
setup_xcodegen
setup_ios_runtime
if [ "$DO_MODELS" = 1 ]; then convert_models; fi
if [ "$DO_BUILD" = 1 ]; then build_app; fi

log "done"
[ "$DO_MODELS" = 1 ] && echo "Converted models: $OUT_DIR/{small,turbo}/<model>/*.mlmodelc"
echo "Toolchain ready. See README.md for pointing the app at the converted model folder."
