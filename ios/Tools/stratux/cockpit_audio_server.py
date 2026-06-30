#!/usr/bin/env python3
"""
CommSight cockpit-audio sidecar for Stratux.

Runs BESIDE Stratux on its Raspberry Pi (it does NOT touch the Stratux ADS-B/GPS/ForeFlight
services). Captures cockpit audio from a USB audio adapter via ALSA `arecord` and serves it as a raw
16 kHz mono signed-16-bit little-endian PCM stream that CommSight ("Stratux receiver" input) reads:

    http://<pi>:8090/audio.raw     # the live PCM stream (one client at a time)
    http://<pi>:8090/health        # JSON status

That raw format is CommSight's native pipeline format, so there is no decode on the app side.
Env overrides: AUDIO_DEVICE (default plughw:1,0), AUDIO_PORT (8090), AUDIO_RATE (16000),
AUDIO_CHANNELS (1). See README.md for wiring + the systemd install.
"""
import json
import os
import signal
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = int(os.environ.get("AUDIO_PORT", "8090"))
ALSA_DEVICE = os.environ.get("AUDIO_DEVICE", "plughw:1,0")
RATE = int(os.environ.get("AUDIO_RATE", "16000"))
CHANNELS = int(os.environ.get("AUDIO_CHANNELS", "1"))
FORMAT = "S16_LE"
# 20 ms of audio per write keeps latency low: 16000 * 0.020 * channels * 2 bytes.
FRAME_BYTES = int(RATE * 0.020 * CHANNELS * 2)

# One arecord capture at a time (the USB adapter is a single input).
capture_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        return  # quiet

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/health"):
            self._json(200, {
                "service": "commsight-cockpit-audio", "ok": True, "audio_url": "/audio.raw",
                "device": ALSA_DEVICE, "rate": RATE, "channels": CHANNELS,
                "format": FORMAT, "frame_bytes_20ms": FRAME_BYTES,
            })
            return
        if not self.path.startswith("/audio.raw"):
            self._json(404, {"ok": False, "error": "not_found"})
            return
        if not capture_lock.acquire(blocking=False):
            self._json(409, {"ok": False, "error": "audio_stream_already_in_use"})
            return

        proc = None
        try:
            proc = subprocess.Popen(
                ["arecord", "-D", ALSA_DEVICE, "-f", FORMAT, "-r", str(RATE),
                 "-c", str(CHANNELS), "-t", "raw", "-q"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.send_header("X-Audio-Format", FORMAT)
            self.send_header("X-Audio-Rate", str(RATE))
            self.send_header("X-Audio-Channels", str(CHANNELS))
            self.end_headers()
            while True:
                data = proc.stdout.read(FRAME_BYTES)
                if not data:
                    break
                self.wfile.write(data)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the iPad disconnected — normal
        except Exception as exc:  # pragma: no cover
            try:
                self._json(500, {"ok": False, "error": str(exc)})
            except Exception:
                pass
        finally:
            if proc is not None:
                try:
                    proc.terminate(); proc.wait(timeout=1)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
            capture_lock.release()


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    signal.signal(signal.SIGTERM, lambda *_: server.shutdown())
    signal.signal(signal.SIGINT, lambda *_: server.shutdown())
    print(f"commsight-cockpit-audio on {HOST}:{PORT}  device={ALSA_DEVICE} {RATE}Hz x{CHANNELS} {FORMAT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
