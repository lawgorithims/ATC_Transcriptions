"""Overnight driver: build every CONUS cell of the avoid map, resumably, in parallel.

    nohup caffeinate -i python3 -I lz/avoid/run.py [--workers 6] > $AVOID_WORK/logs/run.log 2>&1 &

Each cell runs as its own process with a hard timeout, so one hung download cannot stall the night.
Cells whose receipt already says ok or empty are skipped, so a rerun picks up where it stopped. A
failed cell is retried once at the end. The run writes $AVOID_WORK/logs/summary.json when done.
"""
import argparse
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

CELL_TIMEOUT_S = 1200
HERE = os.path.dirname(os.path.abspath(__file__))


def receipt(cell):
    p = os.path.join(C.CELLS, f"{cell}.json")
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def run_cell(cell):
    t0 = time.time()
    try:
        p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "cell.py"), cell],
                           capture_output=True, text=True, timeout=CELL_TIMEOUT_S)
        tail = (p.stderr or "").strip().splitlines()[-1:] if p.returncode not in (0,) else []
    except subprocess.TimeoutExpired:
        return cell, "timeout", round(time.time() - t0, 1), "hard timeout"
    r = receipt(cell) or {}
    return cell, r.get("status", "no-receipt"), round(time.time() - t0, 1), (r.get("reason") or " ".join(tail))[:200]


def free_gb(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1e9


def run_all(cells, workers, label):
    todo = [c for c in cells if (receipt(c) or {}).get("status") not in ("ok", "empty")]
    print(f"[{time.strftime('%H:%M:%S')}] {label}: {len(todo)} of {len(cells)} cells to build, {workers} workers",
          flush=True)
    results = {}
    with cf.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(run_cell, c): c for c in todo}
        for i, fut in enumerate(cf.as_completed(futs), 1):          # bounded by the cells submitted
            cell, status, secs, note = fut.result()
            results[cell] = status
            print(f"[{time.strftime('%H:%M:%S')}] {i}/{len(todo)} {cell} {status} {secs}s {note}", flush=True)
            if free_gb(C.WORK) < 30:
                print("ABORT: under 30 GB free", flush=True)
                ex.shutdown(cancel_futures=True)
                break
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--cells", default=os.path.join(C.WORK, "cells.txt"))
    a = ap.parse_args()
    assert 1 <= a.workers <= 12, "workers out of range"
    os.makedirs(C.CELLS, exist_ok=True)
    with open(a.cells) as f:
        cells = [ln.strip() for ln in f if ln.strip()]
    assert 500 < len(cells) < 2000, f"unexpected cell count {len(cells)}"
    t0 = time.time()
    first = run_all(cells, a.workers, "pass 1")
    second = run_all(cells, max(1, a.workers // 2), "retry pass")   # failures and timeouts, once
    final = {c: (receipt(c) or {}).get("status", "missing") for c in cells}
    counts = {}
    for s in final.values():
        counts[s] = counts.get(s, 0) + 1
    summary = {"finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "hours": round((time.time() - t0) / 3600, 2), "counts": counts,
               "not_ok": sorted(c for c, s in final.items() if s not in ("ok", "empty")),
               "pass1": len(first), "retried": len(second)}
    with open(os.path.join(C.LOGS, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(json.dumps(summary, indent=1), flush=True)


if __name__ == "__main__":
    main()
