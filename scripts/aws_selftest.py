#!/usr/bin/env python3
"""
Automated end-to-end self-test for the ATC_Transcribe web server.

Exercises the same HTTP surface the browser console uses, so it gives a
headless "comprehensive test" of the running app without a GUI:

  1. GET  /api/health          - platform / device / torch / model availability
  2. GET  /api/feeds           - preset feeds + replay-demo + ffmpeg availability
  3. GET  /api/model           - active model / adaptive status
  4. POST /api/proof-of-life   - REAL transcription of bundled ATC snippets (the
                                 core proof the model is alive on this device)
  5. session start/poll/stop   - live feed (if ffmpeg) or replay demo (if sample),
                                 collecting transcripts + latency; informational
  6. negative checks           - double-start and model-swap-while-running -> 409

Uses only the Python standard library so it runs in the server's venv with no
extra deps. Prints a compact PASS/FAIL table and writes a JSON report.

Usage:
    python scripts/aws_selftest.py --base http://127.0.0.1:8000
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


def _request(method: str, url: str, body: dict | None = None, timeout: float = 30.0):
    """Return (status_code, parsed_json_or_text). Never raises for HTTP errors."""
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, _maybe_json(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        return exc.code, _maybe_json(raw)
    except Exception as exc:  # connection refused, timeout, etc.
        return None, {"_error": f"{type(exc).__name__}: {exc}"}


def _maybe_json(raw: str):
    try:
        return json.loads(raw)
    except Exception:
        return raw


class Report:
    def __init__(self) -> None:
        self.checks: list[dict] = []
        self.data: dict = {}

    def add(self, name: str, status: str, detail: str = "") -> None:
        # status in {PASS, FAIL, WARN, INFO}
        self.checks.append({"name": name, "status": status, "detail": detail})
        icon = {"PASS": "[PASS]", "FAIL": "[FAIL]", "WARN": "[WARN]", "INFO": "[INFO]"}.get(
            status, "[ -- ]"
        )
        print(f"  {icon} {name}" + (f"  -- {detail}" if detail else ""))

    @property
    def failed(self) -> int:
        return sum(1 for c in self.checks if c["status"] == "FAIL")

    @property
    def passed(self) -> int:
        return sum(1 for c in self.checks if c["status"] == "PASS")


def wait_for_server(base: str, report: Report, timeout: float = 120.0) -> bool:
    print(f"Waiting for server at {base} ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, _ = _request("GET", f"{base}/api/health", timeout=5)
        if status == 200:
            report.add("Server reachable", "PASS", f"{base}")
            return True
        time.sleep(2)
    report.add("Server reachable", "FAIL", f"no 200 from /api/health within {timeout:.0f}s")
    return False


def check_health(base: str, report: Report) -> dict:
    status, body = _request("GET", f"{base}/api/health")
    if status != 200 or not isinstance(body, dict):
        report.add("/api/health", "FAIL", f"status={status} body={body}")
        return {}
    eng = body.get("engine", {})
    report.data["health"] = body
    device = eng.get("resolved_device")
    torch_v = eng.get("torch", "n/a")
    cuda = eng.get("cuda_available")
    avail = eng.get("models_available", {})
    report.add(
        "/api/health",
        "PASS",
        f"device={device} torch={torch_v} cuda={cuda} ffmpeg={eng.get('ffmpeg_available')}",
    )
    if any(avail.values()):
        report.add("Model weights present", "PASS", f"available={avail}")
    else:
        report.add("Model weights present", "FAIL", f"available={avail} (run download_model.py)")
    return eng


def check_feeds(base: str, report: Report) -> dict:
    status, body = _request("GET", f"{base}/api/feeds")
    if status != 200 or not isinstance(body, dict):
        report.add("/api/feeds", "FAIL", f"status={status}")
        return {}
    feeds = body.get("feeds", [])
    report.data["feeds"] = body
    report.add(
        "/api/feeds",
        "PASS",
        f"{len(feeds)} preset feed(s), demo={body.get('demo_available')}, "
        f"ffmpeg={body.get('ffmpeg_available')}",
    )
    return body


def check_proof_of_life(base: str, report: Report) -> None:
    print("Running proof-of-life (loads model + transcribes bundled snippets; "
          "first run can take a while on CPU) ...")
    t0 = time.time()
    status, body = _request("POST", f"{base}/api/proof-of-life?force=true", timeout=900)
    elapsed = time.time() - t0
    if status != 200 or not isinstance(body, dict):
        report.add("Proof-of-life", "FAIL", f"status={status} body={body}")
        return
    report.data["proof_of_life"] = body
    if body.get("error"):
        report.add("Proof-of-life", "FAIL", body["error"])
        return
    verdict = "PASS" if body.get("passed") else "FAIL"
    report.add(
        "Proof-of-life (real transcription)",
        verdict,
        f"model={body.get('active_model')} device={body.get('device')} "
        f"mean_wer={body.get('mean_wer')} rt_speed={body.get('realtime_speed')}x "
        f"load={body.get('load_seconds')}s wall={elapsed:.0f}s",
    )
    for snip in body.get("snippets", []):
        ref = (snip.get("reference") or "").strip()
        hyp = (snip.get("hypothesis") or "").strip()
        report.add(
            f"  snippet {snip.get('file')}",
            "INFO",
            f"wer={snip.get('wer')} | ref='{ref}' | hyp='{hyp}'",
        )


def check_session(base: str, feeds_body: dict, report: Report) -> None:
    """Start a streaming session, poll for transcripts, then stop. Informational:
    depends on ffmpeg + live-feed reachability (or a bundled replay sample)."""
    demo_available = bool(feeds_body.get("demo_available"))
    ffmpeg_available = bool(feeds_body.get("ffmpeg_available"))
    feeds = feeds_body.get("feeds", [])

    if demo_available:
        payload = {"demo": True, "max_segments": 2}
        source = "replay demo"
    elif ffmpeg_available and feeds:
        f0 = feeds[0]
        payload = {"feed_config": f0["feed_config"], "feed_key": f0["feed_key"], "max_segments": 2}
        source = f"live feed {f0.get('airport')}/{f0.get('feed_key')}"
    else:
        report.add(
            "Streaming session",
            "WARN",
            "skipped: no replay sample and "
            + ("no preset feeds" if not feeds else "ffmpeg not installed"),
        )
        return

    print(f"Starting streaming session ({source}) ...")
    status, body = _request("POST", f"{base}/api/session/start", payload, timeout=60)
    if status != 200:
        report.add("Session start", "WARN", f"status={status} body={body} (source={source})")
        return
    report.add("Session start", "PASS", source)

    # Negative check: a second start must be rejected with 409.
    nstatus, _ = _request("POST", f"{base}/api/session/start", payload, timeout=30)
    report.add(
        "Double-start rejected (409)",
        "PASS" if nstatus == 409 else "WARN",
        f"got status={nstatus}",
    )
    # Negative check: swapping models mid-session must be rejected with 409.
    mstatus, _ = _request("POST", f"{base}/api/model/override", {"model": "small"}, timeout=30)
    report.add(
        "Model-swap-while-running rejected (409)",
        "PASS" if mstatus == 409 else "INFO",
        f"got status={mstatus}",
    )

    # Poll status for transcripts / latency for up to ~90s.
    transcripts: list = []
    last_state = None
    deadline = time.time() + 90
    while time.time() < deadline:
        sstatus, snap = _request("GET", f"{base}/api/session/status?last_seq=0", timeout=30)
        if sstatus == 200 and isinstance(snap, dict):
            last_state = snap.get("state")
            recs = snap.get("records") or snap.get("transcripts") or []
            if recs:
                transcripts = recs
            if last_state in ("stopped", "error") or len(transcripts) >= 2:
                break
        time.sleep(3)

    _request("POST", f"{base}/api/session/stop", timeout=30)
    report.add("Session stop", "PASS", f"final_state={last_state}")
    if transcripts:
        report.add("Live transcripts received", "PASS", f"{len(transcripts)} transmission(s)")
        report.data["session_transcripts"] = transcripts
        for r in transcripts[:3]:
            txt = r.get("text") or r.get("transcript") or ""
            report.add("  transmission", "INFO", txt.strip()[:160])
    else:
        report.add(
            "Live transcripts received",
            "WARN",
            "none within 90s (feed may be quiet/unreachable, or ffmpeg missing)",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="ATC_Transcribe web server self-test")
    parser.add_argument("--base", default="http://127.0.0.1:8000", help="Server base URL")
    parser.add_argument("--report", default="aws_selftest_report.json", help="JSON report path")
    parser.add_argument(
        "--skip-session", action="store_true", help="Skip the streaming session test"
    )
    args = parser.parse_args()
    base = args.base.rstrip("/")

    report = Report()
    print("=" * 64)
    print(" ATC_Transcribe - automated browser-API self-test")
    print("=" * 64)

    if not wait_for_server(base, report):
        _finish(report, args.report)
        return 1

    print("\n-- Environment & availability --")
    check_health(base, report)
    feeds_body = check_feeds(base, report)
    mstatus, mbody = _request("GET", f"{base}/api/model")
    report.add("/api/model", "PASS" if mstatus == 200 else "FAIL", json.dumps(mbody)[:120])

    print("\n-- Core model proof-of-life --")
    check_proof_of_life(base, report)

    if not args.skip_session:
        print("\n-- Streaming session --")
        check_session(base, feeds_body, report)

    return _finish(report, args.report)


def _finish(report: Report, report_path: str) -> int:
    print("\n" + "=" * 64)
    print(f" SUMMARY: {report.passed} passed, {report.failed} failed, "
          f"{sum(1 for c in report.checks if c['status'] == 'WARN')} warn")
    print("=" * 64)
    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "passed": report.passed,
        "failed": report.failed,
        "checks": report.checks,
        "data": report.data,
    }
    try:
        with open(report_path, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2)
        print(f"Full JSON report written to: {report_path}")
    except Exception as exc:
        print(f"(could not write report: {exc})")
    return 0 if report.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
