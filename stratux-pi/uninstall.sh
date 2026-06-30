#!/usr/bin/env bash
#
# Remove the CommSight cockpit-audio gateway. Does NOT touch Stratux.
#
#   sudo ./uninstall.sh
#
set -euo pipefail

PREFIX="${PREFIX:-/opt/commsight}"
SERVICE="cockpit-audio"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo:  sudo ./uninstall.sh" >&2
  exit 1
fi

systemctl disable --now "$SERVICE.service" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
rm -rf "$PREFIX"
echo "Removed $PREFIX and the $SERVICE service."
echo "(/etc/default/$SERVICE left in place — delete it manually if you want.)"
