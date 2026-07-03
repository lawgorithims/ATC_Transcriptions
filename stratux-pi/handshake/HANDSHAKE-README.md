# CommSight Pi <-> iPad Audio Handshake Tests

Quick link-health checks for the cockpit-audio sidecar on the Stratux Pi and
the path to the CommSight iPad app. These verify the *handshake* -- the
protocol contract between the Pi's port-8090 audio server and the app -- in
under a minute. They do NOT replace the sustained-load soak test
(`ios/Tools/stratux_validate.sh`), which exercises long-running streams.

Files:

| File | Runs on | Needs |
|---|---|---|
| `pi_selftest.sh` | the Raspberry Pi (SSH in) | bash + python3 (stdlib only) |
| `handshake_test.py` | your laptop, joined to the `stratux` WiFi | python3 (3.9+, stdlib only) |

Recommended order: `pi_selftest.sh` first (proves the Pi side alone), then
`handshake_test.py` (proves the WiFi link end to end), then the iPad checks.

---

## 1. On the Pi: `pi_selftest.sh`

SSH in from a laptop on the stratux WiFi:

```
ssh pi@192.168.10.1
```

If this folder is on the SD card's boot partition it will be at
`/boot/firmware/stratux-pi/...` on the Pi. The boot partition is FAT32, where
the executable bit cannot be trusted -- so always invoke via bash, never
`./pi_selftest.sh`:

```
bash pi_selftest.sh
```

Good output looks like:

```
== CommSight cockpit-audio Pi self-test ==

NOTE  using audio port 8090 (env AUDIO_PORT / /etc/default/cockpit-audio / default)
NOTE  root filesystem is an overlay (RAM upper layer): ...
PASS  python3 present: Python 3.11.2
PASS  arecord present: /usr/bin/arecord
PASS  capture device(s) found:
          card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
PASS  cockpit-audio service is active (boot-enable state: enabled)
PASS  GET /health on 127.0.0.1:8090 -> ok=true arecord=true device_present=true resolved_device=plughw:1,0 streaming=false
PASS  /audio.raw streamed 2 s -> 64000 bytes in 2.0 s = 32000 B/s (expect ~32000)

self-test: 6 passed, 0 failed, 0 warnings
PI SIDE LOOKS GOOD -- now run handshake_test.py from a laptop on the stratux WiFi.
```

Exit code is 0 only if nothing FAILed. WARN lines do not fail the run --
read them anyway; in particular:

- The overlay NOTE means the Stratux image's root filesystem is a RAM
  overlay: installs and alsamixer gain settings made now will VANISH at the
  next power cycle. To make changes permanent: `sudo overlayctl disable &&
  sudo reboot`, do the install / set the gain / `sudo alsactl store`, then
  `sudo overlayctl enable && sudo reboot`.
- "another client is streaming right now" means the iPad (or a laptop test)
  currently holds the single-client stream -- that itself proves audio is
  flowing, but disconnect it and rerun for a full local check.

## 2. On the laptop: `handshake_test.py`

Join the `stratux` WiFi network, quit CommSight on the iPad (the sidecar
allows exactly ONE stream client, and an attached iPad would make the stream
tests fail with 409), then:

```
python3 handshake_test.py
```

Options:

```
--host 192.168.10.1     Pi address (default shown)
--audio-port 8090       sidecar port (default shown)
--seconds 10            how long T3 samples the stream (default 10)
--expect-tone 1000      tone-loopback wire check, see section 3
--with-stratux          also check Stratux's own /getSituation on port 80
```

Good output looks like:

```
target: audio http://192.168.10.1:8090  stratux http://192.168.10.1/

T1  PASS tcp-reach          TCP connect to 192.168.10.1:8090 in 9 ms
T2  PASS health             service=commsight-cockpit-audio resolved_device=plughw:1,0 device_present=True streaming=False
T3  PASS audio-stream       10.0 s, 32013 B/s, 165440 samples, RMS -28.4 dBFS, clip 0.00%, range [-9124, 9377]
T4  PASS single-client-409  second concurrent client correctly rejected: 409 audio_stream_already_in_use
T5  PASS wav-header         PCM 16000 Hz, 1 ch, 16-bit, 32000 B/s (Content-Type: audio/wav)
T6  PASS reconnect          bytes flowing again 412 ms after the drop (attempt 1)
T7  SKIP tone-loopback      skipped: no --expect-tone given
T8  SKIP stratux-situation  skipped: run with --with-stratux to check

...
result: 6 passed, 0 failed, 2 skipped
HANDSHAKE OK -- the Pi->iPad audio link contract holds.
```

Exit code 0 only if every non-skipped test passed. What the tests mean:

- **T1** fails fast (3 s) if the Pi is unreachable -- almost always "you are
  not on the stratux WiFi" or the sidecar service is not running.
- **T2** checks `/health`: `device_present=false` means the USB audio adapter
  is missing/unrecognized.
