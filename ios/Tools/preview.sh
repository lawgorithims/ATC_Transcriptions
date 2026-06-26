#!/usr/bin/env bash
#
# preview.sh — view + drive the iOS Simulator in a web browser, even though the build
# box (a headless Apple-Silicon Mac) has no attached display. Serves the Mac's screen
# over noVNC and launches the ATC app in the booted Simulator pointed at the real CoreML
# model, so you can watch + tap the app from any browser while a dev cert is pending
# (the Simulator needs no signing — these builds use CODE_SIGNING_ALLOWED=NO).
#
#   bash Tools/preview.sh                  # start the noVNC proxy + (once logged in) launch the app
#   bash Tools/preview.sh --replay         # use the bundled demo clips instead of the live feed
#   bash Tools/preview.sh --shot           # capture ONE screenshot of the booted Simulator
#   bash Tools/preview.sh --shots [N] [s]  # capture N screenshots, s seconds apart (default 5, 3s)
#   bash Tools/preview.sh --enable-sharing # ONE-TIME: turn on macOS Screen Sharing (asks for sudo)
#
# From your machine, tunnel the web port (only path in — nothing is exposed publicly):
#   ssh -i ~/.ssh/id_ed25519 -L 6080:localhost:6080 <user>@<host> -N
# then open http://localhost:6080/vnc.html, authenticate with the VNC password ($VNC_PW),
# LOG INTO the macOS desktop in the browser, and re-run this script.
#
# One-time prereqs: full Xcode; `setup.sh --build` (app) + `setup.sh --models` (CoreML);
# noVNC (`git clone https://github.com/novnc/noVNC ~/noVNC`) + websockify
# (`uv tool install websockify`); `displayplacer` (`brew install displayplacer`, for the
# low-lag display tuning); and Screen Sharing on (`preview.sh --enable-sharing`).
#
# Low-lag viewing: open noVNC with these query params (the Desktop launcher does this):
#   /vnc.html?autoconnect=true&resize=scale&quality=4&compression=9&show_dot=true&password=<pw>
#
# Env overrides: DEVICE, PORT, ATC_MODEL_DIR, ATC_AUDIO_DIR, ATC_STREAM_URL, NOVNC_DIR, VNC_PW.
#
set -eo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

DD="${DD:-$HOME/atc-dd}"
APP="$DD/Build/Products/Debug-iphonesimulator/ATCTranscribe.app"
BUNDLE_ID="com.flycommsight.atctranscribe"
DEVICE="${DEVICE:-iPhone 17 Pro}"
PORT="${PORT:-6080}"
NOVNC_DIR="${NOVNC_DIR:-$HOME/noVNC}"
SHOTS_DIR="${SHOTS_DIR:-$HOME/atc-preview-shots}"
VNC_PW="${VNC_PW:-atcprev8}"     # legacy VNC passwords are truncated to 8 chars
MODEL_DIR="${ATC_MODEL_DIR:-$(find "$HOME/atc-coreml/small" -name AudioEncoder.mlmodelc -exec dirname {} \; 2>/dev/null | head -1)}"
AUDIO_DIR="${ATC_AUDIO_DIR:-$HOME/ATC_Transcribe/python-legacy/tests/diagnostic_data}"
STREAM_URL="${ATC_STREAM_URL:-s1-bos.liveatc.net/katl_twr}"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# ONE-TIME: enable macOS Screen Sharing (port 5900) with a legacy VNC password so noVNC
# can reach the login window even before anyone is logged in.
if [ "${1:-}" = "--enable-sharing" ]; then
  log "enabling Screen Sharing (sudo)"
  sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -allowAccessFor -allUsers -access -on -privs -all \
    -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "$VNC_PW" -restart -agent
  sudo launchctl enable system/com.apple.screensharing 2>/dev/null || true
  sudo launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
  echo "Screen Sharing on. VNC password: $VNC_PW"
  exit 0
fi

