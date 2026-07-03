"""HTTP server: a single cockpit-audio client (the iPad) streams PCM; /health reports status.

Endpoints:
  GET /health     → JSON status (resolved device, capture device list, busy flag)
  GET /audio.raw  → raw 16 kHz mono S16LE PCM stream (what CommSight reads)
  GET /audio.wav  → same audio wrapped in a streaming WAV header (handy for ffplay/a browser)

One capture at a time (the USB adapter is a single input); a second client gets HTTP 409.
"""
import json
import signal
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import __version__, capture
from .config import Config
from .ledmeter import LedMeter


def _kill(proc):
    try:
        proc.terminate()
        proc.wait(timeout=1)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=1)              # reap, or the dead arecord lingers as a zombie
        except Exception:
            pass


def _drain(pipe):
    """Read a pipe to EOF and discard — runs on a daemon thread while a capture streams."""
    try:
        while pipe.read(65536):
            pass
    except Exception:
        pass


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CommSightCockpitAudio/" + __version__
    # Socket timeout (BaseHTTPRequestHandler applies it to the connection). Without it an iPad
    # that drops off the WiFi uncleanly leaves sends stuck in kernel retransmit for ~15 min
    # while holding the single-stream lock, so every reconnect gets 409.
    timeout = 10
    config: Config = None                       # injected by make_server
    capture_lock: threading.Lock = None         # injected by make_server
    led_meter: LedMeter = None                  # injected by serve (None when disabled)

    def setup(self):
        # Keepalive catches the half-open case with no data in flight (idle connection) in
        # ~10 s; the timeout above catches the blocked-send case.
        s = self.request
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        for opt, val in (("TCP_KEEPIDLE", 5), ("TCP_KEEPINTVL", 2), ("TCP_KEEPCNT", 3)):
            if hasattr(socket, opt):
                try:
                    s.setsockopt(socket.IPPROTO_TCP, getattr(socket, opt), val)
                except OSError:
                    pass
        super().setup()

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
        meter = self.led_meter
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
            # The idle LED meter also holds capture_lock between real clients — don't report that
            # as "an iPad is streaming".
            "streaming": self.capture_lock.locked() and not (meter and meter.holding),
            "led_meter": meter.status() if meter else {"enabled": False},
        })

    def _stream(self, wav):
        cfg = self.config
        if not capture.have_arecord():
            return self._json(503, {"ok": False, "error": "arecord_not_found",
                                    "hint": "sudo apt-get install -y alsa-utils"})
        # The idle LED meter shares the capture device: tell it to yield, then wait briefly for
        # its arecord to die. A GENUINE second client still 409s — the meter releases within a
        # frame, so the only way the timeout expires is another client holding the stream.
        meter = self.led_meter
        acquired = self.capture_lock.acquire(blocking=False)
        if not acquired and meter is not None and meter.holding:
            meter.yield_now()
            acquired = self.capture_lock.acquire(timeout=2.0)
        if not acquired:
            return self._json(409, {"ok": False, "error": "audio_stream_already_in_use"})
        if meter is not None:
            meter.yield_now()                   # keep the idle loop parked while we stream
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
            # arecord keeps writing warnings ("overrun!!!") to stderr; drain them or the 64 KiB
            # pipe fills and freezes capture mid-stream. (Closing the pipe instead would
            # SIGPIPE-kill arecord on its next warning.)
            threading.Thread(target=_drain, args=(proc.stderr,), daemon=True).start()
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
            if meter is not None and not wav:
                meter.feed(first)               # wav's first chunk is header bytes — skip those
            while True:
                data = proc.stdout.read(cfg.frame_bytes)
                if not data:
                    break
                self.wfile.write(data)
                self.wfile.flush()
                if meter is not None and not wav:
                    meter.feed(data)
        except (ConnectionError, TimeoutError):
            pass                                 # the iPad disconnected or vanished — normal
        except Exception as exc:
            try:
                self._json(500, {"ok": False, "error": str(exc)})
            except Exception:
                pass
        finally:
            if proc is not None:
                _kill(proc)
            self.capture_lock.release()
            if meter is not None:
                meter.client_done()             # idle metering may resume


def make_server(cfg: Config) -> ThreadingHTTPServer:
    handler = type("_BoundHandler", (_Handler,),
                   {"config": cfg, "capture_lock": threading.Lock()})
    return ThreadingHTTPServer((cfg.bind_host, cfg.port), handler)


def _shutdown_async(srv):
    """Stop the server without blocking the caller. Signal handlers run on the main thread —
    the one inside serve_forever() — and a synchronous srv.shutdown() there deadlocks (it
    waits on an event only serve_forever can set), so hand the call to a throwaway thread."""
    threading.Thread(target=srv.shutdown, daemon=True).start()


def serve(cfg: Config):
    srv = make_server(cfg)
    meter = None
    if cfg.led_meter:
        meter = LedMeter(cfg, srv.RequestHandlerClass.capture_lock)
        srv.RequestHandlerClass.led_meter = meter
    signal.signal(signal.SIGTERM, lambda *_: _shutdown_async(srv))
    signal.signal(signal.SIGINT, lambda *_: _shutdown_async(srv))
    device = capture.resolve_device(cfg.device)
    print("commsight-cockpit-audio v%s on %s:%d  device=%s (%s)  %dHz x%d %s"
          % (__version__, cfg.bind_host, cfg.port, device, cfg.device, cfg.rate, cfg.channels, cfg.fmt),
          flush=True)
    if not capture.device_present(device):
        print("WARNING: capture device %s not found — check the USB adapter / AUDIO_DEVICE "
              "(arecord -l)." % device, flush=True)
    if meter is not None:
        meter.start()
    try:
        srv.serve_forever()
    finally:
        if meter is not None:
            meter.stop()                        # kill idle arecord, restore LED triggers
        srv.server_close()
