#!/usr/bin/env bash
#
# Run the nav cycle watchdog and email when it is unhappy. Driven by nav-cycle-watch.timer.
#
# ⚠️ IT EMAILS ON FAILURE *AND* ON "CANNOT TELL". A watchdog that goes quiet when the network is
# down looks exactly like a watchdog reporting all-clear, and that is the one outcome this must
# never produce. Exit 3 is therefore an alert, not a skip.
#
# ⚠️ IT DOES NOT SEND THE SAME MAIL EVERY DAY. A daily message that says the same thing for three
# weeks stops being read, which is how the alert itself becomes the next silent failure. The state
# file holds the last status sent; a repeat waits for the status to CHANGE or for
# ESCALATE_AFTER_DAYS to pass. The all-clear is sent once, so a fixed problem visibly closes.
#
# ⚠️ NO NEW SECRETS. It sends through the SAME SMTP credentials the website already uses for
# password-reset mail — SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, MAIL_FROM — so there is nothing
# extra to rotate and nothing extra to leak. Point ENV_FILE at the site's env file; the installer
# defaults it to /etc/obelisk/nav-watch.env, which should simply source the site's.
# The repo is PUBLIC: no value belongs in this file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-/usr/bin/python3}"
STATE="${STATE_DIRECTORY:-/var/lib/obelisk-nav-watch}/last-status"
ESCALATE_AFTER_DAYS="${ESCALATE_AFTER_DAYS:-7}"
ALERT_TO="${ALERT_TO:-}"

REPORT="$("$PY" -I "$HERE/cycle_watch.py" 2>&1)"
CODE=$?

case "$CODE" in
  0) STATUS=current  ;;
  1) STATUS=expired  ;;
  2) STATUS=expiring ;;
  *) STATUS=unknown  ;;
esac

mkdir -p "$(dirname "$STATE")"
LAST=""; LAST_T=0
[ -f "$STATE" ] && { LAST="$(cut -d' ' -f1 "$STATE")"; LAST_T="$(cut -d' ' -f2 "$STATE")"; }
NOW="$(date -u +%s)"
DAYS_SINCE=$(( (NOW - ${LAST_T:-0}) / 86400 ))

SEND=0
if [ "$STATUS" != current ]; then
  [ "$STATUS" != "$LAST" ] || [ "$DAYS_SINCE" -ge "$ESCALATE_AFTER_DAYS" ] && SEND=1
elif [ -n "$LAST" ] && [ "$LAST" != current ]; then
  SEND=1
fi

printf '%s %s\n' "$STATUS" "$NOW" > "$STATE"
echo "$REPORT"
[ "$SEND" -eq 1 ] || exit "$CODE"

SUBJECT="Obelisk nav data: ${STATUS}"
[ "$STATUS" = expired ]  && SUBJECT="ACTION NEEDED — Obelisk nav data has EXPIRED"
[ "$STATUS" = expiring ] && SUBJECT="Obelisk nav data expires soon — build and stage the next cycle"
[ "$STATUS" = unknown ]  && SUBJECT="Obelisk nav watchdog could not check"
[ "$STATUS" = current ]  && SUBJECT="Obelisk nav data is current again"

if [ -z "${SMTP_HOST:-}" ] || [ -z "$ALERT_TO" ]; then
  # Exit non-zero so systemd records a failed unit: an alert that could not be sent is itself the
  # thing worth noticing, and must not look like a quiet success.
  echo "cannot send mail: SMTP_HOST or ALERT_TO not set (see nav/deploy/README.md)" >&2
  exit 1
fi

BODY="$REPORT

--
nav-cycle-watch on $(hostname -s). To close it:

  Publish a built cycle that is already in force
    python3 nav/publish_nav.py --publish --from-dir <build dir>

  Stage the next one ahead of its date, so the roll is invisible
    python3 ios/Tools/build_procedures.py --metafile \\
      https://aeronav.faa.gov/d-tpp/<cycle>/xml_data/d-TPP_Metafile.xml --out <dir>/procedures.json
    python3 nav/publish_nav.py --stage-next --from-dir <dir>

  All three datasets must move together: procedures.json's cycle goes into the plate URL, and the
  FAA ages old cycles off, so a mixed cycle 404s every plate."

ALERT_TO="$ALERT_TO" SUBJECT="$SUBJECT" BODY="$BODY" "$PY" - <<'PYEOF'
import os, smtplib, ssl
from email.message import EmailMessage

m = EmailMessage()
m["From"] = os.environ.get("MAIL_FROM") or os.environ["SMTP_USER"]
m["To"] = os.environ["ALERT_TO"]
m["Subject"] = os.environ["SUBJECT"]
m.set_content(os.environ["BODY"])

host, port = os.environ["SMTP_HOST"], int(os.environ.get("SMTP_PORT", "587"))
user, pw = os.environ.get("SMTP_USER"), os.environ.get("SMTP_PASS")
# 465 is implicit TLS; 587 is STARTTLS. Getting this wrong is a hang, not an error, so it is
# explicit rather than guessed — and the timeout means a wedged relay cannot stall the timer.
if port == 465:
    s = smtplib.SMTP_SSL(host, port, timeout=30, context=ssl.create_default_context())
else:
    s = smtplib.SMTP(host, port, timeout=30)
    s.starttls(context=ssl.create_default_context())
with s:
    if user and pw:
        s.login(user, pw)
    s.send_message(m)
print(f"alert sent to {os.environ['ALERT_TO']}")
PYEOF

exit "$CODE"