# Capture screenshot(s) of the booted Simulator (works fully headless via simctl — no GUI
# session or VNC needed). Writes timestamped PNGs to $SHOTS_DIR for use as context.
if [ "${1:-}" = "--shot" ] || [ "${1:-}" = "--shots" ]; then
  N=1; INT=3
  [ "${1:-}" = "--shots" ] && { N="${2:-5}"; INT="${3:-3}"; }
  mkdir -p "$SHOTS_DIR"
  log "capturing $N screenshot(s) -> $SHOTS_DIR"
  i=1
  while [ "$i" -le "$N" ]; do
    f="$SHOTS_DIR/atc-$(date +%Y%m%d-%H%M%S)-$i.png"
    if xcrun simctl io booted screenshot "$f" >/dev/null 2>&1; then echo "$f"; else
      echo "capture failed — is a simulator booted? (xcrun simctl list devices | grep Booted)"; exit 1
    fi
    i=$((i + 1))
    [ "$i" -le "$N" ] && sleep "$INT"
  done
  echo "pull to your machine:  scp -i ~/.ssh/id_ed25519 '<user>@<host>:$SHOTS_DIR/*.png' ."
  exit 0
fi

SOURCE="live"; LAUNCH_SRC=(--source live --link "$STREAM_URL")
if [ "${1:-}" = "--replay" ]; then SOURCE="replay"; LAUNCH_SRC=(--source replay); fi

# 1) (re)start the noVNC web proxy, bound to localhost — reachable only via the SSH tunnel.
log "noVNC proxy on 127.0.0.1:$PORT"
[ -x "$NOVNC_DIR/utils/novnc_proxy" ] || { echo "noVNC missing at $NOVNC_DIR — git clone https://github.com/novnc/noVNC \"$NOVNC_DIR\""; exit 1; }
command -v websockify >/dev/null || { echo "websockify missing — uv tool install websockify"; exit 1; }
if ! netstat -an 2>/dev/null | grep -q "127.0.0.1.$PORT .*LISTEN"; then
  pkill -f "websockify.*$PORT" 2>/dev/null || true
  nohup websockify --web "$NOVNC_DIR" "127.0.0.1:$PORT" localhost:5900 </dev/null >/tmp/novnc.log 2>&1 &
  disown 2>/dev/null || true
  sleep 2
fi
if netstat -an 2>/dev/null | grep "127.0.0.1.$PORT" | grep -q LISTEN; then
  echo "proxy up — tunnel with: ssh -L $PORT:localhost:$PORT <user>@<host> -N ; open http://localhost:$PORT/vnc.html (pw $VNC_PW)"
else
  echo "proxy may not be listening — see /tmp/novnc.log"; tail -5 /tmp/novnc.log 2>/dev/null || true
fi

# 2) The GUI steps need a logged-in desktop session — there's no display otherwise.
if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  cat <<EOF

No desktop session yet. In the browser (http://localhost:$PORT/vnc.html) LOG INTO the
macOS desktop, then re-run:  bash Tools/preview.sh
EOF
  exit 0
fi

# 2b) Tune the headless display for low-lag VNC: smaller resolution, bigger cursor, hidden
# Dock. Best-effort (needs `displayplacer`); override via PREVIEW_RES / CURSOR_SIZE.
PREVIEW_RES="${PREVIEW_RES:-1024x768}"
if command -v displayplacer >/dev/null; then
  SID=$(displayplacer list 2>/dev/null | awk '/Persistent screen id:/{print $4; exit}')
  [ -n "$SID" ] && displayplacer "id:$SID res:$PREVIEW_RES hz:60 color_depth:8 scaling:off origin:(0,0) degree:0" >/dev/null 2>&1 && echo "display -> $PREVIEW_RES"
fi
defaults write com.apple.universalaccess mouseDriverCursorSize -float "${CURSOR_SIZE:-3.0}" >/dev/null 2>&1 || true
defaults write com.apple.dock autohide -bool true >/dev/null 2>&1 && killall Dock >/dev/null 2>&1 || true

# 3) Boot the simulator, surface its window, install + launch the app on the real model.
log "Simulator + app ($DEVICE, source=$SOURCE)"
[ -d "$APP" ] || { echo "app not built — bash Tools/setup.sh --build"; exit 1; }
[ -n "$MODEL_DIR" ] || { echo "no CoreML model under ~/atc-coreml/small — bash Tools/setup.sh --models"; exit 1; }
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open "$(xcode-select -p)/Applications/Simulator.app"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted "$BUNDLE_ID" --model-dir "$MODEL_DIR" --audio-dir "$AUDIO_DIR" "${LAUNCH_SRC[@]}" --correct

cat <<EOF

App launched in the Simulator. In the browser, press Start to transcribe the $SOURCE
source (live feeds are bursty — give it 30-60s), or use the input dropdown to switch
sources. Re-run this script anytime to relaunch.
EOF
