"""Drive the Pi's onboard LEDs as a cockpit-audio input meter.

The bench problem this solves: audio is wired into the USB adapter's mic-in, but a headless Pi
gives no sign it hears anything. With the meter on:

  GREEN (ACT) flickers ~6 Hz while the input level is above LED_THRESHOLD_DBFS — "I hear audio".
  RED (PWR) lights for a beat when a peak crosses LED_CLIP_DBFS — "too hot, turn it down".

Level sources, in priority order:
  - While the iPad streams /audio.raw, the server feeds us the same PCM it serves (zero cost).
  - While idle, we run our own `arecord` on the capture device so the LEDs work with no client
    attached. The USB input is single-capture, so the idle capture YIELDS the device the moment
    a client asks: the server calls `yield_now()`, we kill our arecord and release the shared
    lock within one ~20 ms frame.

LEDs live under /sys/class/leds — ACT (a.k.a. led0, green) and PWR (a.k.a. led1, red) on a
Pi 3/4. Writing them needs root (the service already runs as root). On a box without them
(dev laptop) or without write access, the meter disables itself and the audio path is
completely unaffected. Original LED triggers (mmc0 activity, power-on) are restored on stop.
"""
import array
import math
import os
import subprocess
import threading
import time

_SILENCE_DBFS = -120.0            # reported for an all-zero chunk (log of 0 is undefined)
_FLICKER_HALF_PERIOD = 0.08       # green toggles every 80 ms while audio present (~6 Hz flicker)
_QUIET_HOLD = 0.3                 # seconds below threshold before green goes dark
_CLIP_HOLD = 0.25                 # seconds red stays lit after a clipped peak
_IDLE_RETRY = 0.5                 # seconds between idle-capture attempts (device busy/absent)


def levels_dbfs(pcm: bytes):
    """(rms_dbfs, peak_dbfs) of little-endian S16 PCM. Assumes a little-endian host (the Pi and
    every dev box we use are). Cheap: ~320 samples per 20 ms frame."""
    if len(pcm) < 2:
        return (_SILENCE_DBFS, _SILENCE_DBFS)
    samples = array.array("h")
    samples.frombytes(pcm[: len(pcm) - (len(pcm) % 2)])
    peak = 0
    acc = 0
    for s in samples:
        a = -s if s < 0 else s
        if a > peak:
            peak = a
        acc += s * s
    if peak == 0:
        return (_SILENCE_DBFS, _SILENCE_DBFS)
    rms = math.sqrt(acc / len(samples))
    to_dbfs = lambda v: max(_SILENCE_DBFS, 20.0 * math.log10(v / 32768.0)) if v > 0 else _SILENCE_DBFS
    return (to_dbfs(rms), to_dbfs(peak))


class Led:
    """One sysfs LED: saves its trigger, takes manual control, restores on exit."""

    def __init__(self, base: str, names):
        self.path = None
        self._saved_trigger = None
        self._max = "1"
        self._lit = None                      # last written state, to skip redundant writes
        for name in names:
            p = os.path.join(base, name)
            if os.path.isdir(p):
                self.path = p
                break

    @property
    def available(self) -> bool:
        return self.path is not None

    def _write(self, leaf, value) -> bool:
        try:
            with open(os.path.join(self.path, leaf), "w") as f:
                f.write(value)
            return True
        except OSError:
            return False

    def take_control(self) -> bool:
        """Remember the active trigger (the [bracketed] word), then detach it. False = this LED
        can't be driven (not root / kernel says no) — caller should drop it."""
        if not self.available:
            return False
        try:
            with open(os.path.join(self.path, "trigger")) as f:
                for word in f.read().split():
                    if word.startswith("[") and word.endswith("]"):
                        self._saved_trigger = word[1:-1]
            with open(os.path.join(self.path, "max_brightness")) as f:
                self._max = f.read().strip() or "1"
        except OSError:
            return False
        return self._write("trigger", "none")

    def set(self, lit: bool):
        if self.path is None or lit == self._lit:
            return
        if self._write("brightness", self._max if lit else "0"):
            self._lit = lit

    def restore(self):
        if self.path is None:
            return
        self._write("brightness", "0")
        if self._saved_trigger:
            self._write("trigger", self._saved_trigger)


