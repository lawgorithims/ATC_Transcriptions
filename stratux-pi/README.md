# stratux-pi — CommSight cockpit-audio gateway

The Raspberry Pi code that turns a [Stratux](https://github.com/stratux/stratux) receiver into a
single cockpit device for **CommSight**: it captures **cockpit audio** from a USB audio adapter and
streams it over the Stratux Wi-Fi to the iPad, where CommSight transcribes it. Aircraft **traffic**
and **GPS** come straight from Stratux's own web API. The result works **in flight with no internet**.

```
headset / intercom audio ─► USB audio adapter ─► [ Raspberry Pi ] ─► this gateway ─► /audio.raw ─┐
                                                       │                                          ├─► iPad: CommSight
Stratux ADS-B + WAAS GPS  ─────────────────────────────┴─► Stratux web API: /traffic, /getSituation┘
```

This gateway runs **beside** Stratux and never touches its ADS-B / GPS / ForeFlight services, so
ForeFlight keeps working unchanged. It is pure Python standard library + ALSA `arecord` — **no pip
dependencies** (important on a Pi that's offline in the air).

## What's in here

| Path | What |
| --- | --- |
| `commsight_cockpit_audio/` | the Python package (HTTP server + ALSA capture) |
| `install.sh` / `uninstall.sh` | one-command install/remove (deps, code, systemd) |
| `cockpit-audio.service` | systemd unit (installed so it runs on boot) |
| `cockpit-audio.env` | config defaults → `/etc/default/cockpit-audio` |
| `bin/detect-audio` | show capture devices + the auto-pick |
| `bin/record-test` | record a few seconds with a live level meter to set gain |
| `Makefile` | `make run` / `devices` / `test` / `install` / `syntax` |

## Prerequisites

- A **working Stratux** on the Pi (flash it from the [Stratux project](https://github.com/stratux/stratux)
  / stratux.me — that's separate from this gateway). Any Raspberry Pi OS works too if you only want
  the audio half.
- A **USB audio adapter** (e.g. UGREEN) with a microphone input, plus a 3.5 mm cable + an inline
  volume control / attenuator. *(A ground-loop isolator on the audio branch kills engine whine.)*

## 1. Wire the audio

```
headset / intercom  →  3.5 mm out  →  inline volume / attenuator  →  USB adapter PINK mic-in  →  USB into the Pi
```

Use the **pink microphone** input, not the green headphone jack. Clean and un-clipped matters more
than loud.

## 2. Get this code onto the Pi

Connect your laptop to the Stratux Wi-Fi, then either clone or copy the `stratux-pi/` folder:

```bash
# Option A — clone on the Pi (if it has internet on the bench):
ssh pi@192.168.10.1
git clone https://github.com/lawgorithims/ATC_Transcriptions.git
cd ATC_Transcriptions/stratux-pi

# Option B — copy just this folder from your laptop:
scp -r stratux-pi pi@192.168.10.1:~/stratux-pi
ssh pi@192.168.10.1
cd ~/stratux-pi
```

## 3. Install

```bash
sudo ./install.sh
```

This installs `alsa-utils`/`python3` if missing, copies the code to `/opt/commsight`, writes
`/etc/default/cockpit-audio`, prints the detected capture devices, and enables + starts the
`cockpit-audio` systemd service (so it comes back on every boot). Re-run it any time to upgrade.

If auto-detect picks the wrong card, edit the device and restart:

```bash
/opt/commsight/detect-audio                 # see the devices + the auto pick
sudo nano /etc/default/cockpit-audio        # set AUDIO_DEVICE=plughw:1,0 (your card,device)
sudo systemctl restart cockpit-audio
```

## 4. Verify (on the ground)

```bash
# Set a clean capture level first (watch the meter; don't let it pin/clip):
/opt/commsight/record-test                  # records /tmp/cockpit_test.wav; aplay it to listen
alsamixer                                   # F6 pick the USB card, F4 capture, adjust gain

# Service health + a live stream check:
curl http://localhost:8090/health           # JSON: resolved_device, device_present, etc.
curl http://192.168.10.1:8090/audio.raw --output cockpit.raw   # from a laptop; Ctrl-C after ~10 s
ffplay -f s16le -ar 16000 -ac 1 cockpit.raw  # should be the cockpit audio
# (or just open http://192.168.10.1:8090/audio.wav in a browser / ffplay)
```

### The Pi's LEDs are a live input meter

While the service runs, the Pi's onboard LEDs show what the capture input hears — no laptop
needed. Play audio into the USB adapter's mic-in and watch the board:

| LED | Meaning |
| --- | --- |
| **Green (ACT) flickering** | audio is arriving at the input — the wiring works |
| **Green dark** | input is silent: wrong jack (use the pink mic-in), dead cable, or volume at zero |
| **Red (PWR) blinking** | the signal is clipping — turn the inline volume / capture gain down |

It works with or without the iPad connected (the meter borrows the mic between client streams
and hands it over the instant CommSight connects). `/health` reports the same numbers as
`led_meter.rms_dbfs` / `peak_dbfs` if you want values instead of blinkenlights. Set
`LED_METER=off` to return the LEDs to their normal duties (SD activity / power).

## 5. Use in CommSight

In the app: **Settings → Stratux receiver** → set the address (`192.168.10.1`) and audio port
(`8090`), then pick **"Stratux receiver"** as the input source and press **Start**. iOS asks once
for permission to find devices on the local network — allow it. The status chip shows the link,
GPS fix, and traffic count; transcripts start as audio arrives.

## Configuration

`/etc/default/cockpit-audio` (restart the service after editing):

| Variable | Default | Notes |
| --- | --- | --- |
| `AUDIO_DEVICE` | `auto` | `auto` finds a USB capture device; or set e.g. `plughw:1,0` |
| `AUDIO_PORT` | `8090` | must match CommSight's Settings → Stratux receiver → Audio port |
| `AUDIO_RATE` | `16000` | CommSight's native rate — leave it |
| `AUDIO_CHANNELS` | `1` | mono — leave it |
| `AUDIO_FORMAT` | `S16_LE` | signed 16-bit LE — leave it |
| `LED_METER` | `on` | drive the Pi's ACT/PWR LEDs as an input level meter; `off` restores normal LED duty |
| `LED_THRESHOLD_DBFS` | `-50` | green flickers while input RMS is above this; raise it if noise false-triggers |
| `LED_CLIP_DBFS` | `-3` | red lights when a peak crosses this |

## HTTP API

Served on `0.0.0.0:<AUDIO_PORT>`:

| Endpoint | Returns |
| --- | --- |
| `GET /health` | JSON status: resolved device, capture device list, whether a stream is active |
| `GET /audio.raw` | raw 16 kHz mono S16LE PCM (what CommSight reads) — **one client at a time** |
| `GET /audio.wav` | the same audio with a streaming WAV header (for `ffplay` / a browser) |

A second simultaneous audio client gets HTTP `409` (the USB input is single-capture). A missing /
busy device returns `503` with the `arecord` error in the body.

## Run without installing (dev / quick demo)

```bash
cd stratux-pi
python3 -m commsight_cockpit_audio --list-devices      # what's available
python3 -m commsight_cockpit_audio --device plughw:1,0 # foreground, Ctrl-C to stop
make syntax                                            # byte-compile sanity check
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `/health` shows `device_present: false` | wrong/absent device — `detect-audio`, set `AUDIO_DEVICE`, replug USB, check `lsusb` |
| Stream silent | wrong jack — use the **pink mic-in**; try `plughw:0,0` vs `plughw:1,0` |
| Distorted / clipped | lower the inline volume + `alsamixer` capture gain; add an attenuator |
| Buzz / whine | add a 3.5 mm ground-loop isolator on the audio branch |
| `409` on `/audio.raw` | another client is already streaming (only one at a time) |
| CommSight can't connect | allow the local-network prompt; confirm `/health` from a laptop; check the port in Settings |
| Doesn't survive reboot | the Stratux image may mount root read-only (overlayfs); disable the overlay, or start manually for the demo |
| ForeFlight stopped | reboot — this gateway is separate from Stratux; if it persists, re-flash the Stratux SD card |

`sudo journalctl -u cockpit-audio -f` tails the gateway's logs.

## Uninstall

```bash
sudo ./uninstall.sh     # removes the service + /opt/commsight; does not touch Stratux
```

## Notes

- **Relationship to Stratux.** This does not include or modify the Stratux software — flash that
  separately. CommSight reads traffic from `ws://<pi>/traffic` and GPS from `http://<pi>/getSituation`
  (Stratux's own web API on port 80), and cockpit audio from this gateway on port 8090. Same host,
  different services.
- **License.** Part of the CommSight / ATC_Transcribe repository; see the repository's license.
  Stratux is a separate project under its own license.
