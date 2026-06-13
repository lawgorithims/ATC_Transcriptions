# Live ATC Pipeline

Real-time transcription from **online ATC radio feeds** (not microphone input).

## Fresh install

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

Or double-click `scripts/install.bat`. Then activate:

```powershell
.\.venv\Scripts\Activate.ps1
```

Requires **ffmpeg** on PATH for live streams (`winget install Gyan.FFmpeg`).

## Quick start

**Live KDFW Lone Star Approach (default):**

```bash
python live_atc_pipeline.py
```

This tunes into **Lone Star Approach (17/35C Final)** — Dallas, 127.075 MHz — from `airport_configs/kdfw.json`.

**Custom replaceable stream URL:**

```bash
python live_atc_pipeline.py --stream-url "https://d.liveatc.net/kdfw1_app_fin_17c"
```

**LiveATC listen page:**

```bash
python live_atc_pipeline.py --liveatc-page "https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c"
```

**Different KDFW feed:**

```bash
python live_atc_pipeline.py --feed lone_star_approach_17l_final
```

## Offline latency evaluation

Uses the archived JFK sample recording (legacy test data):

```bash
python live_atc_pipeline.py \
  --simulate-file data/live_atc/KJFK-Twr2-Mar-15-2026-0000Z.mp3 \
  --fast-simulate \
  --max-segments 20 \
  --output-json results/live/kdfw/latency_report.json
```

Or: `scripts\run_latency_eval.bat`

## Changing the feed

Feeds are in `airport_configs/kdfw.json` under `streams`:

```json
"lone_star_approach_17c_final": {
  "label": "Lone Star Approach (17/35C Final)",
  "url": "https://d.liveatc.net/kdfw1_app_fin_17c",
  "liveatc_page": "https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c",
  "frequency_mhz": "127.075"
}
```

Replace `url` with any MP3/Icecast ATC stream. Defaults also in `config.yaml` under `live_pipeline:`.

## Configuration

| Flag | Default | Description |
|------|---------|-------------|
| `--feed-config` | `airport_configs/kdfw.json` | Airport feed definitions |
| `--feed` | `lone_star_approach_17c_final` | Which stream key to use |
| `--stream-url` | — | Override with any direct stream URL |
| `--max-segments` | unlimited | Stop after N transmissions |
| `--output-json` | — | Save latency report JSON |
| `--fast-simulate` | off | Replay local file as fast as possible |

See also `README.md` and `atc_stream.py`.
