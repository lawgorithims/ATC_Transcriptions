#!/usr/bin/env bash
#
# Install the nav cycle watchdog on the box. RUN THIS ON THE EC2 HOST, as a user with sudo.
#
#   scp -r nav/cycle_watch.py nav/deploy <you>@<box>:/tmp/navwatch/
#   ssh <you>@<box> 'sudo ALERT_TO=you@example.com bash /tmp/navwatch/deploy/install.sh'
#
# Idempotent: run it again to upgrade. It only ever adds; it removes nothing it did not create.
#
# ⚠️ IT ADDS NO NEW SECRET. Alerting reuses the SMTP credentials the website already has for
# password-reset mail, by sourcing the site's env file. Nothing is copied, duplicated or rotated.
set -euo pipefail

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[1;36m== %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SRC/../cycle_watch.py" ] || [ -f "$SRC/cycle_watch.py" ] || \
  die "cycle_watch.py not found beside this script — copy it over too"
WATCHDOG="$([ -f "$SRC/cycle_watch.py" ] && echo "$SRC/cycle_watch.py" || echo "$SRC/../cycle_watch.py")"

RUN_USER="${RUN_USER:-obelisk}"
SITE_ENV="${SITE_ENV:-/opt/obelisk-web/.env}"
ALERT_TO="${ALERT_TO:-}"
[ -n "$ALERT_TO" ] || die "set ALERT_TO=you@example.com — an alert with nowhere to go is not an alert"

id -u "$RUN_USER" >/dev/null 2>&1 || die "user '$RUN_USER' does not exist (set RUN_USER=)"
[ -f "$SITE_ENV" ] || die "no site env at $SITE_ENV — set SITE_ENV= to the file holding SMTP_HOST etc.
The watchdog reuses the website's mail credentials rather than adding a second copy of them."
grep -q '^SMTP_HOST=' "$SITE_ENV" || die "$SITE_ENV has no SMTP_HOST; alerting would have nowhere to send"

say "python3 present?"
command -v python3 >/dev/null || die "python3 not installed"
python3 -c 'import urllib.request, smtplib, json' || die "python3 is missing stdlib modules"

say "install the watchdog to /opt/obelisk/nav"
install -d -m 755 /opt/obelisk/nav
install -m 755 "$WATCHDOG" /opt/obelisk/nav/cycle_watch.py
install -m 755 "$SRC/alert_on_stale.sh" /opt/obelisk/nav/alert_on_stale.sh

say "env file (no secrets of its own — it sources the site's)"
install -d -m 755 /etc/obelisk
if [ ! -f /etc/obelisk/nav-watch.env ]; then
  cat > /etc/obelisk/nav-watch.env <<ENV
# Where the alert goes.
ALERT_TO=$ALERT_TO
# Mail credentials come from the website's own env — one copy, one rotation.
ENV
  # systemd's EnvironmentFile cannot source another file, so the site's values are read at run
  # time by the unit's ExecStart wrapper instead. Record the path for it here.
  echo "SITE_ENV=$SITE_ENV" >> /etc/obelisk/nav-watch.env
  chmod 600 /etc/obelisk/nav-watch.env
  echo "  wrote /etc/obelisk/nav-watch.env"
else
  echo "  /etc/obelisk/nav-watch.env exists — left alone"
fi

say "systemd units"
sed -e "s|^User=.*|User=$RUN_USER|" -e "s|^Group=.*|Group=$RUN_USER|" \
    "$SRC/nav-cycle-watch.service" > /etc/systemd/system/nav-cycle-watch.service
install -m 644 "$SRC/nav-cycle-watch.timer" /etc/systemd/system/nav-cycle-watch.timer
systemctl daemon-reload
systemctl enable --now nav-cycle-watch.timer

say "run it once now, so a broken install fails here and not silently in a month"
if systemctl start nav-cycle-watch.service; then
  echo "  first run OK"
else
  echo "  first run reported a problem — that may be the watchdog correctly saying the cycle is"
  echo "  stale, which is a FINDING, not an install failure. Read the log:"
fi
journalctl -u nav-cycle-watch.service -n 25 --no-pager || true

say "next run"
systemctl list-timers nav-cycle-watch.timer --no-pager || true
echo
echo "Installed. It checks daily at 1000Z and mails $ALERT_TO when the published cycle is"
echo "expired, expiring, or cannot be checked at all."
