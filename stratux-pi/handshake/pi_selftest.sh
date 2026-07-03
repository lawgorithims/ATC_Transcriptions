#!/usr/bin/env bash
# CommSight cockpit-audio Pi self-test.
#
# Runs ON the Raspberry Pi (the Stratux box). This file may live on the FAT32
# boot partition (/boot/firmware/stratux-pi/...), where the exec bit cannot be
# trusted, so ALWAYS run it as:
#
#     bash pi_selftest.sh
#
# Checks: python3, arecord, ALSA capture devices, the cockpit-audio systemd
# service, GET /health on localhost, and 2 seconds of /audio.raw bytes at a
# plausible rate. Prints PASS/FAIL/WARN lines; exits 0 only if nothing FAILed.
#
# Uses only bash + python3 stdlib (no curl, no pip).

set -u

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { printf 'PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { printf 'WARN  %s\n' "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
note() { printf 'NOTE  %s\n' "$1"; }

echo "== CommSight cockpit-audio Pi self-test =="
echo

# ---- port: env AUDIO_PORT wins, then /etc/default/cockpit-audio, then 8090
PORT="${AUDIO_PORT:-}"
if [ -z "$PORT" ] && [ -r /etc/default/cockpit-audio ]; then
    PORT="$(sed -n 's/^[[:space:]]*AUDIO_PORT=//p' /etc/default/cockpit-audio | tail -n 1 | tr -d "\"'")"
fi
PORT="${PORT:-8090}"
note "using audio port $PORT (env AUDIO_PORT / /etc/default/cockpit-audio / default)"

# ---- overlay warning (Stratux image: RAM upper layer eats installs)
FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || true)"
if [ "$FSTYPE" = "overlay" ]; then
    note "root filesystem is an overlay (RAM upper layer): anything installed or configured NOW will VANISH at the next power cycle. To make changes stick: sudo overlayctl disable && sudo reboot, install/set gain, then sudo overlayctl enable && sudo reboot."
fi

# ---- 1. python3
HAVE_PY=0
if command -v python3 >/dev/null 2>&1; then
    PYVER="$(python3 --version 2>&1)"
    pass "python3 present: $PYVER"
    HAVE_PY=1
else
    fail "python3 not found -- the sidecar and this self-test both need it"
fi

# ---- 2. arecord
if command -v arecord >/dev/null 2>&1; then
    pass "arecord present: $(command -v arecord)"
else
    fail "arecord not found -- fix: sudo apt-get install -y alsa-utils (remember the overlay note above)"
fi

# ---- 3. at least one ALSA capture device
if command -v arecord >/dev/null 2>&1; then
    CARDS="$(arecord -l 2>/dev/null | grep '^card ' || true)"
    if [ -n "$CARDS" ]; then
        pass "capture device(s) found:"
        printf '%s\n' "$CARDS" | sed 's/^/          /'
    else
        fail "no ALSA capture devices in 'arecord -l' -- is the USB audio adapter plugged in? Try another USB port; check 'lsusb' and 'dmesg | tail'."
    fi
else
    warn "skipping capture-device check (no arecord)"
fi

# ---- 4. cockpit-audio service state
if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; cannot check the cockpit-audio service"
elif systemctl cat cockpit-audio.service >/dev/null 2>&1; then
    STATE="$(systemctl is-active cockpit-audio 2>/dev/null || true)"
    ENABLED="$(systemctl is-enabled cockpit-audio 2>/dev/null || true)"
    if [ "$STATE" = "active" ]; then
        pass "cockpit-audio service is active (boot-enable state: $ENABLED)"
    else
        fail "cockpit-audio service is installed but '$STATE' -- try: sudo systemctl start cockpit-audio; logs: journalctl -u cockpit-audio -n 50"
    fi
    if [ "$ENABLED" != "enabled" ]; then
        warn "cockpit-audio is not enabled at boot ('$ENABLED') -- fix: sudo systemctl enable cockpit-audio (with the overlay disabled, or it will not stick)"
    fi
else
    warn "cockpit-audio service is not installed -- run: sudo bash install.sh (from the stratux-pi folder). IMPORTANT on the Stratux image: disable the overlay first (sudo overlayctl disable && sudo reboot) or the install evaporates at the next power cycle."