- **T3** measures the byte rate (must be 32000 B/s +/- 15% -- the app decodes
  exactly 2 half-second chunks per second from this) and sanity-checks the
  PCM: constant/all-zero samples mean a dead input (adapter not wired to the
  audio source), heavy clipping (>= 30% of samples) means the capture gain is
  too hot -- fix with alsamixer on the Pi (and `sudo alsactl store` inside an
  overlay-disabled window or the setting is lost on reboot). RMS dBFS is
  reported so you can log a baseline; cockpit audio typically sits around
  -35..-15 dBFS with squelched-silence gaps.
- **T4** confirms a second concurrent client gets `409
  audio_stream_already_in_use` (the adapter is a single input; two arecords
  would corrupt both streams).
- **T5** confirms `/audio.wav` (the ffplay/browser debug endpoint) advertises
  16 kHz mono 16-bit PCM.
- **T6** drops the stream and reconnects immediately -- the iPad does exactly
  this with a 1.5 s backoff after every WiFi hiccup. Bytes must flow again
  within 5 s. If this fails with "still 409", the sidecar did not release the
  capture lock on client disconnect; note that an *unclean* client vanish
  (WiFi drop with no TCP reset) is known to hold the lock much longer -- this
  test only covers the clean-close path.

If T3/T4/T6 fail with `409 audio_stream_already_in_use` at the start, some
other client (usually the iPad) is holding the stream: quit CommSight and
rerun.

## 3. Tone-loopback: true end-to-end wire check

T3 proves bytes flow; it cannot prove the *right audio* is on the wire. For
that, inject a known tone at the analog input and detect it in the received
PCM:

1. On a phone (or any audio player), play a continuous **1 kHz sine tone** at
   moderate volume. Any signal-generator app works, or a "1000 Hz test tone"
   video/file.
2. Feed the phone's headphone output into the **mic/line-in of the Pi's USB
   audio adapter** with a 3.5 mm male-male cable (the same jack the aircraft
   audio panel normally feeds).
3. On the laptop:

   ```
   python3 handshake_test.py --expect-tone 1000
   ```

T7 then runs a Goertzel detector on the PCM captured during T3, taking the
strongest bin within +/-2 Hz of the target (so a few hundred ppm of clock
skew between the tone source and the adapter's ADC cannot fail a good wire),
and passes only if that bin dominates (>= 4% of total signal energy and
>= 5x above off-tone probe frequencies). Good output:

```
T7  PASS tone-loopback      tone detected: 1000 Hz (best bin 1000.00 Hz, searched +/-2.0 Hz) holds 71.3% of signal energy, 2841x above off-tone probes (620/1410/1730 Hz)
```

If T7 fails while T3 passes, the digital path is fine but the analog input is
not: check the cable, the adapter's mic-vs-headphone jack, the phone volume,
and the capture gain (alsamixer). Any tone frequency up to ~7 kHz works;
1 kHz is conventional. Avoid 600 Hz if you are testing against
`stratux-pi/test/fake_stratux.py`, which emits its own 600 Hz tone (actually,
that makes `--expect-tone 600` a neat self-test of the detector).

## 4. On the iPad: confirm CommSight sees the link

1. Join the iPad to the `stratux` WiFi network (Settings -> Wi-Fi).
2. Open CommSight. On first use iOS asks for **Local Network** permission --
   Allow it (without it the app cannot reach 192.168.10.1 at all; recheck
   under Settings -> Privacy & Security -> Local Network -> CommSight).
3. In CommSight: **Settings -> Stratux receiver** -> host `192.168.10.1`,
   audio port `8090` (both are the defaults and match the Settings
   placeholders).
4. Select the Stratux/cockpit-audio source and watch the status chip: it
   should show the link as connected and transcription should start when
   audio is present.
5. If the app reports "No cockpit audio at 192.168.10.1:8090 -- check the
   Stratux audio sidecar / port", rerun `handshake_test.py` from the laptop:
   if it passes, the problem is on the iPad side (wrong WiFi, Local Network
   permission denied, or a typo in host/port); if it fails, follow the FAIL
   hints.
6. Note the app is the *single* allowed stream client: while CommSight is
   connected, `handshake_test.py` stream tests and `/audio.wav` in a browser
   will get 409. That is by design.

## 5. Troubleshooting quick reference

| Symptom | Likely cause / fix |
|---|---|
| T1 FAIL, cannot connect | not on the `stratux` WiFi; sidecar not running (`bash pi_selftest.sh` on the Pi); wrong port |
| T2 `device_present=false` | USB audio adapter unplugged/unrecognized -- reseat it, check `arecord -l` |
| T3 rate far below 32000 B/s | Pi overloaded or WiFi marginal -- move closer, check for interference |
| T3 dead input (constant PCM) | nothing wired into the adapter input, or capture channel muted in alsamixer |
| T3 heavy clipping | capture gain too hot -- alsamixer, then `sudo alsactl store` (overlay disabled, or it reverts on reboot) |
| 409 on everything | another client (the iPad) holds the stream -- quit CommSight and rerun |
| everything passes on the bench, dead after a power cycle | the install/gain lived in the RAM overlay -- redo it with `sudo overlayctl disable && sudo reboot` first, then re-enable |
