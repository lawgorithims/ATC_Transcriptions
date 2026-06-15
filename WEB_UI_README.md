# ATC_Transcribe — Browser Console (Web UI)

A browser front-end for the live ATC transcriber. It runs **on the host that has
the model** (e.g. the Apple-Silicon Mac) and is reached from any browser on the
same network — no app install on the viewing device.

It gives you:

- a **live transcript** of ATC communications as each transmission is decoded;
- a control bar to **paste a LiveATC link** (or pick a preset feed / replay demo)
  and transcribe it in real time;
- a **status panel** showing the **handshake** (browser ↔ host) and
  **proof-of-life** (model loads and transcribes on this host's device);
- rolling **latency** stats (capture-to-text, transcribe time, real-time factor).

```
   ┌────────────┐     HTTP + WebSocket      ┌─────────────────────────────┐
   │  Browser   │ ◀───────────────────────▶ │  Apple-Silicon host          │
   │ (any LAN   │   transcripts / status    │  server/app.py (FastAPI)     │
   │  device)   │                           │   ├─ TranscriberEngine (MPS) │
   └────────────┘                           │   └─ LiveATCPipeline + ffmpeg│
                                            └─────────────────────────────┘
```

The browser never touches the model directly — it talks to `server/app.py`,
which owns the shared Whisper model and the live pipeline.

---

## 1. Update the Apple-Silicon machine

Run these **on the Mac** (this picks up the latest code, including the web UI):

```bash
cd /path/to/ATC_Transcribe
git pull

# Refresh the environment (re-runs deps + model check; safe to repeat)
bash scripts/install.sh
source .venv/bin/activate

# Add the web-server dependencies (FastAPI + uvicorn)
pip install -r requirements-server.txt

# ffmpeg is required for live web streams
brew install ffmpeg
```

> `scripts/install.sh` and `scripts/run_web_server.sh` both install
> `requirements-server.txt` for you, so the explicit `pip install` above is only
> needed if you want to do it by hand.

Confirm the model still loads on the Metal GPU:

```bash
python diagnostics/diagnostic.py --device mps
```

A `PASS` means the same proof-of-life the web UI shows will be green.

---

## 2. Start the server

```bash
# macOS / Linux
bash scripts/run_web_server.sh                 # binds 0.0.0.0:8000, device auto (MPS)
bash scripts/run_web_server.sh --port 9000
bash scripts/run_web_server.sh --device mps --warm   # load model + run PoL at startup

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File scripts/run_web_server.ps1
powershell -ExecutionPolicy Bypass -File scripts/run_web_server.ps1 -Port 9000

# Or directly
python -m server.app --host 0.0.0.0 --port 8000
```

The server prints its address. From another device on the network, browse to the
host's LAN IP, e.g. `http://192.168.1.50:8000`. On the host itself,
`http://localhost:8000` works too.

`--warm` loads the ~1 GB model and runs proof-of-life at startup so the first
page load is instant; otherwise the model loads lazily on the first
proof-of-life or stream start.

---

## 3. Use it

1. **Watch the status pills** (top right):
   - **Handshake** turns green when the browser's WebSocket reaches the host.
   - **Proof of life** runs automatically on load: it transcribes a couple of
     bundled ATC snippets and turns green on `PASS` (shows the device + word
     error rate). Re-run any time with **Run proof-of-life**.
   - **Stream** shows the live session state (idle → connecting → live → stopped).
2. **Transcribe a feed.** Pick a source:
   - **Custom stream URL** — paste a LiveATC listen-page link
     (`https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c`),
     a direct `.mp3`/Icecast URL, or a LiveATC mount. Press **Start**.
   - **Preset feeds** — the KDFW / KJFK feeds from `airport_configs/*.json`
     (these include airport context for better accuracy).
   - **Replay demo** — replays a bundled recording at live pace. Works **without
     ffmpeg**, so it's the quickest way to see the transcript flow end-to-end.
3. Transmissions stream into the transcript panel with timestamps and latency.
   Press **Stop** to end the session.

> **ffmpeg:** live web streams are decoded with ffmpeg. If it isn't installed,
> the UI shows a warning and live URLs fail with a clear message — the **replay
> demo** still works. Install with `brew install ffmpeg` (macOS) /
> `winget install Gyan.FFmpeg` (Windows).

---

## 4. HTTP / WebSocket API

The UI is a thin client over these endpoints (handy for scripting / testing):

| Method | Path | Purpose |
| ------ | ---- | ------- |
| `GET`  | `/` | The browser UI |
| `GET`  | `/api/health` | Platform, device, model + ffmpeg availability |
| `GET`  | `/api/feeds` | Preset feeds + replay-demo availability |
| `POST` | `/api/proof-of-life?force=true` | Run the handshake; returns PASS/FAIL, device, WER |
| `POST` | `/api/session/start` | Body: `{stream_url}` \| `{feed_config,feed_key}` \| `{demo:true}` |
| `POST` | `/api/session/stop` | Stop the current session |
| `GET`  | `/api/session/status?last_seq=N` | Snapshot of status, transcripts, stats |
| `WS`   | `/ws` | Live transcript + status stream (snapshot then deltas) |

Example:

```bash
curl -X POST localhost:8000/api/proof-of-life?force=true
curl -X POST localhost:8000/api/session/start \
  -H 'Content-Type: application/json' \
  -d '{"stream_url":"https://www.liveatc.net/hlisten.php?icao=kdfw&mount=kdfw1_app_fin_17c"}'
```

---

## 5. Notes & limits

- **One session at a time.** Starting a new stream while one is running returns
  `409`; stop it first. The model is shared across proof-of-life and the session,
  so it is only loaded once.
- **No authentication.** This is a LAN testing tool — it binds `0.0.0.0` with
  open CORS and no auth. Don't expose it directly to the public internet; put it
  behind a VPN / reverse proxy with auth if you need remote access.
- **Device.** `--device auto` resolves to Metal (MPS) on Apple Silicon, CUDA on
  NVIDIA, else CPU — same resolution as the CLI and the diagnostic.
- **Architecture.** `server/engine.py` owns the shared model + proof-of-life;
  `server/session.py` runs `LiveATCPipeline` in a background thread and exposes a
  thread-safe view; `server/app.py` is the FastAPI layer; `server/static/` is the
  framework-free UI.