fi

# ---- 5. GET /health on localhost (python3 urllib; curl may not exist)
STREAMING=no
HEALTH_RC=99
if [ "$HAVE_PY" -eq 1 ]; then
    HEALTH_OUT="$(python3 - "$PORT" <<'PYEOF'
import json, sys, urllib.request
port = sys.argv[1]
url = "http://127.0.0.1:%s/health" % port
try:
    with urllib.request.urlopen(url, timeout=5) as r:
        d = json.load(r)
except Exception as e:
    print("unreachable: %s" % e)
    sys.exit(1)
print("ok=%s arecord=%s device_present=%s resolved_device=%s streaming=%s" % (
    str(d.get("ok")).lower(), str(d.get("arecord")).lower(),
    str(d.get("device_present")).lower(), d.get("resolved_device"),
    str(d.get("streaming")).lower()))
sys.exit(0 if d.get("ok") is True else 2)
PYEOF
)"
    HEALTH_RC=$?
    case $HEALTH_RC in
        0) pass "GET /health on 127.0.0.1:$PORT -> $HEALTH_OUT" ;;
        2) fail "GET /health reports NOT ok -> $HEALTH_OUT (check the USB audio adapter and arecord)" ;;
        *) fail "GET /health unreachable on 127.0.0.1:$PORT ($HEALTH_OUT) -- is the cockpit-audio service running? journalctl -u cockpit-audio -n 50" ;;
    esac
    case "$HEALTH_OUT" in
        *"streaming=true"*) STREAMING=yes ;;
    esac
else
    fail "skipping /health check (no python3)"
fi

# ---- 6. two seconds of /audio.raw at a plausible byte rate (~32000 B/s)
if [ "$HAVE_PY" -ne 1 ]; then
    fail "skipping /audio.raw check (no python3)"
elif [ "$HEALTH_RC" -ne 0 ]; then
    warn "skipping /audio.raw check (health check did not pass)"
elif [ "$STREAMING" = "yes" ]; then
    warn "skipping /audio.raw check: another client is streaming right now (the iPad?). That itself proves the stream works; disconnect it and rerun for a full local test."
else
    AUDIO_OUT="$(python3 - "$PORT" <<'PYEOF'
import http.client, sys, time
port = int(sys.argv[1])
try:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/audio.raw", headers={"Connection": "close"})
    r = conn.getresponse()
except Exception as e:
    print("cannot open /audio.raw: %s" % e)
    sys.exit(1)
if r.status == 409:
    print("HTTP 409: another client holds the stream (the iPad?) -- disconnect it and rerun")
    sys.exit(1)
if r.status != 200:
    body = r.read(300)
    print("HTTP %d: %r" % (r.status, body))
    sys.exit(1)
try:
    first = r.read(640)
except Exception as e:
    print("no first frame: %s" % e)
    sys.exit(1)
if not first:
    print("HTTP 200 but zero bytes")
    sys.exit(1)
t0 = time.time()
n = 0
while time.time() - t0 < 2.0:
    try:
        b = r.read(3200)
    except Exception as e:
        print("stream stalled after %d bytes: %s" % (n, e))
        sys.exit(1)
    if not b:
        print("stream closed early after %d bytes" % n)
        sys.exit(1)
    n += len(b)
elapsed = time.time() - t0
rate = n / max(elapsed, 0.001)
print("%d bytes in %.1f s = %.0f B/s (expect ~32000)" % (n, elapsed, rate))
sys.exit(0 if 27200 <= rate <= 36800 else 1)
PYEOF
)"
    AUDIO_RC=$?
    if [ "$AUDIO_RC" -eq 0 ]; then
        pass "/audio.raw streamed 2 s -> $AUDIO_OUT"
    else
        fail "/audio.raw stream check -> $AUDIO_OUT"
    fi
fi

# ---- summary
echo
echo "self-test: $PASS_COUNT passed, $FAIL_COUNT failed, $WARN_COUNT warnings"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "PI SIDE LOOKS GOOD -- now run handshake_test.py from a laptop on the stratux WiFi."
    exit 0
fi
echo "FIX THE FAIL LINES ABOVE, then rerun: bash pi_selftest.sh"
exit 1
