#!/usr/bin/env bash
#
# Run the nav cycle watchdog and email when it is unhappy. Driven by nav-cycle-watch.timer.
#
# ⚠️ IT EMAILS ON FAILURE *AND* ON "CANNOT TELL". A watchdog that goes quiet when the network is
# down looks exactly like a watchdog reporting all-clear, and that is the one outcome this must
# never produce. Exit 3 is therefore an alert, not a skip.
#
# ⚠️ IT DOES NOT EMAIL THE SAME STATE TWICE A DAY, FOREVER. A daily mail saying the same thing for
# three weeks is how an alert becomes furniture and stops being read. The state file holds the last
# status sent; a repeat is suppressed until the status CHANGES or ESCALATE_AFTER_DAYS passes.
#
# Secrets come from the environment, never this file: the repo is PUBLIC.
#   RESEND_API_KEY   the same key the website uses for transactional mail
#   ALERT_TO         where to send it
#   ALERT_FROM       a verified sender on the DKIM-aligned domain
# Put them in /etc/obelisk/nav-watch.env (chmod 600) and add to the unit:
#   EnvironmentFile=/etc/obelisk/nav-watch.env
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-/usr/bin/python3}"
STATE="${STATE_DIRECTORY:-/var/lib/obelisk-nav-watch}/last-status"
ESCALATE_AFTER_DAYS="${ESCALATE_AFTER_DAYS:-7}"

REPORT="$("$PY" -I "$HERE/../cycle_watch.py" 2>&1)"
CODE=$?

case "$CODE" in
  0) STATUS=current  ;;
  1) STATUS=expired  ;;
  2) STATUS=expiring ;;
  *) STATUS=unknown  ;;
esac

# Nothing to say, and nothing was wrong last time either.
LAST=""; LAST_DAY=0
[ -f "$STATE" ] && { LAST="$(cut -d' ' -f1 "$STATE")"; LAST_DAY="$(cut -d' ' -f2 "$STATE")"; }
TODAY="$(date -u +%s)"
DAYS_SINCE=$(( (TODAY - ${LAST_DAY:-0}) / 86400 ))

SEND=0
if [ "$STATUS" != current ]; then
  # New problem, a changed problem, or an old one that has gone unfixed long enough to repeat.
  if [ "$STATUS" != "$LAST" ] || [ "$DAYS_SINCE" -ge "$ESCALATE_AFTER_DAYS" ]; then SEND=1; fi
elif [ -n "$LAST" ] && [ "$LAST" != current ]; then
  SEND=1                      # the all-clear: say so once, so a fixed alert visibly closes
fi

printf '%s %s\n' "$STATUS" "$TODAY" > "$STATE"
echo "$REPORT"
[ "$SEND" -eq 1 ] || exit 0

SUBJECT="Obelisk nav data: ${STATUS}"
[ "$STATUS" = expired ] && SUBJECT="ACTION NEEDED — Obelisk nav data has EXPIRED"
[ "$STATUS" = unknown ] && SUBJECT="Obelisk nav watchdog could not check"

if [ -z "${RESEND_API_KEY:-}" ] || [ -z "${ALERT_TO:-}" ] || [ -z "${ALERT_FROM:-}" ]; then
  # Still exit non-zero so systemd records a failed unit: an alert that could not be sent is
  # itself the thing worth noticing.
  echo "cannot send mail: RESEND_API_KEY / ALERT_TO / ALERT_FROM not set" >&2
  exit 1
fi

BODY="$REPORT

--
nav-cycle-watch on $(hostname). Publishing a built cycle:
  python3 nav/publish_nav.py --publish --from-dir <build dir>
Staging one ahead of its effective date, so the roll is invisible:
  python3 nav/publish_nav.py --stage-next --from-dir <next-cycle dir>"

"$PY" - "$SUBJECT" "$BODY" <<'PYEOF'
import json, os, sys, urllib.request
subject, body = sys.argv[1], sys.argv[2]
payload = json.dumps({"from": os.environ["ALERT_FROM"], "to": [os.environ["ALERT_TO"]],
                      "subject": subject, "text": body}).encode()
req = urllib.request.Request("https://api.resend.com/emails", data=payload, method="POST",
                             headers={"Authorization": f"Bearer {os.environ['RESEND_API_KEY']}",
                                      "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as r:
    print(f"alert sent: HTTP {r.status}")
PYEOF
exit "$CODE"
