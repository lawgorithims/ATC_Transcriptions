#!/usr/bin/env python3
"""extent.py — Stage 4: how much ROOM there is, as a fact about the ground.

WHAT IT MAKES
    lz/work/<cell>/extent.npy    uint8, metres/EXTENT_STEP_M, longest open run through each cell

WHY THIS IS A PIPELINE PLANE AND NOT A DEVICE COMPUTATION
    The device scores a pixel from lookup tables — six plane values in, one score out, no
    neighbours. Measuring how far open ground CONTINUES needs to walk neighbouring cells, and
    across tile boundaries, which is not something a render thread can do per pixel.

    It is also the wrong place philosophically. "How long is this field" is a fact about ground,
    exactly like its slope or its land cover, so it belongs with the other facts. The device turns
    it into a verdict against the aircraft's landing distance — the same murphy contract as
    everything else: facts here, judgment there.

WHAT PROBLEM IT SOLVES
    Before this plane, a 60 m patch of perfect flat cropland ringed by forest scored IDENTICALLY to
    the middle of a mile-wide field. Same class, same slope, same roughness, same hazard — so the
    same colour, and a pilot reading the gradient could not tell them apart. One of them is usable
    and one is not, and the difference is not a recommendation, it is risk.

AIRCRAFT-AGNOSTIC BY CONSTRUCTION
    The mask below is the loosest defensible reading of "could any light aeroplane conceivably use
    this": not water, wetland, forest, dense development or snow, and not absurdly steep. It is
    deliberately MORE permissive than any aircraft's own rules, which makes the published extent an
    UPPER BOUND on usable run. The device may cut it down with its own vetoes; it can never widen
    it. A bound that can only shrink is one a pilot can rely on.

MEASURED ALONG FOUR AXES, AND THAT UNDER-REPORTS
    Runs are measured horizontally, vertically and along both diagonals, and the longest wins. A
    field whose long axis falls between two of those reads short — worst case at 22.5 deg off, where
    the measurement is cos(22.5) = 92% of the truth. That error is in the safe direction (less room
    reported than exists) and 8% is far inside the uncertainty of the land cover it is measuring.

USAGE
    python3 lz/extent.py --cell n33w107 --build
    python3 lz/extent.py --cell n33w107 --verify
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C  # noqa: E402

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: python3 -m pip install numpy")


# Classes an aeroplane could conceivably put down on. Deliberately generous — see the module note.
OPEN_CLASSES = (
    C.CLASS_OPEN_FIRM, C.CLASS_OPEN_SOFT, C.CLASS_CROP,
    C.CLASS_BRUSH, C.CLASS_BARREN_ROUGH, C.CLASS_DEVELOPED_OPEN,
)
# Beyond this, "run length" stops meaning anything useful — nobody lands along a 30 deg slope, and
# including it would let a mountainside inflate the extent of the flat ground beside it.
OPEN_MAX_SLOPE_DEG = 15.0


def build(workdir):
    C.require_numpy()
    cls = np.load(os.path.join(workdir, "class.npy"), mmap_mode="r")
    slope = np.load(os.path.join(workdir, "slope.npy"), mmap_mode="r")
    assert cls.shape == slope.shape, "extent: class and slope grids disagree"

    t0 = time.time()
    mask = np.isin(cls, OPEN_CLASSES)
    # Slope is stored as magnitude in SLOPE_STEP_DEG units, with a no-data sentinel. NO DATA IS NOT
    # OPEN: ground we could not measure must not contribute length to a run a pilot may rely on.
    slope_ok = (slope != C.SLOPE_NODATA) & (slope <= int(OPEN_MAX_SLOPE_DEG / C.SLOPE_STEP_DEG))
    mask &= slope_ok
    print(f"   open mask: {mask.mean()*100:.1f}% of the grid  ({time.time()-t0:.0f}s)")

    best = np.zeros(mask.shape, dtype=np.int16)
    for name, (di, dj) in (("horizontal", (0, 1)), ("vertical", (1, 0)),
                           ("diagonal /", (1, 1)), ("diagonal \\", (1, -1))):
        t = time.time()
        run = _run_lengths(mask, di, dj)
        np.maximum(best, run, out=best)
        print(f"   {name:12} max run {run.max()} cells  ({time.time()-t:.0f}s)")

    # Cells -> metres. A run of N cells spans N * CELL_SIZE_M along an axis; the diagonals are
    # longer per step, but they are NOT scaled up — over-reporting length on a diagonal field is
    # exactly the direction this must never err in.
    metres = best.astype(np.float32) * C.CELL_SIZE_M
    out = np.clip(np.rint(metres / EXTENT_STEP_M), 0, 255).astype(np.uint8)
    # A cell that is not open at all has no run, and must read as zero rather than as "unknown".
    out[~mask] = 0

    path = os.path.join(workdir, "extent.npy")
    np.save(path, out)
    usable = out[out > 0]
    print(f"   wrote {os.path.basename(path)}  "
          f"open cells {usable.size/1e6:.1f}M, median run "
          f"{int(np.median(usable)) * EXTENT_STEP_M if usable.size else 0:.0f} m, "
          f"max {int(out.max()) * EXTENT_STEP_M:.0f} m  ({time.time()-t0:.0f}s total)")
    return 0


EXTENT_STEP_M = C.EXTENT_STEP_M


def _run_lengths(mask, di, dj):
    """Length, in cells, of the contiguous True run each cell belongs to, along one direction.

    Two sweeps: one counting up to each cell, one counting back from it. The cell's run is the sum
    minus itself. The loop is over ROWS (or columns), not cells — each iteration is one vectorised
    operation over a whole line, so 137M cells cost thousands of numpy calls rather than millions.
    """
    # int16, not int32: the longest possible run is the grid's own width (~12.5k cells), which fits
    # with room to spare, and this array is allocated three times over 137M cells. int32 would cost
    # 1.6 GB per direction on a machine that is also building other cells.
    m = mask.astype(np.int16)
    fwd = np.zeros_like(m)
    bwd = np.zeros_like(m)
    h, w = m.shape
    steps = h if di else w
    assert steps > 0, "_run_lengths: empty grid"

    # Forward sweep.
    for k in range(steps):                                     # bounded by the grid (rule 2)
        if di == 0:                                            # along a row
            if k == 0:
                fwd[:, 0] = m[:, 0]
            else:
                fwd[:, k] = (fwd[:, k - 1] + 1) * m[:, k]
        elif dj == 0:                                          # down a column
            if k == 0:
                fwd[0, :] = m[0, :]
            else:
                fwd[k, :] = (fwd[k - 1, :] + 1) * m[k, :]
        else:                                                  # a diagonal
            if k == 0:
                fwd[0, :] = m[0, :]
            elif dj > 0:
                fwd[k, 1:] = (fwd[k - 1, :-1] + 1) * m[k, 1:]
                fwd[k, 0] = m[k, 0]
            else:
                fwd[k, :-1] = (fwd[k - 1, 1:] + 1) * m[k, :-1]
                fwd[k, -1] = m[k, -1]

    # Backward sweep — the same recurrence walked the other way.
    for k in range(steps - 1, -1, -1):                         # bounded (rule 2)
        if di == 0:
            if k == w - 1:
                bwd[:, k] = m[:, k]
            else:
                bwd[:, k] = (bwd[:, k + 1] + 1) * m[:, k]
        elif dj == 0:
            if k == h - 1:
                bwd[k, :] = m[k, :]
            else:
                bwd[k, :] = (bwd[k + 1, :] + 1) * m[k, :]
        else:
            if k == h - 1:
                bwd[k, :] = m[k, :]
            elif dj > 0:
                bwd[k, :-1] = (bwd[k + 1, 1:] + 1) * m[k, :-1]
                bwd[k, -1] = m[k, -1]
            else:
                bwd[k, 1:] = (bwd[k + 1, :-1] + 1) * m[k, 1:]
                bwd[k, 0] = m[k, 0]

    run = fwd + bwd - m          # the cell itself is counted in both sweeps
    return np.where(m > 0, run, 0)


def verify(workdir):
    """Sanity, not ground truth: the plane must be shaped right and internally consistent."""
    path = os.path.join(workdir, "extent.npy")
    if not os.path.exists(path):
        print("FAIL extent.npy missing — run --build")
        return 1
    ext = np.load(path, mmap_mode="r")
    cls = np.load(os.path.join(workdir, "class.npy"), mmap_mode="r")
    ok = True

    if ext.shape != cls.shape:
        print(f"FAIL shape {ext.shape} != class {cls.shape}"); ok = False
    else:
        print(f"ok   shape {ext.shape}")

    # Water can never carry a run. If it does, the mask leaked.
    water = ext[np.asarray(cls) == C.CLASS_WATER]
    if water.size and water.max() > 0:
        print(f"FAIL water carries a run of {int(water.max())*EXTENT_STEP_M:.0f} m"); ok = False
    else:
        print("ok   water carries no run")

    # Forest likewise.
    forest = ext[np.asarray(cls) == C.CLASS_FOREST]
    if forest.size and forest.max() > 0:
        print(f"FAIL forest carries a run"); ok = False
    else:
        print("ok   forest carries no run")

    open_ext = ext[np.asarray(ext) > 0]
    if open_ext.size == 0:
        print("FAIL nothing in this cell has any open run at all"); ok = False
    else:
        print(f"ok   {open_ext.size/1e6:.1f}M cells carry a run, median "
              f"{int(np.median(open_ext))*EXTENT_STEP_M:.0f} m, max "
              f"{int(open_ext.max())*EXTENT_STEP_M:.0f} m")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", action="store_true", help="compute the extent plane")
    ap.add_argument("--verify", action="store_true", help="shape + mask-leak checks")
    C.add_cell_argument(ap)
    a = ap.parse_args()
    C.select_cell(a.cell)          # before ANY path is built

    wd = C.cell_dir(C.WORK_DIR, None)
    rc = 0
    if a.build:
        rc |= build(wd)
    if a.verify:
        rc |= verify(wd)
    if not (a.build or a.verify):
        ap.print_help()
    return rc


if __name__ == "__main__":
    sys.exit(main())
