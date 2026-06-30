# Stratux → CommSight setup

Turn a [Stratux](https://github.com/stratux/stratux) receiver into a single cockpit device that feeds
**CommSight**: live cockpit **audio** (transcribed on the iPad) plus on-board **ADS-B traffic** and
**GPS** — all over the Stratux Wi-Fi, **no internet needed in flight**.

```
headset / intercom audio ──► USB audio adapter ──► Stratux Pi ──► cockpit_audio_server.py ──┐
                                                                                            ├─► iPad (CommSight, "Stratux receiver" source)
Stratux ADS-B + WAAS GPS  ──────────────────────► Stratux web API (traffic / GPS) ──────────┘
```

The audio sidecar runs **beside** Stratux and never touches its ADS-B/GPS/ForeFlight services, so
ForeFlight keeps working unchanged.

## What CommSight talks to

| Data | Source | Endpoint |
| --- | --- | --- |
| Cockpit audio | this sidecar | `http://<pi>:8090/audio.raw` (raw 16 kHz mono S16LE PCM) |
| Aircraft traffic | Stratux (built-in) | `ws://<pi>/traffic` (one `TrafficInfo` JSON per target) |
| Ownship GPS / fix | Stratux (built-in) | `http://<pi>/getSituation` |

`<pi>` is the Stratux address — **`192.168.10.1`** on the stock Stratux Wi-Fi. Set the address +
audio port in **CommSight → Settings → Stratux receiver**, then pick **"Stratux receiver"** as the
input source and press **Start**. On first connect iOS asks for permission to find devices on the
local network — allow it.

## 1. Wire the audio

```
headset / intercom  →  3.5 mm analog out  →  inline volume/attenuator  →  USB adapter PINK mic-in  →  USB into the Pi
```

Use the **pink microphone** input, not the green headphone jack. Keep it clean and un-clipped (ATC
audio quality matters more than loudness). A 3.5 mm ground-loop isolator on this branch kills engine
whine if present.

## 2. Install the sidecar on the Pi

SSH to the Stratux (`ssh pi@192.168.10.1`), then confirm the adapter and pick a clean capture level:

```bash
arecord -l                      # note the card,device — e.g. "card 1: ... device 0" → plughw:1,0
arecord -D plughw:1,0 -f S16_LE -r 16000 -c 1 -d 10 /tmp/t.wav   # 10 s test
aplay /tmp/t.wav                # (or copy it off and listen); use alsamixer to set capture gain
```

Copy `cockpit_audio_server.py` to the Pi and run it (set `AUDIO_DEVICE` to your card,device):

```bash
AUDIO_DEVICE=plughw:1,0 python3 cockpit_audio_server.py
# verify from a laptop on the Stratux Wi-Fi:
curl http://192.168.10.1:8090/health
curl http://192.168.10.1:8090/audio.raw --output cockpit.raw   # Ctrl-C after ~10 s
ffplay -f s16le -ar 16000 -ac 1 cockpit.raw                    # should be the cockpit audio
```

## 3. Run it on boot (optional)

```bash
sudo mkdir -p /opt/commsight && sudo cp cockpit_audio_server.py /opt/commsight/
sudo tee /etc/systemd/system/cockpit-audio.service >/dev/null <<'EOF'
[Unit]
Description=CommSight cockpit audio
After=network-online.target
[Service]
Type=simple
Environment=AUDIO_DEVICE=plughw:1,0
Environment=AUDIO_PORT=8090
ExecStart=/usr/bin/python3 /opt/commsight/cockpit_audio_server.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now cockpit-audio.service
systemctl status cockpit-audio.service
```

If it doesn't persist across a reboot, the Stratux image may mount root read-only (overlayfs) —
disable the overlay first, or just start it manually for the demo.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `arecord -l` doesn't list the adapter | another USB port / reboot / short USB extension; check `lsusb` |
| Stream is silent | wrong jack — use the **pink mic-in**; try `plughw:0,0` vs `plughw:1,0` |
| Distorted / clipped | lower the inline volume + `alsamixer` capture gain; add an attenuator |
| Buzz / whine | 3.5 mm ground-loop isolator on the audio branch |
| CommSight can't connect | allow the local-network prompt; confirm `/health` from a laptop; check the address in Settings |
| ForeFlight stopped | reboot — the sidecar is separate; if it persists, re-flash the Stratux SD card |

The sidecar serves **one** audio client at a time (the iPad). Traffic/GPS come straight from Stratux,
so ForeFlight and CommSight can read those simultaneously.
