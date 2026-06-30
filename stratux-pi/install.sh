#!/usr/bin/env bash
#
# Install the CommSight cockpit-audio gateway on a Raspberry Pi (beside Stratux).
# Idempotent: re-running upgrades the code and restarts the service. Leaves an existing
# /etc/default/cockpit-audio config untouched.
#
#   sudo ./install.sh
#
set -euo pipefail

PREFIX="${PREFIX:-/opt/commsight}"
SERVICE="cockpit-audio"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo:  sudo ./install.sh" >&2
  exit 1
fi

echo "== dependencies =="
if ! command -v arecord >/dev/null 2>&1; then
  echo "  installing alsa-utils..."; apt-get update -qq && apt-get install -y -qq alsa-utils
fi
command -v python3 >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3; }
echo "  arecord: $(command -v arecord)   python3: $(python3 --version 2>&1)"

echo "== install code -> $PREFIX =="
mkdir -p "$PREFIX"
rm -rf "$PREFIX/commsight_cockpit_audio"
cp -r "$HERE/commsight_cockpit_audio" "$PREFIX/"
install -m 0755 "$HERE/bin/detect-audio" "$PREFIX/detect-audio"
install -m 0755 "$HERE/bin/record-test" "$PREFIX/record-test"

echo "== config -> /etc/default/$SERVICE =="
if [ -f "/etc/default/$SERVICE" ]; then
  echo "  exists — left unchanged (edit it to change AUDIO_DEVICE / AUDIO_PORT)"
else
  install -m 0644 "$HERE/cockpit-audio.env" "/etc/default/$SERVICE"
  echo "  wrote defaults"
fi

echo "== capture devices =="
( cd "$PREFIX" && python3 -m commsight_cockpit_audio --list-devices ) || true

echo "== systemd service =="
sed "s#@PREFIX@#$PREFIX#g" "$HERE/cockpit-audio.service" > "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
systemctl enable "$SERVICE.service" >/dev/null 2>&1 || true
systemctl restart "$SERVICE.service"
sleep 1
systemctl --no-pager --lines=0 status "$SERVICE.service" || true

PORT="$(grep -E '^AUDIO_PORT=' "/etc/default/$SERVICE" 2>/dev/null | cut -d= -f2)"; PORT="${PORT:-8090}"
echo
echo "Installed. Verify:   curl http://localhost:${PORT}/health"
echo "In CommSight:        Settings -> Stratux receiver -> set this Pi's address (port ${PORT}),"
echo "                     pick \"Stratux receiver\" as the input source, then Start."
