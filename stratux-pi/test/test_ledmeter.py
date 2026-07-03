"""Unit tests for the LED input meter — pure logic, no Pi hardware needed.

Run from stratux-pi/:  python3 -m unittest discover -s test -v
The sysfs LED tree is faked with a temp directory; the idle-capture arecord is faked with a
tiny Python child process that emits PCM-shaped bytes at a realistic pace.
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from commsight_cockpit_audio import ledmeter                     # noqa: E402
from commsight_cockpit_audio.config import Config, from_env      # noqa: E402
from commsight_cockpit_audio.ledmeter import Led, LedMeter, levels_dbfs  # noqa: E402


def sine_pcm(amplitude, samples=320, freq=1000, rate=16000):
    """S16LE mono sine; amplitude in [0,1] of full scale."""
    peak = int(amplitude * 32767)
    return b"".join(
        struct.pack("<h", int(peak * math.sin(2 * math.pi * freq * i / rate)))
        for i in range(samples))


class LevelsTests(unittest.TestCase):
    def test_silence_is_floor(self):
        rms, peak = levels_dbfs(b"\x00" * 640)
        self.assertEqual(rms, -120.0)
        self.assertEqual(peak, -120.0)

    def test_empty_and_odd_input_do_not_crash(self):
        self.assertEqual(levels_dbfs(b""), (-120.0, -120.0))
        self.assertEqual(levels_dbfs(b"\x00"), (-120.0, -120.0))

    def test_full_scale_square_is_zero_dbfs(self):
        pcm = struct.pack("<h", 32767) * 320
        rms, peak = levels_dbfs(pcm)
        self.assertAlmostEqual(peak, 0.0, delta=0.01)
        self.assertAlmostEqual(rms, 0.0, delta=0.01)

    def test_half_scale_sine_rms(self):
        # 0.5 amplitude sine: peak = -6.02 dBFS, RMS = peak - 3.01 = -9.03 dBFS
        rms, peak = levels_dbfs(sine_pcm(0.5, samples=1600))
        self.assertAlmostEqual(peak, -6.02, delta=0.15)
        self.assertAlmostEqual(rms, -9.03, delta=0.15)


class FakeSysfs:
    """Builds /sys/class/leds-shaped LED dirs in a temp folder."""

    def __init__(self):
        self.base = tempfile.mkdtemp(prefix="fakeleds-")

    def add(self, name, trigger="none mmc0 [mmc0] heartbeat", max_brightness="255"):
        d = os.path.join(self.base, name)
        os.makedirs(d)
        with open(os.path.join(d, "trigger"), "w") as f:
            f.write(trigger)
        with open(os.path.join(d, "max_brightness"), "w") as f:
            f.write(max_brightness)
        with open(os.path.join(d, "brightness"), "w") as f:
            f.write("0")
        return d

    def read(self, name, leaf):
        with open(os.path.join(self.base, name, leaf)) as f:
            return f.read().strip()

    def cleanup(self):
        shutil.rmtree(self.base, ignore_errors=True)


class LedTests(unittest.TestCase):
    def setUp(self):
        self.fs = FakeSysfs()
        self.addCleanup(self.fs.cleanup)

    def test_resolves_first_existing_name(self):
        self.fs.add("led0")
        led = Led(self.fs.base, ("ACT", "led0"))
        self.assertTrue(led.available)
        self.assertTrue(led.path.endswith("led0"))

    def test_take_control_saves_trigger_and_detaches(self):
        self.fs.add("ACT")
        led = Led(self.fs.base, ("ACT", "led0"))
        self.assertTrue(led.take_control())
        self.assertEqual(led._saved_trigger, "mmc0")
        self.assertEqual(self.fs.read("ACT", "trigger"), "none")

    def test_set_writes_max_brightness_and_dedupes(self):
        self.fs.add("PWR", max_brightness="1")
        led = Led(self.fs.base, ("PWR", "led1"))
        led.take_control()
        led.set(True)
        self.assertEqual(self.fs.read("PWR", "brightness"), "1")
        led.set(False)
        self.assertEqual(self.fs.read("PWR", "brightness"), "0")

    def test_restore_puts_trigger_back(self):
        self.fs.add("ACT")
        led = Led(self.fs.base, ("ACT", "led0"))
        led.take_control()
        led.set(True)
        led.restore()
        self.assertEqual(self.fs.read("ACT", "trigger"), "mmc0")
        self.assertEqual(self.fs.read("ACT", "brightness"), "0")

    def test_missing_led_is_harmless(self):
        led = Led(self.fs.base, ("ACT", "led0"))
        self.assertFalse(led.available)
        self.assertFalse(led.take_control())
        led.set(True)      # no crash
        led.restore()      # no crash


class MeterLogicTests(unittest.TestCase):
    """feed() → LED behavior, with time controlled via monkeypatched monotonic."""

    def setUp(self):
        self.fs = FakeSysfs()
        self.addCleanup(self.fs.cleanup)
        self.fs.add("ACT")
        self.fs.add("PWR")
        self.cfg = Config()
        self.meter = LedMeter(self.cfg, threading.Lock(), leds_base=self.fs.base)
        self.meter.green.take_control()
        self.meter.red.take_control()
        self.meter.enabled = True
        self.now = 100.0
        self._orig_monotonic = ledmeter.time.monotonic
        ledmeter.time.monotonic = lambda: self.now
        self.addCleanup(self._restore_time)

    def _restore_time(self):
        ledmeter.time.monotonic = self._orig_monotonic

    def green_lit(self):
        return self.fs.read("ACT", "brightness") != "0"

    def red_lit(self):
        return self.fs.read("PWR", "brightness") != "0"

    def test_loud_audio_flickers_green(self):
        loud = sine_pcm(0.3)
        states = set()
        for _ in range(20):                      # 20 frames x 100 ms of fake time = 2 s
            self.meter.feed(loud)
            states.add(self.green_lit())
            self.now += 0.1
        self.assertEqual(states, {True, False}, "green should toggle (flicker), not sit static")

    def test_quiet_audio_keeps_green_dark(self):
        quiet = sine_pcm(0.001)                  # ~ -60 dBFS, below the -50 threshold
        for _ in range(10):
            self.meter.feed(quiet)
            self.now += 0.1
        self.assertFalse(self.green_lit())

    def test_green_goes_dark_after_quiet_hold(self):
        self.meter.feed(sine_pcm(0.3))
        self.now += 0.5                          # > _QUIET_HOLD
        self.meter.feed(sine_pcm(0.001))
        self.assertFalse(self.green_lit())

    def test_clipping_lights_red_then_clears(self):
        hot = sine_pcm(0.99)                     # peak ~ -0.1 dBFS > -3 clip threshold
        self.meter.feed(hot)
        self.assertTrue(self.red_lit())
        self.now += 1.0                          # > _CLIP_HOLD
        self.meter.feed(sine_pcm(0.001))
        self.assertFalse(self.red_lit())

    def test_disabled_meter_feed_is_noop(self):
        m = LedMeter(self.cfg, threading.Lock(), leds_base=tempfile.mkdtemp())
        m.start()                                # no LEDs → disables itself
        self.assertFalse(m.enabled)
        m.feed(sine_pcm(0.5))                    # no crash
        m.stop()

    def test_status_reports_levels(self):
        self.meter.feed(sine_pcm(0.5))
        st = self.meter.status()
        self.assertTrue(st["enabled"])
        self.assertAlmostEqual(st["peak_dbfs"], -6.0, delta=0.3)


class IdleCaptureArbitrationTests(unittest.TestCase):
    """The idle capture must hold the shared lock while metering and yield it to a client fast."""

    FAKE_ARECORD = [sys.executable, "-u", "-c",
                    "import sys,time\n"
                    "b = b'\\x11\\x22' * 320\n"
                    "for _ in range(1000):\n"
                    "    sys.stdout.buffer.write(b); sys.stdout.buffer.flush(); time.sleep(0.02)\n"]

    def setUp(self):
        self.fs = FakeSysfs()
        self.addCleanup(self.fs.cleanup)
        self.fs.add("ACT")
        self.lock = threading.Lock()
        self.meter = LedMeter(Config(), self.lock, leds_base=self.fs.base,
                              capture_cmd=self.FAKE_ARECORD)

    def tearDown(self):
        self.meter.stop()

    def wait_for(self, predicate, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.02)
        return False

    def test_idle_loop_meters_and_yields_to_client(self):
        self.meter.start()
        self.assertTrue(self.meter.enabled)
        # Idle loop should grab the lock and start "capturing" from the fake arecord.
        self.assertTrue(self.wait_for(lambda: self.meter.holding), "idle capture never started")
        self.assertTrue(self.wait_for(lambda: self.meter.last_level_at > 0),
                        "idle capture produced no levels")
        # A client arrives: yield_now + a bounded acquire must succeed quickly.
        self.meter.yield_now()
        t0 = time.monotonic()
        got = self.lock.acquire(timeout=2.0)
        took = time.monotonic() - t0
        self.assertTrue(got, "client could not take the device from the idle meter")
        self.assertLess(took, 1.5, "idle meter took too long to yield (%.2fs)" % took)
        try:
            self.assertFalse(self.meter.holding)
        finally:
            self.lock.release()
        # Client done → idle metering resumes.
        self.meter.client_done()
        self.assertTrue(self.wait_for(lambda: self.meter.holding),
                        "idle capture did not resume after the client left")


class ConfigTests(unittest.TestCase):
    def test_defaults(self):
        cfg = from_env({})
        self.assertTrue(cfg.led_meter)
        self.assertEqual(cfg.led_threshold_dbfs, -50.0)
        self.assertEqual(cfg.led_clip_dbfs, -3.0)

    def test_led_meter_off(self):
        for raw in ("off", "0", "false", "no", "OFF"):
            self.assertFalse(from_env({"LED_METER": raw}).led_meter, raw)

    def test_led_meter_on_variants(self):
        for raw in ("on", "1", "true", "yes"):
            self.assertTrue(from_env({"LED_METER": raw}).led_meter, raw)

    def test_threshold_parsing_and_garbage(self):
        self.assertEqual(from_env({"LED_THRESHOLD_DBFS": "-40"}).led_threshold_dbfs, -40.0)
        self.assertEqual(from_env({"LED_THRESHOLD_DBFS": "loud"}).led_threshold_dbfs, -50.0)


if __name__ == "__main__":
    unittest.main()