class LedMeter:
    """Audio-level → LED driver with an idle-capture loop.

    Shares `capture_lock` with the HTTP server. While a client streams, the server owns the lock
    and calls `feed()` per chunk. While idle, our thread owns the lock and runs arecord; the
    server calls `yield_now()` + acquires with a short timeout to take the device over.
    """

    def __init__(self, cfg, capture_lock: threading.Lock, leds_base: str = "/sys/class/leds",
                 capture_cmd=None):
        self.cfg = cfg
        self.lock = capture_lock
        self.green = Led(leds_base, ("ACT", "led0"))
        self.red = Led(leds_base, ("PWR", "led1"))
        self.client_active = threading.Event()   # a real client wants / holds the device
        self.holding = False                     # OUR idle capture currently holds the lock
        self.enabled = False
        self._capture_cmd = capture_cmd          # test seam; None → arecord via capture module
        self._stop = threading.Event()
        self._thread = None
        self._proc = None
        # flicker/hold state (guarded by the GIL only — single writer at a time by design)
        self._green_lit = False
        self._last_toggle = 0.0
        self._last_loud = 0.0
        self._clip_until = 0.0
        self.last_rms = _SILENCE_DBFS
        self.last_peak = _SILENCE_DBFS
        self.last_level_at = 0.0

    # -- lifecycle -------------------------------------------------------------------------

    def start(self):
        ok_green = self.green.take_control()
        ok_red = self.red.take_control()
        if not ok_green:
            self.green.path = None
        if not ok_red:
            self.red.path = None
        self.enabled = ok_green or ok_red
        if not self.enabled:
            print("led-meter: no controllable LEDs under sysfs — meter off "
                  "(normal on non-Pi dev boxes)", flush=True)
            return
        print("led-meter: on  green=%s red=%s  threshold=%.0f dBFS clip=%.0f dBFS"
              % (self.green.path or "-", self.red.path or "-",
                 self.cfg.led_threshold_dbfs, self.cfg.led_clip_dbfs), flush=True)
        self._thread = threading.Thread(target=self._idle_loop, name="led-idle-capture",
                                        daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self.client_active.set()                 # unblock the idle loop immediately
        if self._thread is not None:
            self._thread.join(timeout=3)
        self._kill_proc()
        self.green.restore()
        self.red.restore()

    def yield_now(self):
        """Server-side: a client wants the device. Returns once signalled (the idle loop kills
        its arecord + releases the lock within about a frame)."""
        self.client_active.set()

    def client_done(self):
        """Server-side: the client stream ended — idle metering may resume."""
        self.client_active.clear()

    # -- level → LEDs ----------------------------------------------------------------------

    def feed(self, pcm: bytes):
        """Update the LEDs from one PCM chunk (called by the server's stream loop or by our own
        idle capture). Safe no-op when the meter is disabled."""
        if not self.enabled:
            return
        rms, peak = levels_dbfs(pcm)
        now = time.monotonic()
        self.last_rms, self.last_peak, self.last_level_at = rms, peak, now
        if rms >= self.cfg.led_threshold_dbfs:
            self._last_loud = now
            if now - self._last_toggle >= _FLICKER_HALF_PERIOD:
                self._green_lit = not self._green_lit
                self._last_toggle = now
        elif now - self._last_loud > _QUIET_HOLD:
            self._green_lit = False
        self.green.set(self._green_lit)
        if peak >= self.cfg.led_clip_dbfs:
            self._clip_until = now + _CLIP_HOLD
        self.red.set(now < self._clip_until)

    def status(self):
        """For /health."""
        fresh = (time.monotonic() - self.last_level_at) < 2.0 if self.last_level_at else False
        return {
            "enabled": self.enabled,
            "idle_capture": self.holding,
            "rms_dbfs": round(self.last_rms, 1) if fresh else None,
            "peak_dbfs": round(self.last_peak, 1) if fresh else None,
        }

    # -- idle capture ----------------------------------------------------------------------

    def _build_cmd(self):
        if self._capture_cmd is not None:
            return list(self._capture_cmd)
        from . import capture                    # late import keeps this module test-light
        if not capture.have_arecord():
            return None
        device = capture.resolve_device(self.cfg.device)
        return capture.arecord_command(device, self.cfg.rate, self.cfg.channels,
                                       self.cfg.fmt, wav=False)

    def _kill_proc(self):
        proc, self._proc = self._proc, None
        if proc is None:
            return
        try:
            proc.kill()
            proc.wait(timeout=1)
        except Exception:
            pass
        try:
            proc.stdout.close()
        except Exception:
            pass

    def _idle_loop(self):
        frame = self.cfg.frame_bytes
        while not self._stop.is_set():
            if self.client_active.is_set():
                # A client owns (or is taking) the device. The server's feed() keeps the LEDs
                # honest while it streams.
                time.sleep(0.1)
                continue
            if not self.lock.acquire(blocking=False):
                time.sleep(0.1)
                continue
            self.holding = True
            capture_died = False
            try:
                cmd = self._build_cmd()
                if cmd is None:
                    capture_died = True          # no arecord — retry slowly, outside the lock
                else:
                    try:
                        self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                                      stderr=subprocess.DEVNULL, bufsize=0)
                    except OSError:
                        self._proc = None
                        capture_died = True
                    if self._proc is not None:
                        while not self._stop.is_set() and not self.client_active.is_set():
                            data = self._proc.stdout.read(frame)
                            if not data:         # device unplugged / arecord died
                                self.green.set(False)
                                capture_died = True
                                break
                            self.feed(data)
                        self._kill_proc()
            finally:
                self.holding = False
                self.lock.release()
            # Back off OUTSIDE the lock: a waiting client gets the device immediately, and a
            # missing/unplugged adapter doesn't turn this loop into a spawn storm.
            time.sleep(_IDLE_RETRY if capture_died else 0.05)
