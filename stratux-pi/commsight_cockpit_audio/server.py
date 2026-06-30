"""HTTP server: a single cockpit-audio client (the iPad) streams PCM; /health reports status.

Endpoints:
  GET /health     → JSON status (resolved device, capture device list, busy flag)
  GET /audio.raw  → raw 16 kHz mono S16LE PCM stream (what CommSight reads)
  GET /audio.wav  → same audio wrapped in a streaming WAV header (handy for ffplay/a browser)

One capture at a time (the USB adapter is a single input); a second client gets HTTP 409.
"""
import json
import signal
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import __version__, capture
from .config import Config


def _kill(proc):
    try:
        proc.terminate()
        proc.wait(timeout=1)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CommSightCockpitAudio/" + __version__
    config: Config = None                       # injected by make_server
    capture_lock: threading.Lock = None         # injected by make_server

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args))

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/health"):
            return self._health()
        if path == "/audio.raw":
            return self._stream(wav=False)
        if path == "/audio.wav":
            return self._stream(wav=True)
        self._json(404, {"ok": False, "error": "not_found",
                         "paths": ["/health", "/audio.raw", "/audio.wav"]})

    def _health(self):
        cfg = self.config
        device = capture.resolve_device(cfg.device)
        self._json(200, {
            "service": "commsight-cockpit-audio",
            "version": __version__,
            "ok": capture.have_arecord() and capture.device_present(device),
            "audio_url": "/audio.raw",
            "wav_url": "/audio.wav",
            "arecord": capture.have_arecord(),
            "configured_device": cfg.device,
            "resolved_device": device,
            "device_present": capture.device_present(device),
            "capture_devices": capture.list_capture_devices(),
            "rate": cfg.rate, "channels": cfg.channels, "format": cfg.fmt,
            "frame_bytes_20ms": cfg.frame_bytes,
            "streaming": self.capture_lock.locked(),
        })

    def _stream(self, wav):
        cfg = self.config
        if not capture.have_arecord():
            return self._json(503, {"ok": False, "error": "arecord_not_found",
                                    "hint": "sudo apt-get install -y alsa-utils"})
        if not self.capture_lock.acquire(blocking=False):
            return self._json(409, {"ok": False, "error": "audio_stream_already_in_use"})
        proc = None
        try:
            device = capture.resolve_device(cfg.device)
            cmd = capture.arecord_command(device, cfg.rate, cfg.channels, cfg.fmt, wav)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            # A blocking read returns audio if arecord started, or empty if it died (bad device /
            # busy) — distinguish those before committing to a 200 response.
            first = proc.stdout.read(cfg.frame_bytes)
            if not first:
                detail = (proc.stderr.read() or b"").decode("utf-8", "replace").strip()
                return self._json(503, {"ok": False, "error": "capture_failed",
                                        "device": device, "detail": detail[:300]})
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav" if wav else "application/octet-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.send_header("X-Audio-Format", cfg.fmt)
            self.send_header("X-Audio-Rate", str(cfg.rate))
            self.send_header("X-Audio-Channels", str(cfg.channels))
            self.end_headers()
            self.wfile.write(first)
            self.wfile.flush()
            while True:
                data = proc.stdout.read(cfg.frame_bytes)
                if not data:
                    break
                self.wfile.write(data)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass                                 # the iPad disconnected — normal
        except Exception as exc:
            try:
                self._json(500, {"ok": False, "error": str(exc)})
            except Exception:
                pass
        finally:
            if proc is not None:
                _kill(proc)
            self.capture_lock.release()


def make_server(cfg: Config) -> ThreadingHTTPServer:
    handler = type("_BoundHandler", (_Handler,),
                   {"config": cfg, "capture_lock": threading.Lock()})
    return ThreadingHTTPServer((cfg.bind_host, cfg.port), handler)


def serve(cfg: Config):
    srv = make_server(cfg)
    signal.signal(signal.SIGTERM, lambda *_: srv.shutdown())
    signal.signal(signal.SIGINT, lambda *_: srv.shutdown())
    device = capture.resolve_device(cfg.device)
    print("commsight-cockpit-audio v%s on %s:%d  device=%s (%s)  %dHz x%d %s"
          % (__version__, cfg.bind_host, cfg.port, device, cfg.device, cfg.rate, cfg.channels, cfg.fmt),
          flush=True)
    if not capture.device_present(device):
        print("WARNING: capture device %s not found — check the USB adapter / AUDIO_DEVICE "
              "(arecord -l)." % device, flush=True)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
