# Chart border audit

Checks, through the **running app**, that every place two FAA chart packs meet is served at full
detail — no transparent collar, no strip where only the blurry base shows through.

It compares two things for each tile along a border:

- **served** — what the app's loopback tile server (`MBTilesHTTPServer`) actually returns;
- **oracle** — an independent composite built straight from the `.mbtiles` files: each pack's native
  tile, or its nearest ancestor (≤ 4 levels), or its overzoom (≤ 5 levels), stacked.

A tile is flagged when the served image is more than 3 % less opaque than the oracle. Only seam tiles
(two or more packs can contribute) are probed, within ±0.5° of the centre of each overlap.

## Files

- `probe.py` — `pairs` lists touching pack pairs with a centre point; `check a b z…` probes one border.
- `sweep.py` — runs a whole pairs list on one simulator: installs packs in batches under the app's
  600 MB disk budget, relaunches the app at each border with `--chart-layer` / `--chart-center`, finds
  the tile server's port with `lsof`, and appends one JSON line per border.

## Running it

Needs a Python with Pillow, a simulator with the app installed, and built packs.

```bash
python3 -m venv /tmp/cba && /tmp/cba/bin/pip install pillow
cd ios/Tools/chart_border_audit
/tmp/cba/bin/python probe.py ~/CommSight/charts-build/packs 0 ENR_L pairs > enrL_pairs.txt
PYTHON=/tmp/cba/bin/python python3 sweep.py <sim-udid> ENR_L ifrLow enrL_pairs.txt enrL.jsonl 10 11 12
```

Kinds and layers: `_SEC`/`sectional` (z5–12), `ENR_L`/`ifrLow` (z10–12), `ENR_H`/`ifrHigh` (z10–11).
Several simulators can run disjoint pairs lists in parallel; on a 10-core Mac four was the most that
stayed reliable.

## Reading the result

Each line has `z → {seam_tiles, errors, short, worst_gap, examples}`, plus `evicted` (packs the
600 MB budget deleted — a border with an evicted pack is a harness miss, not an app bug).

Before trusting a clean run, prove the probe can fail: uninstall the packs and re-probe a few
borders — every one must come back short. A flag that does not reproduce on its own pair should be
re-run before it is called a bug: under heavy load the fixed 12 s wait can catch one pack unmounted.

Last full run (2026-11, cycle 09-03-2026): sectional 92/92, IFR-high 34/34, IFR-low 97/98 clean; the
one flag (ENR_L10/ENR_L16) did not reproduce in seven retries.
