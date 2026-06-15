"""
ATC_Transcribe web server.

Serves a browser UI from the host running the fine-tuned Whisper model (e.g. the
Apple-Silicon Mac) and exposes:

  GET  /                     -> the UI (server/static/index.html)
  GET  /api/health           -> environment / device / model / ffmpeg status
  GET  /api/feeds            -> preset LiveATC feeds + replay-demo availability
  POST /api/proof-of-life    -> run the handshake (model alive on this device)
  POST /api/session/start    -> start transcribing a stream URL / feed / demo
  POST /api/session/stop     -> stop the current session
  GET  /api/session/status   -> current session snapshot
  WS   /ws                   -> live transcript + status stream

Run (from the project root):
    python -m server.app --host 0.0.0.0 --port 8000
    # or
    uvicorn server.app:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Optional

# Make the project root importable whether launched as `python server/app.py`,
# `python -m server.app`, or via uvicorn.
ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from fastapi import FastAPI, WebSocket, WebSocketDisconnect  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from fastapi.responses import FileResponse, JSONResponse  # noqa: E402
from fastapi.staticfiles import StaticFiles  # noqa: E402
from pydantic import BaseModel  # noqa: E402

from server.engine import TranscriberEngine, ensure_ffmpeg_on_path  # noqa: E402
from server.session import TranscriptionSession  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "static"
AIRPORT_CONFIG_DIR = ROOT / "airport_configs"
DEMO_SAMPLE = ROOT / "data" / "live_atc" / "KJFK-Twr2-Mar-15-2026-0000Z.mp3"


class StartRequest(BaseModel):
    stream_url: Optional[str] = None
    feed_config: Optional[str] = None
    feed_key: Optional[str] = None
    demo: bool = False
    max_segments: Optional[int] = None
    source_label: Optional[str] = None


def list_feeds() -> list[dict]:
    """Enumerate preset feeds from airport_configs/*.json for the UI dropdown."""
    feeds: list[dict] = []
    if AIRPORT_CONFIG_DIR.is_dir():
        for cfg_path in sorted(AIRPORT_CONFIG_DIR.glob("*.json")):
            try:
                cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
            except Exception:
                continue
            airport = cfg.get("airport_name") or cfg.get("airport_code") or cfg_path.stem
            for key, entry in (cfg.get("streams") or {}).items():
                feeds.append(
                    {
                        "feed_config": str(cfg_path.relative_to(ROOT)).replace("\\", "/"),
                        "feed_key": key,
                        "airport": airport,
                        "label": entry.get("label") or key,
                        "frequency_mhz": entry.get("frequency_mhz"),
                    }
                )
    return feeds


def create_app(model_path: str | None = None, device: str = "auto") -> FastAPI:
    model_path = model_path or os.environ.get(
        "ATC_MODEL_PATH", str(ROOT / "models" / "whisper-atc")
    )
    device = os.environ.get("ATC_DEVICE", device)

    # Recover a just-installed ffmpeg whose PATH update hasn't propagated yet.
    ensure_ffmpeg_on_path()

    engine = TranscriberEngine(model_path=model_path, device=device)
    session = TranscriptionSession(engine)

    app = FastAPI(title="ATC_Transcribe Web UI", version="1.0")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.state.engine = engine
    app.state.session = session

    # ----- REST ---------------------------------------------------------

    @app.get("/api/health")
    async def health():
        return {"server": "ok", "engine": engine.health()}

    @app.get("/api/feeds")
    async def feeds():
        return {
            "feeds": list_feeds(),
            "demo_available": DEMO_SAMPLE.exists(),
            "demo_label": f"Replay demo ({DEMO_SAMPLE.name})" if DEMO_SAMPLE.exists() else None,
            "ffmpeg_available": engine.ffmpeg_available(),
        }

    @app.post("/api/proof-of-life")
    async def proof_of_life(force: bool = False):
        result = await asyncio.to_thread(engine.proof_of_life, 2, force)
        return result

    @app.post("/api/session/start")
    async def session_start(req: StartRequest):
        if session.is_running():
            return JSONResponse(
                status_code=409,
                content={"error": "A session is already running. Stop it first."},
            )
        try:
            if req.demo:
                if not DEMO_SAMPLE.exists():
                    return JSONResponse(
                        status_code=400,
                        content={"error": "No replay demo sample is available on this host."},
                    )
                snap = await asyncio.to_thread(
                    lambda: session.start(
                        simulate_file=str(DEMO_SAMPLE),
                        fast_simulate=False,
                        max_segments=req.max_segments,
                        source_label=req.source_label or "Replay demo",
                    )
                )
            else:
                snap = await asyncio.to_thread(
                    lambda: session.start(
                        stream_url=req.stream_url,
                        feed_config=req.feed_config,
                        feed_key=req.feed_key,
                        max_segments=req.max_segments,
                        source_label=req.source_label,
                    )
                )
            return snap
        except ValueError as exc:
            return JSONResponse(status_code=400, content={"error": str(exc)})
        except Exception as exc:  # pragma: no cover
            return JSONResponse(status_code=500, content={"error": str(exc)})

    @app.post("/api/session/stop")
    async def session_stop():
        snap = await asyncio.to_thread(session.stop)
        return snap

    @app.get("/api/session/status")
    async def session_status(last_seq: int = 0):
        return session.snapshot(last_seq=last_seq)

    # ----- WebSocket: live transcript + status --------------------------

    @app.websocket("/ws")
    async def ws(websocket: WebSocket):
        await websocket.accept()
        try:
            snap = session.snapshot(0)
            await websocket.send_json(
                {"type": "snapshot", "session": snap, "health": engine.health()}
            )
            last_seq = snap["seq"]
            while True:
                await asyncio.sleep(0.4)
                snap = session.snapshot(last_seq)
                if snap["records"]:
                    last_seq = snap["records"][-1]["seq"]
                await websocket.send_json({"type": "delta", "session": snap})
        except WebSocketDisconnect:
            return
        except Exception:
            # Client went away or socket errored; end the loop quietly.
            return

    # ----- UI -----------------------------------------------------------

    if STATIC_DIR.is_dir():
        app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    @app.get("/")
    async def index():
        index_file = STATIC_DIR / "index.html"
        if index_file.exists():
            return FileResponse(str(index_file))
        return JSONResponse(
            status_code=500, content={"error": "UI not found (server/static/index.html)"}
        )

    return app


# Module-level app for `uvicorn server.app:app`.
app = create_app()


def main() -> None:
    parser = argparse.ArgumentParser(description="ATC_Transcribe web UI server")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8000, help="Port (default 8000)")
    parser.add_argument(
        "--device", default="auto", help="auto | mps | cuda | cpu (default auto)"
    )
    parser.add_argument(
        "--model-path", default=None, help="Path to fine-tuned model (default models/whisper-atc)"
    )
    parser.add_argument(
        "--warm", action="store_true", help="Load the model + run proof-of-life at startup"
    )
    args = parser.parse_args()

    import uvicorn

    global app
    app = create_app(model_path=args.model_path, device=args.device)

    if args.warm:
        print("Warming up: loading model and running proof-of-life ...")
        result = app.state.engine.proof_of_life(force=True)
        verdict = "PASS" if result.get("passed") else "FAIL"
        print(f"Proof-of-life: {verdict} (device={result.get('device')}, "
              f"mean WER={result.get('mean_wer')})")

    print(f"\nATC_Transcribe web UI -> http://{args.host}:{args.port}")
    print("Open that address in a browser on the same network.\n")
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
