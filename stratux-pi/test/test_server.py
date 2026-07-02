#!/usr/bin/env python3
"""Unit/integration tests for the cockpit-audio sidecar (stdlib only, no audio hardware).

Runs the real server on an ephemeral port with `arecord` faked by a Python child process, and
covers the failure modes that matter in the cockpit:

  - a client that vanishes without FIN/RST (iPad off the WiFi) frees the single-stream lock
    within seconds instead of ~15 min of kernel retransmit
  - arecord stderr spam ("overrun!!!") cannot fill the 64 KiB pipe and freeze capture
  - SIGTERM handling never calls srv.shutdown() synchronously (deadlock with serve_forever)
  - arecord startup failure still reports stderr detail in the 503
  - `arecord -l` parsing runs under LC_ALL=C; _kill() reaps the child

Run:  python3 -m unittest discover -s stratux-pi/test -p "test_*.py"
"""
import http.client
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from commsight_cockpit_audio import capture, server          # noqa: E402
from commsight_cockpit_audio.config import Config            # noqa: E402

# Fake arecord: one first frame, then ~400 KiB of stderr spam (>> the 64 KiB pipe), then keep
# streaming. Without the stderr drain the child blocks on stderr and stdout goes silent.
FAKE_SPAM = (
    "import sys\n"
    "sys.stdout.buffer.write(b'\\x00' * 640); sys.stdout.buffer.flush()\n"
    "spam = b'overrun!!!\\n' * 100\n"
    "for _ in range(400): sys.stderr.buffer.write(spam)\n"
    "sys.stderr.buffer.flush()\n"
    "import time\n"
    "while True:\n"
    "    sys.stdout.buffer.write(b'\\x00' * 640); sys.stdout.buffer.flush()\n"
    "    time.sleep(0.002)\n"
)

# Fake arecord: produce audio flat-out, so a client that stops reading fills the socket buffers
# fast and the server's send blocks.
FAKE_FAST = (
    "import sys\n"
    "while True:\n"
    "    sys.stdout.buffer.write(b'\\x00' * 65536)\n"
)

# Fake arecord: die at startup with a diagnostic on stderr, like a missing/busy device.
FAKE_FAIL = (
    "import sys\n"
    "sys.stderr.write('arecord: main:830: audio open error: No such device')\n"
    "sys.exit(1)\n"
)


