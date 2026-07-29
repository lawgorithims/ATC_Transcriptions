#!/usr/bin/env python3
"""detect_neatline.py — find an FAA enroute chart's map panel, for charts with no published clip shape.

The FAA ships ENR_L clip shapes (jlmcgraw/aviationCharts) but NO ENR_H ones, so the IFR-high charts
were being built UNCUT: collar and all. That is not cosmetic. An enroute chart's collar is not a blank
margin, it is a legend panel — on ENR_H01 it is ~9% of a 24,000 px-wide chart — and in a mosaic that
panel is painted straight over the neighbouring chart's airways and fixes. Exactly the border problem
seen in the Caribbean set.

A chart panel is bounded by a NEATLINE: a solid rule running the full width/height of the map area.
It is the one feature in the image that is both very dark and nearly continuous, so it is found by
looking for rows/columns whose dark-pixel coverage is near-total, then taking the outermost such pair
on each axis.

FAIL-SAFE. Cropping the wrong rectangle would DELETE map data, which is far worse than keeping a
collar. So the window is accepted only when it is confidently a panel — a plausible share of the
image, positioned like a border — and otherwise the script exits non-zero and the caller builds uncut.

Usage:  detect_neatline.py <geotiff>          → "xoff yoff xsize ysize" on stdout, or exit 1
"""
import sys

try:
    from osgeo import gdal
    import numpy as np
except ImportError:                                             # pragma: no cover - env guard
    sys.stderr.write("detect_neatline: needs GDAL python bindings + numpy\n")
    sys.exit(2)

gdal.UseExceptions()

# A neatline rule is near-black and nearly continuous. These are deliberately strict: a missed
# detection costs a collar, a false one costs map data.
DARK = 128          # 0-255 grey below which a pixel counts as ink
COVERAGE = 0.80     # fraction of the span a rule must cover to be a neatline candidate
MIN_AREA = 0.35     # the panel must be at least this share of the sheet, else we are cropping junk
MAX_AREA = 0.999    # ...and if it is essentially the whole sheet there was nothing to cut
TARGET = 3000       # downsample width; the rule survives, the cost does not


def detect(path):
    ds = gdal.Open(path)
    W, H = ds.RasterXSize, ds.RasterYSize
    if W < 64 or H < 64:
        raise ValueError("raster too small to hold a panel")
    step = max(1, W // TARGET)
    w, h = max(1, W // step), max(1, H // step)
    arr = ds.ReadAsArray(buf_xsize=w, buf_ysize=h)
    if arr is None:
        raise ValueError("could not read raster")
    arr = np.asarray(arr)
    gray = arr.mean(axis=0) if arr.ndim == 3 else arr.astype(float)
    dark = gray < DARK

    def rules(frac):
        """Indices whose coverage clears the threshold, collapsed to one index per contiguous run —
        a 2 px-wide rule is one line, not two."""
        idx = np.where(frac > COVERAGE)[0]
        out, prev = [], None
        for i in idx:
            if prev is None or i - prev > 2:
                out.append(int(i))
            prev = i
        return out

    rows, cols = rules(dark.mean(axis=1)), rules(dark.mean(axis=0))
    if len(rows) < 2 or len(cols) < 2:
        raise ValueError(f"no bounding rules found (rows={len(rows)}, cols={len(cols)})")

    # Outermost pair on each axis = the panel border.
    top, bottom, left, right = rows[0], rows[-1], cols[0], cols[-1]
    if bottom - top < 2 or right - left < 2:
        raise ValueError("degenerate panel")

    # Back to full resolution, INSIDE the rule so the printed line itself is not kept.
    x0, x1 = (left + 1) * step, (right) * step
    y0, y1 = (top + 1) * step, (bottom) * step
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(W, x1), min(H, y1)
    xs, ys = x1 - x0, y1 - y0
    if xs <= 0 or ys <= 0:
        raise ValueError("empty window")

    share = (xs * ys) / float(W * H)
    if share < MIN_AREA:
        raise ValueError(f"panel is only {share:.1%} of the sheet — refusing to crop map data")
    if share > MAX_AREA:
        raise ValueError("panel is the whole sheet — nothing to cut")
    return x0, y0, xs, ys, share


def main():
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    try:
        x0, y0, xs, ys, share = detect(sys.argv[1])
    except Exception as e:                                      # any failure → caller builds uncut
        sys.stderr.write(f"detect_neatline: {e}\n")
        return 1
    sys.stderr.write(f"detect_neatline: panel {xs}x{ys} at ({x0},{y0}) = {share:.1%} of sheet\n")
    print(f"{x0} {y0} {xs} {ys}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
