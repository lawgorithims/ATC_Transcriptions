#!/usr/bin/env python3
"""Mint verify receipts for packs that were gated BEFORE receipts existed.

⚠️ READ THIS BEFORE TRUSTING ANYTHING IT WRITES.

`publish.py` now refuses to upload a pack that carries no receipt from a passing `verify.py`. That
is the right rule — a rejected pack stays on disk looking exactly like an accepted one, and two of
them were one publish away from every device. But it stranded sixteen packs that WERE gated, at
build time, before the receipt existed: re-verifying them needs the source rasters, and those are
deleted by design the moment a cell finishes.

This does NOT grandfather them on trust. For each pack it:

  1. finds that cell's build log and requires it to record a real verify run;
  2. requires EVERY structural check in that log to have passed, with ONE named exception — the z13
     tile count, whose rule has since changed (it used to demand half the cell's tiles outright,
     which is wrong wherever the country has a coastline);
  3. re-applies the CURRENT tile rule from scratch, counting z13 tiles out of the pack itself and
     scaling against the DEM coverage the log recorded;
  4. and only then writes a receipt, stamped with where its evidence came from.

Fails closed everywhere: no log, an unparseable log, any other failed check, or a tile count that
does not satisfy today's rule means no receipt and a printed reason. A receipt minted here says
`basis: build-log` so it can never be mistaken for a fresh verification.
"""
import glob
import hashlib
import json
import os
import re
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lzcommon as C                                              # noqa: E402

LOG_DIR = ("/private/tmp/claude-501/-Users-bsusl/"
           "9d2aac48-9e5c-4de6-a943-c605eaeb11b0/scratchpad")
OUT_DIR = os.path.join(HERE, "out")

# The one check allowed to have failed in the log, because its rule has since been corrected.
FORGIVEN = "z13 tile count"


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def z13_tiles(pack_path):
    """Count native-zoom tiles from the pack itself — no manifest, no work directory."""
    con = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    try:
        n = con.execute("SELECT COUNT(*) FROM tiles WHERE zoom_level = ?",
                        (C.NATIVE_ZOOM,)).fetchone()[0]
    finally:
        con.close()
    return int(n)


def read_log(cell):
    path = os.path.join(LOG_DIR, f"build_{cell}.log")
    if not os.path.exists(path):
        return None, f"no build log at {os.path.basename(path)}"
    text = open(path, errors="replace").read()
    # Only the LAST verify block matters — a cell may have been attempted more than once.
    blocks = text.split("== verify")
    if len(blocks) < 2:
        return None, "build log records no verify run"
    return blocks[-1], None


def coverage_from_log(cell):
    text = open(os.path.join(LOG_DIR, f"build_{cell}.log"), errors="replace").read()
    m = None
    for m in re.finditer(r'"coverage_pct":\s*([0-9.]+)', text):
        pass
    if m is None:
        for m in re.finditer(r"1 m ([0-9.]+)% of cell", text):
            pass
    return float(m.group(1)) / 100.0 if m else None


def judge(cell, pack_path):
    """(ok, reason, detail) — may this pack be vouched for by today's rules?"""
    block, why = read_log(cell)
    if block is None:
        return False, why, {}

    failed = [ln.strip() for ln in block.splitlines() if ln.startswith("FAIL")]
    unforgiven = [f for f in failed if FORGIVEN not in f]
    if unforgiven:
        return False, f"log records {len(unforgiven)} failed check(s) that are still failures: " \
                      f"{unforgiven[0][:80]}", {}

    if "ODbL independence" not in block:
        return False, "log has no ODbL independence result — licence separation unproven", {}
    if re.search(r"^FAIL.*ODbL", block, re.M):
        return False, "the ODbL gate FAILED in the log", {}

    cov = coverage_from_log(cell)
    if cov is None:
        return False, "no DEM coverage recorded in the log — cannot apply the tile rule", {}

    expect13 = len(C.cell_tiles(C.NATIVE_ZOOM))
    got13 = z13_tiles(pack_path)
    floor = expect13 * cov * 0.75
    if not (got13 <= expect13 and got13 > floor):
        return False, (f"fails TODAY's tile rule: {got13} of {expect13} against a floor of "
                       f"{floor:.0f} at {100 * cov:.1f}% coverage"), {}
    return True, "", {"z13": got13, "of": expect13, "coverage_pct": round(100 * cov, 2),
                      "floor": round(floor, 1)}


def main():
    packs = sorted(p for p in glob.glob(os.path.join(OUT_DIR, "*.lzpack"))
                   if "fixture" not in os.path.basename(p))
    minted, refused, already = [], [], []
    for path in packs:
        cell = os.path.basename(path)[:-len(".lzpack")]
        rec_path = path + ".verified.json"
        if os.path.exists(rec_path):
            already.append(cell)
            continue
        # ⚠️ SELECT THE CELL FIRST. `lzcommon` is cell-parameterised — `cell_tiles` answers for
        # whichever cell is currently selected, and a 1-degree cell covers MORE Mercator tiles the
        # further north it sits (696 at n37 against 644 at n33). Without this every comparison used
        # the default cell's count and the tool refused sixty-seven perfectly good packs, blaming
        # them for its own mistake.
        C.select_cell(cell)
        ok, why, detail = judge(cell, path)
        if not ok:
            refused.append((cell, why))
            continue
        rec = {"cell": cell, "sha256": sha256_of(path), "bytes": os.path.getsize(path),
               "verified_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "basis": "build-log", "tile_rule": detail,
               "note": "Gated by verify.py at build time, before receipts existed. Every other "
                       "check passed in the log; the z13 tile rule was re-applied here against "
                       "the pack's own tile count and the coverage the log recorded."}
        with open(rec_path, "w") as fh:
            json.dump(rec, fh, indent=2, sort_keys=True)
        minted.append((cell, detail))

    for cell, d in minted:
        print(f"  minted  {cell}  z13 {d['z13']}/{d['of']} at {d['coverage_pct']}% coverage "
              f"(floor {d['floor']})")
    for cell, why in refused:
        print(f"  REFUSED {cell}  {why}")
    print(f"\n{len(minted)} minted, {len(refused)} refused, {len(already)} already had one")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