class ServerTestCase(unittest.TestCase):
    """Real ThreadingHTTPServer on 127.0.0.1:<ephemeral>, capture module monkeypatched."""

    def setUp(self):
        self.enterContext(mock.patch.object(capture, "have_arecord", lambda: True))
        self.enterContext(mock.patch.object(capture, "resolve_device", lambda configured: "fake"))
        self.fake_script = FAKE_FAST
        self.enterContext(mock.patch.object(
            capture, "arecord_command",
            lambda device, rate, channels, fmt, wav: [sys.executable, "-u", "-c", self.fake_script]))
        self.srv = server.make_server(Config(bind_host="127.0.0.1", port=0))
        self.srv.RequestHandlerClass.timeout = 1     # keep the vanished-client test fast
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.thread.join(timeout=5)
        self.srv.server_close()

    def _get(self, path, timeout=5):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        conn.request("GET", path)
        return conn, conn.getresponse()

    def _health(self):
        conn, resp = self._get("/health")
        try:
            return json.loads(resp.read())
        finally:
            conn.close()

    def test_handler_timeout_configured(self):
        # The class attribute is what unwedges a send stuck in kernel retransmit.
        self.assertIsInstance(server._Handler.timeout, (int, float))
        self.assertTrue(0 < server._Handler.timeout <= 15)

    def test_stderr_spam_does_not_stall_stream(self):
        self.fake_script = FAKE_SPAM
        conn, resp = self._get("/audio.raw", timeout=10)
        try:
            self.assertEqual(resp.status, 200)
            got, deadline = 0, time.monotonic() + 10
            while got < 65536 and time.monotonic() < deadline:
                chunk = resp.read(4096)
                if not chunk:
                    break
                got += len(chunk)
            self.assertGreaterEqual(got, 65536, "stream stalled — stderr pipe filled up?")
        finally:
            conn.close()

    def test_vanished_client_frees_lock(self):
        # Client A: raw socket with a tiny receive buffer; read the start of the stream, then
        # stop reading entirely (like an iPad gone from the WiFi — no FIN, no RST).
        a = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        a.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
        a.settimeout(5)
        try:
            a.connect(("127.0.0.1", self.port))
            a.sendall(b"GET /audio.raw HTTP/1.1\r\nHost: x\r\n\r\n")
            head = a.recv(4096)
            self.assertIn(b"200", head.split(b"\r\n", 1)[0])

            # While A streams, a second client must get 409 (single capture slot).
            conn, resp = self._get("/audio.raw")
            self.assertEqual(resp.status, 409)
            resp.read()
            conn.close()

            # A stops reading; the server's send blocks, hits the socket timeout, and the
            # cleanup path releases the lock. Target: free within seconds, not minutes.
            start = time.monotonic()
            deadline = start + 8
            while time.monotonic() < deadline:
                if not self._health()["streaming"]:
                    break
                time.sleep(0.2)
            freed_after = time.monotonic() - start
            self.assertFalse(self._health()["streaming"],
                             "lock still held %.1fs after client vanished" % freed_after)

            # And a reconnect now succeeds instead of 409.
            conn, resp = self._get("/audio.raw")
            try:
                self.assertEqual(resp.status, 200)
                self.assertTrue(resp.read(640))
            finally:
                conn.close()
        finally:
            a.close()

    def test_capture_failure_returns_503_with_stderr_detail(self):
        # The startup-failure path must still read stderr (the drain starts only after the
        # first frame succeeds).
        self.fake_script = FAKE_FAIL
        conn, resp = self._get("/audio.raw")
        try:
            self.assertEqual(resp.status, 503)
            body = json.loads(resp.read())
            self.assertEqual(body["error"], "capture_failed")
            self.assertIn("audio open error", body["detail"])
        finally:
            conn.close()

    def test_shutdown_async_stops_real_server(self):
        # tearDown would also stop it, but this asserts the helper alone unblocks serve_forever.
        server._shutdown_async(self.srv)
        self.thread.join(timeout=5)
        self.assertFalse(self.thread.is_alive(), "serve_forever did not exit after shutdown")


class ShutdownHandlerTest(unittest.TestCase):
    def test_shutdown_async_never_blocks_the_caller(self):
        # Signal handlers run on the thread inside serve_forever(); if _shutdown_async called
        # srv.shutdown() synchronously this would deadlock (systemctl stop → 90 s → SIGKILL).
        class BlockingSrv:
            def __init__(self):
                self.called = threading.Event()

            def shutdown(self):
                self.called.set()
                time.sleep(60)                   # emulate shutdown() waiting on serve_forever

        srv = BlockingSrv()
        start = time.monotonic()
        server._shutdown_async(srv)
        self.assertLess(time.monotonic() - start, 0.5, "shutdown handler blocked the caller")
        self.assertTrue(srv.called.wait(2), "shutdown() was never invoked")


class CaptureTest(unittest.TestCase):
    def test_list_capture_devices_uses_c_locale_and_parses(self):
        sample = ("**** List of CAPTURE Hardware Devices ****\n"
                  "card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]\n")
        seen = {}

        def fake_run(cmd, **kw):
            seen["cmd"], seen["env"] = cmd, kw.get("env")
            return types.SimpleNamespace(stdout=sample)

        with mock.patch.object(capture.subprocess, "run", fake_run):
            devices = capture.list_capture_devices()
        self.assertEqual(seen["cmd"], ["arecord", "-l"])
        self.assertIsNotNone(seen["env"], "arecord -l must run with an explicit env")
        self.assertEqual(seen["env"].get("LC_ALL"), "C")
        self.assertEqual(devices, [{"card": 1, "device": 0, "id": "Device",
                                    "name": "USB Audio Device", "alsa": "plughw:1,0"}])


class KillTest(unittest.TestCase):
    def test_kill_reaps_a_live_child(self):
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        server._kill(proc)
        self.assertIsNotNone(proc.returncode, "child not reaped — zombie")

    def test_kill_reaps_on_the_kill_path(self):
        proc = mock.Mock()
        proc.terminate.side_effect = OSError("terminate failed")
        server._kill(proc)
        proc.kill.assert_called_once()
        proc.wait.assert_called_once_with(timeout=1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
