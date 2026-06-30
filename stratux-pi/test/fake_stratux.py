#!/usr/bin/env python3
"""Fake Stratux + cockpit-audio sidecar — for validating the CommSight client under sustained load.

Serves all three CommSight endpoints on ONE port so the integration test can hit audio + traffic +
GPS concurrently (the "is there bandwidth / can it hold the stream up" check):

  GET /audio.raw[?drop=N]   raw 16 kHz mono S16LE PCM (a 600 Hz tone), paced at REAL TIME (32 kB/s).
                            ?drop=N closes the stream after ~N seconds to exercise client reconnect.
  GET /getSituation         Stratux SituationData JSON (a slowly moving WAAS fix).
  WS  /traffic              Stratux TrafficInfo JSON — TRAFFIC_TARGETS aircraft at TRAFFIC_HZ each.

Stdlib only (no pip). Env: PORT (9408), TRAFFIC_TARGETS (25), TRAFFIC_HZ (1.0).
"""
import base64
import hashlib
import json
import math
import os
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "9408"))
TARGETS = int(os.environ.get("TRAFFIC_TARGETS", "25"))
HZ = float(os.environ.get("TRAFFIC_HZ", "1.0"))
RATE = 16000
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# One second of a 600 Hz sine as int16 LE (600 whole cycles → loops seamlessly). Doubled so a frame
# can be sliced across the wrap with one index.
_ONE_SEC = b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 600 * (i / RATE))))
                    for i in range(RATE))
_BUF2 = _ONE_SEC * 2
_LEN = len(_ONE_SEC)


def ws_frame(text: str) -> bytes:
    payload = text.encode("utf-8")
    n = len(payload)
    if n < 126:
        header = bytes([0x81, n])
    elif n < 65536:
        header = bytes([0x81, 126]) + struct.pack(">H", n)
    else:
        header = bytes([0x81, 127]) + struct.pack(">Q", n)
    return header + payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        return

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/getSituation":
            return self._situation()
        if path == "/audio.raw":
            return self._audio()
        if path == "/traffic":
            return self._traffic_ws()
        self.send_error(404)

    def _situation(self):
        now = time.time()
        body = json.dumps({
            "GPSLatitude": 42.36 + 0.001 * math.sin(now / 30.0),
            "GPSLongitude": -71.01 + 0.001 * math.cos(now / 30.0),
            "GPSFixQuality": 2, "GPSSatellites": 11,
            "GPSAltitudeMSL": 2500.0, "GPSGroundSpeed": 120.0, "GPSTrueCourse": 270.0,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _audio(self):
        drop = 0.0
        if "?" in self.path:
            for kv in self.path.split("?", 1)[1].split("&"):
                if kv.startswith("drop="):
                    try:
                        drop = float(kv[5:])
                    except ValueError:
                        drop = 0.0
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        frame_bytes = 640                       # 20 ms (320 samples) → write 50×/s
        off = 0
        start = time.time()
        next_t = start
        try:
            while True:
                if drop and (time.time() - start) >= drop:
                    break                       # close → the client must reconnect
                self.wfile.write(_BUF2[off:off + frame_bytes])
                self.wfile.flush()
                off = (off + frame_bytes) % _LEN
                next_t += frame_bytes / 2 / RATE
                dt = next_t - time.time()
                if dt > 0:
                    time.sleep(dt)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _traffic_ws(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            return self.send_error(400)
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.close_connection = True
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\n"
                          "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.wfile.flush()
        interval = 1.0 / (max(HZ, 0.1) * max(TARGETS, 1))   # round-robin all targets at ~HZ each
        i = 0
        try:
            while True:
                tgt = i % TARGETS
                msg = {
                    "Icao_addr": 0xA00000 + tgt,
                    "Tail": "N%d" % (1000 + tgt), "Reg": "N%d" % (1000 + tgt),
                    "Lat": 42.30 + 0.01 * tgt, "Lng": -71.00 - 0.01 * tgt,
                    "Position_valid": True, "Alt": 2000 + 100 * tgt, "OnGround": False,
                    "Speed": 150, "Speed_valid": True, "Track": (tgt * 13) % 360,
                    "Distance": 1852.0 * (tgt + 1), "Age": 0.5,
                }
                self.wfile.write(ws_frame(json.dumps(msg)))
                self.wfile.flush()
                i += 1
                time.sleep(interval)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("fake-stratux on 127.0.0.1:%d  targets=%d hz=%.1f  (audio %d B/s, traffic ~%.0f msg/s)"
          % (PORT, TARGETS, HZ, RATE * 2, HZ * TARGETS), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
