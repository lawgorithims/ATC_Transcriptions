"""
Health monitor for the pseudo-labeling run: is each feed producing USABLE data,
and is it landing in persistent storage?

Reads the manifests under ``storage_root`` (no GPU, no network) and reports:
  * per-facility / per-feed accepted examples + audio hours + role mix
  * global acceptance rate and reject-reason breakdown (threshold tuning)
  * per-feed acquisition status (recorded / silent / missing)
  * configured feeds that are producing NOTHING (so you can drop or fix them)
  * storage location + free space

    python -m dataset.monitor --config dataset/config.yaml
    python -m dataset.monitor --config dataset/config.yaml --watch 30   # refresh every 30 s
"""

from __future__ import annotations

import json
import shutil
import time
from collections import defaultdict
from pathlib import Path
from typing import Optional

import yaml


def _paths(cfg: dict) -> dict:
    storage_root = Path(cfg.get("storage_root", "data"))
    out_root = Path(cfg.get("output_root") or storage_root / "us_pseudo")
    return {"storage_root": storage_root, "out_root": out_root}


def _read_jsonl(path: Path) -> list:
    rows = []
    if Path(path).exists():
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    return rows


def _configured_feeds(cfg: dict) -> list:
    out = []
    for f in cfg.get("feeds", []):
        name = Path(f["airport_config"]).stem.upper()
        for k in f["feed_keys"]:
            out.append((name, k))
    return out


def report(cfg: dict) -> dict:
    paths = _paths(cfg)
    out_root = paths["out_root"]
    manifest = _read_jsonl(out_root / "manifest.jsonl")
    scores = _read_jsonl(out_root / "scores.jsonl")
    downloads = _read_jsonl(out_root / "downloads.jsonl")

    # Accepted examples per (airport, feed).
    by_feed = defaultdict(lambda: {"n": 0, "secs": 0.0, "controller": 0, "pilot": 0, "unknown": 0})
    total_secs = 0.0
    for r in manifest:
        key = (r.get("airport", "?"), r.get("feed", "?"))
        b = by_feed[key]
        b["n"] += 1
        b["secs"] += float(r.get("dur_s", 0) or 0)
        b[r.get("role", "unknown")] = b.get(r.get("role", "unknown"), 0) + 1
        total_secs += float(r.get("dur_s", 0) or 0)

    # Acquisition status per (airport, feed).
    acq = defaultdict(lambda: defaultdict(int))
    for d in downloads:
        acq[(d.get("airport", "?"), d.get("feed", "?"))][d.get("status", "?")] += 1

    # Global reject reasons.
    reasons = defaultdict(int)
    for s in scores:
        reasons[s.get("reason", "?")] += 1
    total_decisions = len(scores)
    accepted = len(manifest)

    # --- print ---
    print("=" * 72)
    free_gb = shutil.disk_usage(paths["storage_root"]).free / 1e9 if paths["storage_root"].exists() else 0
    print(f"Storage: {paths['storage_root'].resolve()}  (free {free_gb:.1f} GB)")
    print(f"Accepted: {accepted}  |  Audio: {total_secs / 3600:.2f} h  |  "
          f"Decisions: {total_decisions}  |  Accept rate: "
          f"{(accepted / total_decisions * 100) if total_decisions else 0:.1f}%")
    print("-" * 72)
    print(f"{'FACILITY':10s} {'FEED':26s} {'ACCEPT':>6s} {'HOURS':>6s}  ctrl/pilot/unk  {'RECORDED':>8s}")
    configured = _configured_feeds(cfg)
    seen = set()
    for (airport, feed) in sorted(set(list(by_feed) + [(a, f) for a, f in configured])):
        seen.add((airport, feed))
        b = by_feed.get((airport, feed), {"n": 0, "secs": 0.0, "controller": 0, "pilot": 0, "unknown": 0})
        a = acq.get((airport, feed), {})
        recorded = a.get("ok", 0)
        roles = f"{b['controller']}/{b['pilot']}/{b['unknown']}"
        flag = ""
        if (airport, feed) in configured and b["n"] == 0:
            flag = "  <- no usable data yet" if recorded else "  <- not active/recording"
        print(f"{airport:10s} {feed:26s} {b['n']:6d} {b['secs'] / 3600:6.2f}  {roles:>13s}  {recorded:8d}{flag}")
    print("-" * 72)
    if reasons:
        top = sorted(reasons.items(), key=lambda kv: kv[1], reverse=True)
        print("Reject/accept reasons:", ", ".join(f"{k}={v}" for k, v in top))
    print("=" * 72)

    return {
        "accepted": accepted,
        "hours": round(total_secs / 3600, 3),
        "decisions": total_decisions,
        "by_feed": {f"{a}/{f}": v["n"] for (a, f), v in by_feed.items()},
        "reasons": dict(reasons),
        "free_gb": round(free_gb, 1),
    }


def main(argv: Optional[list] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Monitor pseudo-label data health.")
    ap.add_argument("--config", required=True, type=Path)
    ap.add_argument("--watch", type=float, default=0.0, help="refresh interval seconds (0 = once)")
    args = ap.parse_args(argv)
    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))

    if args.watch <= 0:
        report(cfg)
        return 0
    while True:
        print("\033[2J\033[H", end="")  # clear screen
        print(time.strftime("%Y-%m-%d %H:%M:%S"))
        try:
            report(cfg)
        except KeyboardInterrupt:
            break
        time.sleep(args.watch)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
