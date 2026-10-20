"""PiSugar 3 battery telemetry for /health.

The Obelisk is a battery appliance — an Orange Pi Zero 2W on a PiSugar 3 cell — and the app's
`CockpitHealth` already decodes a `battery` object it was never sent. A cockpit device whose
remaining runtime is unknowable is a device you cannot plan a flight around, which is the whole
reason the iPad asks.

HOW IT READS. The PiSugar server exposes a tiny line protocol on 127.0.0.1:8423: write a command,
read a line back ("battery: 64.5"). That is preferred over the I2C registers because it is what the
vendor supports, it needs no root and no smbus dependency, and it already handles the fuel gauge's
quirks.

EVERY FIELD IS OPTIONAL, DELIBERATELY. The app models them as optionals and renders only what
arrives (`BatteryTelemetry`), so a Stratux with no cell, a PiSugar daemon that is not running, and a
firmware that reports percentage but not current all degrade to less detail rather than to an error.
A health endpoint that 500s because the battery shim is unhappy would take the AUDIO down with it,
and audio is the thing the appliance exists to serve.
"""
from __future__ import annotations

import socket

HOST, PORT = "127.0.0.1", 8423
TIMEOUT = 0.4           # localhost; if the daemon has not answered in this long it is not well


def _ask(sock, cmd):
    """One request/response on an open socket. None on anything unexpected."""
    try:
        sock.sendall((cmd + "\n").encode())
        line = sock.recv(256).decode("utf-8", "replace").strip()
    except OSError:
        return None
    # Replies look like "battery: 64.5" — take the value, tolerate a bare one.
    return line.split(":", 1)[1].strip() if ":" in line else (line or None)


def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def read():
    """Battery state, or None when there is no PiSugar to ask.

    None rather than an empty dict on purpose: the app distinguishes "this appliance has no battery"
    (a Stratux) from "it has one and here is nothing about it", and `battery: null` is how that is
    said over the wire.
    """
    try:
        sock = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
    except OSError:
        return None                      # no daemon, no cell, or not an Obelisk — all normal
    try:
        sock.settimeout(TIMEOUT)
        pct = _f(_ask(sock, "get battery"))
        if pct is None:
            return None                  # answered, but not about a battery
        volts = _f(_ask(sock, "get battery_v"))
        amps = _f(_ask(sock, "get battery_i"))
        charging = _ask(sock, "get battery_charging")
        temp = _f(_ask(sock, "get temperature"))

        out = {"percent": pct}
        if volts is not None:
            out["voltage"] = round(volts, 3)
        if amps is not None:
            out["current"] = round(amps, 3)
        if charging is not None:
            out["charging"] = charging.strip().lower() in ("true", "1", "yes")
        if temp is not None:
            out["temperature_c"] = round(temp, 1)

        # Runtime estimate, only when the cell is actually discharging and we know the draw. The
        # PiSugar reports current as NEGATIVE while discharging; a positive reading means it is on
        # charge and "minutes remaining" is meaningless, so it is omitted rather than guessed.
        if amps is not None and amps < -0.01 and not out.get("charging"):
            capacity_mah = 1200.0        # PiSugar 3 (Zero) cell
            remaining_mah = capacity_mah * max(0.0, min(100.0, pct)) / 100.0
            hours = remaining_mah / (abs(amps) * 1000.0)
            out["minutes_remaining"] = int(hours * 60)
        return out
    finally:
        sock.close()
