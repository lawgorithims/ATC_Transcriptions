#!/usr/bin/env python3
"""build_terrain_grid.py — build CommSight's bundled terrain-elevation grid for the AGL readout.

WHAT IT MAKES
    Resources/terrain/terrain_conus.bin  — a raw little-endian int16 grid of terrain elevation in
                                           METRES, row-major, north-to-south, west-to-east.
    Resources/terrain/terrain_conus.json — the header (bounds, cell size, rows/cols, provenance).

WHY THIS SHAPE
    The app mmaps the .bin (`Data(contentsOf:options:.mappedIfSafe)`), so a ~11 MB grid costs no
    resident memory and a lookup is one index computation — no decoder, no tile cache, no network.

SOURCE
    AWS Open Data "terrain-tiles" (s3://elevation-tiles-prod), Terrarium PNG encoding, zoom 8
    (~600 m/px at the equator). That bucket is public-domain US federal data (SRTM/NASADEM/3DEP/
    GMTED2010) — free, no key, redistributable. Terrarium decode: h = R*256 + G + B/256 - 32768.

TWO DECISIONS THAT MATTER FOR SAFETY
    1. VERTICAL DATUM. CLLocation.altitude is an ORTHOMETRIC height (Core Location approximates MSL
       with the EGM2008 geoid). The source DEMs here are geoid-referenced too (SRTM/NASADEM = EGM96,
       3DEP = NAVD88), and those agree with EGM2008 to well under a metre across CONUS. So
       AGL = CLLocation.altitude - grid, with NO geoid model shipped. Never pair the grid with
       `ellipsoidalAltitude`: the geoid undulation across CONUS runs -17 m (Denver) to -35 m (LA),
       and getting it backwards silently OVERSTATES clearance by that much.
    2. MAX AGGREGATION, not mean. Each output cell takes the HIGHEST source sample inside it, so a
       peak inside a cell is never averaged away. AGL therefore errs LOW — "you are closer to the
       ground than this says" — which is the only safe direction to be wrong in. (It is also why the
       reader does nearest-cell lookup rather than bilinear: interpolating maxima is meaningless.)

    The source is a SURFACE model (trees and buildings are included), so terrain reads high over
    forest and cities. Combined with MAX aggregation the product is deliberately conservative. It is
    an advisory situational readout — NOT a terrain-avoidance database, and not DO-276 anything.

USAGE
    python3 Tools/build_terrain_grid.py                 # full CONUS build (~550 tiles, a few minutes)
    python3 Tools/build_terrain_grid.py --zoom 7        # coarser/faster smoke build
"""

import argparse
import concurrent.futures as futures
import json
import math
import os
import struct
import sys
import urllib.error
import urllib.request
import zlib

# CONUS + a margin for the border areas a US EFB actually flies in.
LAT_MIN, LAT_MAX = 24.0, 50.0
LON_MIN, LON_MAX = -125.0, -66.0
CELLS_PER_DEG = 60                      # 1 arc-minute output cells (~1.85 km)
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
NO_DATA = -32768                        # int16 sentinel for "no coverage"
SPIKE_M = 600                           # a cell this far above its SECOND-highest neighbour is an artifact
                                        # MEASURED, not guessed: at 300 the second-highest rule despikes the
                                        # Grand Teton in the BASE grid (3362 -> 2981 m) — a real peak whose
                                        # z8 cone is already smoothed away. 600 leaves all twelve surveyed
                                        # peaks untouched and still removes genuine adjacent-pair artifacts.
SPIKE_PASSES = 3                        # artifacts come in runs; each pass isolates the next survivor
# "Implausible" is MULTIPLICATIVE, not additive. Real relief is continuous: a summit stands proportionally
# above the country it belongs to, so 3x its neighbourhood is enormous in the mountains (Whitney would need
# 12,400 m) and tight on a barrier island (25 m country allows 115 m). Fixed thresholds cannot do both —
# tuned low enough to catch a 289 m "hill" on Martha's Vineyard they start deleting real coastal summits.
# MEASURED against fifteen real peaks including the hardest cases — Cadillac Mountain (456 m rising almost
# from the water), Mt Tamalpais, Mt Diablo, Bear Butte and Devils Tower — this flags NONE of them, and none
# of their neighbours, while removing the gross highs in flat country.
ARTIFACT_CONTEXT_MULTIPLE = 3.0
ARTIFACT_CONTEXT_FLOOR_M = 40           # ...so a near-zero neighbourhood still allows a real dune or bluff
MAX_TILE_RETRIES = 3

try:
    import numpy as np
except ImportError:
    sys.exit("numpy is required: use one of the repo venvs, e.g. ~/CommSight/train-venv/bin/python3")


# ---------------------------------------------------------------- PNG (stdlib only)

def decode_png_rgb(blob):
    """Decode an 8-bit non-interlaced RGB/RGBA PNG to a (h, w, 3) uint8 array.

    Deliberately dependency-free (Pillow is not installed in the repo venvs). Only the subset the
    AWS terrarium tiles actually use is supported; anything else raises rather than guessing.
    """
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    width = height = None
    bitdepth = colortype = interlace = None
    idat = bytearray()
    pos = 8
    while pos < len(blob):
        (length,) = struct.unpack(">I", blob[pos:pos + 4])
        ctype = blob[pos + 4:pos + 8]
        data = blob[pos + 8:pos + 8 + length]
        pos += 12 + length                      # length + type + data + crc
        if ctype == b"IHDR":
            width, height, bitdepth, colortype, _, _, interlace = struct.unpack(">IIBBBBB", data)
        elif ctype == b"IDAT":
            idat += data
        elif ctype == b"IEND":
            break
    if bitdepth != 8 or colortype not in (2, 6) or interlace != 0:
        raise ValueError(f"unsupported PNG (depth={bitdepth} color={colortype} interlace={interlace})")

    channels = 3 if colortype == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = np.empty((height, stride), dtype=np.uint8)
    prev = np.zeros(stride, dtype=np.uint8)
    src = 0
    for row in range(height):                                   # bounded by the image height
        ftype = raw[src]
        src += 1
        line = np.frombuffer(raw[src:src + stride], dtype=np.uint8).copy()
        src += stride
        if ftype == 0:
            cur = line
        elif ftype == 1:                                        # Sub
            cur = line
            for i in range(channels, stride):
                cur[i] = (int(cur[i]) + int(cur[i - channels])) & 0xFF
        elif ftype == 2:                                        # Up
            cur = (line.astype(np.uint16) + prev.astype(np.uint16)).astype(np.uint8)
        elif ftype == 3:                                        # Average
            cur = line
            for i in range(stride):
                left = int(cur[i - channels]) if i >= channels else 0
                cur[i] = (int(cur[i]) + ((left + int(prev[i])) >> 1)) & 0xFF
        elif ftype == 4:                                        # Paeth
            cur = line
            for i in range(stride):
                a = int(cur[i - channels]) if i >= channels else 0
                b = int(prev[i])
                c = int(prev[i - channels]) if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (int(cur[i]) + pred) & 0xFF
        else:
            raise ValueError(f"bad PNG filter {ftype}")
        out[row] = cur
        prev = cur
    return out.reshape(height, width, channels)[:, :, :3]


# ---------------------------------------------------------------- tiles / geo

def tile_range(zoom):
    """Web-Mercator tile indices covering the CONUS bbox at `zoom`."""
    n = 2 ** zoom

    def xtile(lon):
        return int((lon + 180.0) / 360.0 * n)

    def ytile(lat):
        r = math.radians(lat)
        return int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * n)

    return (xtile(LON_MIN), xtile(LON_MAX), ytile(LAT_MAX), ytile(LAT_MIN))


def tile_pixel_latlon(zoom, x, y, size):
    """Per-pixel lat/lon centres of one tile (arrays of length `size`)."""
    n = 2.0 ** zoom
    px = np.arange(size) + 0.5
    lon = (x + px / size) / n * 360.0 - 180.0
    ty = (y + px / size) / n
    lat = np.degrees(np.arctan(np.sinh(np.pi * (1.0 - 2.0 * ty))))
    return lat, lon


def fetch(url):
    last = None
    for _ in range(MAX_TILE_RETRIES):                            # bounded retries
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = e
    raise RuntimeError(f"failed after {MAX_TILE_RETRIES} tries: {url} ({last})")


# ---------------------------------------------------------------- build

def clean(grid):
    """Two corrections the raw source needs before it can be flown with. Returns (grid, stats).

    1. BATHYMETRY -> SEA LEVEL. The terrain tiles carry ocean/lake depth, not just land: ~23% of the
       CONUS bbox came back below -200 m (the Atlantic and Pacific floors, down to -5900 m). AGL over
       water must be measured from the WATER SURFACE, so every cell that is still below sea level after
       max-aggregation is clamped to 0. A coastal cell keeps its land height because the max already
       picked the land sample. Two consequences worth knowing: genuine below-sea-level land (Death
       Valley -86 m, the Salton Sea) is clamped to 0, which makes AGL read ~280 ft LOW there — the safe
       direction; and over a deep inland lake (Lake Superior's floor is below sea level while its
       SURFACE is at 183 m) the reading is relative to sea level rather than the lake surface, which is
       the one place this grid is optimistic. The readout is advisory and the UI says so.

    2. ISOLATED SPIKES. The source has rare single-pixel artifacts from SRTM void fill — verified one
       at 43.19N 109.12W reading 6512 m with all eight neighbours between 1375 and 2234 m (Gannett
       Peak, the highest ground for hundreds of miles, is 4207 m). Max-aggregation propagates such a
       spike straight into the output cell, and a spike reads terrain HIGH, which makes AGL read LOW —
       a false "you are about to hit the ground".

       The test is against the neighbour MAXIMUM, not the median, and that choice is deliberate. A
       median test flags any cell that stands well above its surroundings — which is the definition of
       a SUMMIT, and on a 1 arc-minute grid a real peak routinely sits 300 m above the median of its
       neighbours. Deleting a real peak makes terrain read LOW and AGL read HIGH: it would overstate
       clearance over exactly the mountains where clearance matters. A genuine summit always has at
       least one high neighbour (mountains come in ranges); an interpolation artifact does not. So a
       cell is only replaced when it towers over its HIGHEST neighbour, and it is replaced by that
       neighbour max rather than the median — still the highest defensible value for the cell.
    """
    # `where=` is load-bearing. The accumulator is SEEDED with NO_DATA (-32768), so an unmasked
    # clamp would rewrite every un-fetched cell to 0 — bit-identical to sea level. A tile that failed
    # to download over Colorado would then read as sea level, and the app would hand the pilot their
    # entire MSL altitude as clearance, at full confidence, with no way to tell it was a hole. The
    # sentinel must survive the clamp so the reader can refuse those cells.
    below = int(((grid < 0) & (grid != NO_DATA)).sum())
    np.maximum(grid, 0, out=grid, where=(grid != NO_DATA))

    # RANK AGAINST THE SECOND-HIGHEST NEIGHBOUR, NOT THE MAXIMUM, AND ITERATE.
    #
    # Source artifacts do not arrive alone — they come in adjacent runs — and against the 8-neighbour MAX
    # each member of a pair is protected by its partner: `grid > nmax + SPIKE_M` is false for both, so
    # neither is ever despiked. Measured on the shipped grid, 278 cells sat >=300 m above the 90th
    # percentile of their ~11 NM neighbourhood while that neighbourhood was below 600 m — gross highs in
    # flat country, worst 2,026 m in the mouth of the Columbia, with 21 operational airports inside
    # 2.5 NM of one. The consequence is not cosmetic: NearestAirports sweeps this grid, so a phantom
    # 1,558 ft cell south of KACK (true ground ~100 ft) turns the only airport on Nantucket into a hard
    # `.blocked` verdict on an offshore engine failure, and TerrainElevation reports the same cells as
    # AGL over open water.
    #
    # The second-highest neighbour is the right discriminator because it encodes the file's own doctrine
    # — mountains come in ranges. A genuine summit has a CONE: several high neighbours, so its second-
    # highest is high too and it survives. An artifact pair has exactly one high neighbour, so its
    # second-highest is the true low ground around it. Iterating matters because the survivor of a pair
    # only becomes isolated once its partner has been replaced.
    #
    # A median test was measured and rejected: real sharp peaks sit far above their neighbour median
    # (Mt Hood +709 m, Grand Teton +630 m, Mt Shasta +515 m), so any threshold catching Nantucket
    # (+454 m) also deletes real mountains. The safe discriminator is the shape of the neighbourhood,
    # not the size of the excess.
    n_spikes = 0
    for _ in range(SPIKE_PASSES):                             # bounded (rule 2)
        filled = np.where(grid == NO_DATA, 0, grid).astype(np.int32)   # sentinel must not skew the neighbourhood
        pad = np.pad(filled, 1, mode="edge")
        stack = np.stack([pad[dy:dy + grid.shape[0], dx:dx + grid.shape[1]]
                          for dy in range(3) for dx in range(3)
                          if not (dy == 1 and dx == 1)])      # the 8 neighbours, bounded and explicit
        second = np.sort(stack, axis=0)[-2]                   # second-highest of the 8
        spikes = (grid > (second + SPIKE_M)) & (grid != NO_DATA)
        if not spikes.any():
            break
        n_spikes += int(spikes.sum())
        grid[spikes] = second[spikes].astype(np.int16)
    # SECOND RULE: A MOUNTAIN IN THE SEA IS NOT A MOUNTAIN.
    #
    # The neighbour test above cannot catch an artifact CLUSTER — three or more bad cells shield each
    # other however you rank them — and raising SPIKE_M far enough to matter starts deleting real peaks.
    # Nantucket is the case that proves it: 475 m of "terrain" on an island whose true high ground is
    # about 35 m, sitting in a neighbourhood whose 90th percentile is 25 m. NRST sweeps this grid, so
    # that cell is a hard BLOCKED verdict on the only airport within glide of an offshore engine failure.
    #
    # Context separates it cleanly where excess alone cannot — see the constants for why the test is a
    # MULTIPLE of the neighbourhood rather than a fixed rise.
    #
    # Replaced with the neighbourhood's own 90th percentile — the surrounding country — never with zero.
    ctx_pad = np.pad(np.where(grid == NO_DATA, 0, grid).astype(np.int32), 5, mode="edge")
    win = np.lib.stride_tricks.sliding_window_view(ctx_pad, (11, 11))
    p90 = np.percentile(win, 90, axis=(2, 3))
    sea = (grid > p90 * ARTIFACT_CONTEXT_MULTIPLE + ARTIFACT_CONTEXT_FLOOR_M) & (grid != NO_DATA)
    n_sea = int(sea.sum())
    grid[sea] = p90[sea].astype(np.int16)

    return grid, {"clampedBelowSeaLevel": below, "despiked": n_spikes,
                  "seaLevelArtifacts": n_sea,
                  "noDataCells": int((grid == NO_DATA).sum())}


# ---------------------------------------------------------------- summit refinement

REFINE_ZOOM = 13                 # near-native source resolution (~19 m posting) — peaks still sharp here
REFINE_WINDOW = 7                # a cell that is the highest within +/-3 cells (~13 km) is a candidate summit
REFINE_THRESHOLD_M = 2000        # only genuine high summits — where the coarse pyramid smooths hundreds of feet
MAX_REFINE_TILES = 8_000         # bound the work (rule 2)
# The highest ground in CONUS is Mt Whitney at 4421 m. A zoom-13 source pixel above this ceiling is a
# corrupt / no-data value (a stray white pixel decodes to ~32767 m under the Terrarium formula), and
# because refinement MAXES into the grid, one such pixel would poison a cell in the unsafe direction
# (terrain too high -> AGL too low -> a false "you are at the ground"). The base build's despike runs
# BEFORE refinement, so refinement must reject these itself.
# THE CONUS CEILING. Mount Whitney is 4,421 m and nothing in the lower 48 is higher, so a refined pixel
# above this is a source artifact by definition — there is no terrain it could be. 4,600 was too generous
# and let a 4,570 m cell into the Sangre de Cristos, which `testNoCellExceedsConusCeiling` then caught.
# The margin over Whitney is for the surface model (snowpack, a summit structure), not for doubt.
MAX_PLAUSIBLE_M = 4425


def refine_summits(grid, workers):
    """Recover true summit heights the coarse base pass smoothed away.

    WHY THIS EXISTS. The base grid is max-aggregated from zoom-8/9 source tiles, but the AWS tile
    PYRAMID is built by AVERAGING downsampling, so a sharp peak is already blurred DOWN before this
    script ever sees it. Measured: Grand Teton's summit pixel reads 3905 m at zoom 9 (965 ft below its
    true 4199 m) but 4194 m at zoom 13. Max-aggregating a smoothed value cannot recover what smoothing
    removed — which is why "look at neighbouring cells" does NOT help (they were smoothed too). The only
    fix is to re-read the peak from a zoom where it is still sharp.

    Doing that for ALL high terrain would be ~74k tiles; but the severe under-read is only at genuine
    SUMMITS, which are local maxima. This finds them (highest cell within a ~13 km window, above
    REFINE_THRESHOLD_M), fetches the zoom-13 tile for each, and maxes its fine pixels back into the
    grid. That is a few thousand tiles, and it errs the safe way: it can only RAISE terrain, so AGL can
    only move DOWN ("you are closer to the ground"), never up.

    Runs AFTER clean(): the recovered summits are real high-resolution data, so they must not be seen by
    the despike pass (a genuine isolated peak looks exactly like the artifact despike removes).
    """
    from scipy.ndimage import maximum_filter                       # train-venv only; build-time dep
    n = 2 ** REFINE_ZOOM
    peak = (grid == maximum_filter(grid, size=REFINE_WINDOW, mode="nearest")) & (grid >= REFINE_THRESHOLD_M)
    rs, cs = np.where(peak)
    tiles = set()
    for r, c in zip(rs, cs):                                        # bounded by the CONUS grid
        lat = LAT_MAX - (r + 0.5) / CELLS_PER_DEG
        lon = LON_MIN + (c + 0.5) / CELLS_PER_DEG
        x = int((lon + 180.0) / 360.0 * n)
        y = int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)
        tiles.add((x, y))
    tiles = list(tiles)[:MAX_REFINE_TILES]
    print(f"summit refinement: {len(rs)} summit cells -> {len(tiles)} zoom-{REFINE_ZOOM} tiles", flush=True)

    rows, cols = grid.shape
    pre_refine = grid.copy()                                # to revert anything refinement invents
    flat = grid.reshape(-1)
    done = raised = 0
    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        jobs = {pool.submit(fetch, TILE_URL.format(z=REFINE_ZOOM, x=x, y=y)): (x, y) for x, y in tiles}
        for fut in futures.as_completed(jobs):
            x, y = jobs[fut]; done += 1
            try:
                rgb = decode_png_rgb(fut.result())
            except Exception as e:
                print(f"  skip {x},{y}: {e}", flush=True); continue
            size = rgb.shape[0]
            elev = (rgb[:, :, 0].astype(np.float64) * 256.0 + rgb[:, :, 1].astype(np.float64)
                    + rgb[:, :, 2].astype(np.float64) / 256.0) - 32768.0
            lat, lon = tile_pixel_latlon(REFINE_ZOOM, x, y, size)
            ri = np.floor((LAT_MAX - lat) * CELLS_PER_DEG).astype(np.int64)
            ci = np.floor((lon - LON_MIN) * CELLS_PER_DEG).astype(np.int64)
            rok = (ri >= 0) & (ri < rows); cok = (ci >= 0) & (ci < cols)
            if not rok.any() or not cok.any():
                continue
            sub = elev[np.ix_(rok, cok)]
            idx = (ri[rok][:, None] * cols + ci[cok][None, :]).ravel()
            vals = np.rint(sub).ravel()
            # Reject corrupt / no-data pixels BEFORE maxing in — one 32767 m pixel would poison a cell in
            # the unsafe direction. (Keep them as float until after the mask so the compare is exact.)
            keep = vals <= MAX_PLAUSIBLE_M
            idx = idx[keep]; vals = vals[keep].astype(np.int16)
            before = flat[idx].copy()
            np.maximum.at(flat, idx, vals)                          # RAISE only — never lowers terrain
            raised += int((flat[idx] > before).sum())
            if done % 200 == 0:
                print(f"  {done}/{len(tiles)}", flush=True)
    reverted = _revert_implausible_refinements(grid, pre_refine)
    # THE CONUS CEILING, ENFORCED AFTER REFINEMENT TOO. `MAX_PLAUSIBLE_M` filters individual zoom-13
    # PIXELS, but the grid cell takes their maximum, and a cell can still finish above the ceiling if the
    # tile is mis-indexed. Nothing in the lower 48 is higher than Whitney, so this is a physical bound,
    # not a heuristic — and `testNoCellExceedsConusCeiling` asserts it on the shipped file.
    over = grid > MAX_PLAUSIBLE_M
    n_over = int(over.sum())
    if n_over:
        grid[over] = np.int16(MAX_PLAUSIBLE_M)
        print(f"  clamped {n_over} cell(s) above the CONUS ceiling", flush=True)
    return grid, {"summitCellsFound": int(len(rs)), "refineTiles": len(tiles),
                  "cellsRaised": raised, "refineZoom": REFINE_ZOOM,
                  "implausibleReverted": reverted, "aboveConusCeiling": n_over}


# A refined cell this far above the 90th percentile of its ~11 NM neighbourhood, while that
# neighbourhood is itself low country, is not a summit — it is an injected artifact.
ARTIFACT_EXCESS_M = 500
ARTIFACT_CONTEXT_M = 600


def _revert_implausible_refinements(grid, before):
    """Undo refinements that INVENTED terrain instead of sharpening it.

    THIS IS WHERE THE SHIPPED GRID'S ARTIFACTS CAME FROM. Measured on a raw zoom-8 capture with despiking
    disabled, the mouth of the Columbia reads 193 m; in the shipped grid it reads 2,026 m. The base pass
    was never the culprit — refinement was. It maxes a whole zoom-13 tile's pixels into the coarse cells
    they fall in, so wherever a summit CANDIDATE sits in flat country (and in flat country a local maximum
    is mostly noise) a tall feature elsewhere under that tile can be written into it.

    The guard is the definition of the job: refinement exists to recover a peak that is ALREADY the local
    maximum, blurred down by the pyramid's averaging. It is not entitled to create a mountain where the
    surrounding country has none. A cell that ends up grossly above a LOW neighbourhood is reverted to its
    pre-refinement value — never below it, so this can only give back what refinement added and can never
    under-read the base.

    NRST sweeps this grid, so an invented 1,558 ft cell beside a sea-level island field is a hard BLOCKED
    verdict on the only airport within glide of an offshore engine failure.
    """
    changed = np.where(grid != before)
    if len(changed[0]) == 0:
        return 0
    step = 3                                                # sample the neighbourhood, not every cell
    sub = grid[::step, ::step]
    pad = np.pad(sub, 5, mode="edge")
    win = np.lib.stride_tricks.sliding_window_view(pad, (11, 11))
    p90 = np.percentile(win, 90, axis=(2, 3))
    rr = np.clip(changed[0] // step, 0, p90.shape[0] - 1)
    cc = np.clip(changed[1] // step, 0, p90.shape[1] - 1)
    context = p90[rr, cc]
    bad = (grid[changed] >= context + ARTIFACT_EXCESS_M) & (context < ARTIFACT_CONTEXT_M)
    n = int(bad.sum())
    if n:
        grid[changed[0][bad], changed[1][bad]] = before[changed[0][bad], changed[1][bad]]
    print(f"  reverted {n} implausible refinements (gross highs in low country)", flush=True)
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zoom", type=int, default=8)
    ap.add_argument("--out", default=None)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--clean-only", action="store_true",
                    help="re-run the cleanup pass over an existing .bin (no downloads)")
    ap.add_argument("--refine-only", action="store_true",
                    help="fetch zoom-13 summit tiles and max them into an existing .bin (no base rebuild)")
    args = ap.parse_args()

    if args.refine_only:
        here = os.path.dirname(os.path.abspath(__file__))
        outdir = args.out or os.path.join(here, "..", "ATCTranscribe", "Resources", "terrain")
        hdr = json.load(open(os.path.join(outdir, "terrain_conus.json")))
        binpath = os.path.join(outdir, "terrain_conus.bin")
        grid = np.fromfile(binpath, dtype="<i2").reshape(hdr["rows"], hdr["cols"])
        grid, stats = refine_summits(grid, args.workers)
        grid.astype("<i2").tofile(binpath)
        hdr["summitRefinement"] = stats
        hdr["maxPlausibleM"] = MAX_PLAUSIBLE_M
        json.dump(hdr, open(os.path.join(outdir, "terrain_conus.json"), "w"), indent=2)
        print(f"refined: {stats}; min {int(grid.min())} max {int(grid.max())}")
        return

    if args.clean_only:
        here = os.path.dirname(os.path.abspath(__file__))
        outdir = args.out or os.path.join(here, "..", "ATCTranscribe", "Resources", "terrain")
        hdr = json.load(open(os.path.join(outdir, "terrain_conus.json")))
        # ORDER IS LOAD-BEARING NOW. In the full pipeline clean() runs BEFORE refine_summits, while a real
        # peak still has the smoothed cone that gives it a high SECOND-highest neighbour. Run on an
        # ALREADY-REFINED grid the same test eats those summits — refinement raises the summit cell and
        # leaves its neighbours smoothed, which is exactly the isolated-high shape this now removes. That
        # would lower real terrain and raise reported AGL: the unsafe direction. Refuse instead.
        if "summitRefinement" in hdr:
            sys.exit("--clean-only on a refined grid would re-smooth the recovered summits; "
                     "rebuild from --zoom instead")
        binpath = os.path.join(outdir, "terrain_conus.bin")
        grid = np.fromfile(binpath, dtype="<i2").reshape(hdr["rows"], hdr["cols"])
        grid, stats = clean(grid)
        grid.astype("<i2").tofile(binpath)
        hdr["cleanup"] = stats
        hdr["seaLevelClamp"] = True
        hdr["spikeThresholdM"] = SPIKE_M
        json.dump(hdr, open(os.path.join(outdir, "terrain_conus.json"), "w"), indent=2)
        print(f"cleaned: {stats}; min {int(grid.min())} max {int(grid.max())}")
        return

    here = os.path.dirname(os.path.abspath(__file__))
    outdir = args.out or os.path.join(here, "..", "ATCTranscribe", "Resources", "terrain")
    os.makedirs(outdir, exist_ok=True)

    rows = int(round((LAT_MAX - LAT_MIN) * CELLS_PER_DEG))
    cols = int(round((LON_MAX - LON_MIN) * CELLS_PER_DEG))
    grid = np.full((rows, cols), NO_DATA, dtype=np.int16)        # MAX-accumulator, seeded at no-data

    x0, x1, y0, y1 = tile_range(args.zoom)
    coords = [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    print(f"zoom {args.zoom}: {len(coords)} tiles -> grid {rows}x{cols} "
          f"({rows * cols * 2 / 1e6:.1f} MB)", flush=True)

    done = 0
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {pool.submit(fetch, TILE_URL.format(z=args.zoom, x=x, y=y)): (x, y) for x, y in coords}
        for fut in futures.as_completed(jobs):
            x, y = jobs[fut]
            done += 1
            try:
                rgb = decode_png_rgb(fut.result())
            except Exception as e:                               # a missing/corrupt tile is not fatal
                print(f"  skip {x},{y}: {e}", flush=True)
                continue

            size = rgb.shape[0]
            elev = (rgb[:, :, 0].astype(np.float64) * 256.0
                    + rgb[:, :, 1].astype(np.float64)
                    + rgb[:, :, 2].astype(np.float64) / 256.0) - 32768.0

            lat, lon = tile_pixel_latlon(args.zoom, x, y, size)
            ri = np.floor((LAT_MAX - lat) * CELLS_PER_DEG).astype(np.int64)
            ci = np.floor((lon - LON_MIN) * CELLS_PER_DEG).astype(np.int64)
            rok = (ri >= 0) & (ri < rows)
            cok = (ci >= 0) & (ci < cols)
            if not rok.any() or not cok.any():
                continue
            sub = elev[np.ix_(rok, cok)]
            rr = ri[rok]
            cc = ci[cok]
            flat = (rr[:, None] * cols + cc[None, :]).ravel()
            vals = np.rint(sub).astype(np.int16).ravel()
            # MAX into the accumulator — a peak inside a cell must never be averaged away.
            np.maximum.at(grid.reshape(-1), flat, vals)
            if done % 50 == 0:
                print(f"  {done}/{len(coords)}", flush=True)

    covered = int((grid != NO_DATA).sum())
    grid, stats = clean(grid)
    binpath = os.path.join(outdir, "terrain_conus.bin")
    with open(binpath, "wb") as f:
        f.write(grid.astype("<i2").tobytes())
    header = {
        "version": 1,
        "latMax": LAT_MAX, "latMin": LAT_MIN, "lonMin": LON_MIN, "lonMax": LON_MAX,
        "rows": rows, "cols": cols, "cellsPerDegree": CELLS_PER_DEG,
        "noData": NO_DATA, "units": "metres", "datum": "orthometric (EGM96/NAVD88 ~ EGM2008)",
        "aggregation": "max", "sourceZoom": args.zoom,
        "source": "AWS Open Data terrain-tiles (s3://elevation-tiles-prod), Terrarium PNG; "
                  "public-domain SRTM/NASADEM/3DEP/GMTED2010",
        "advisory": "Surface model (includes vegetation/buildings), max-aggregated. Situational "
                    "awareness only — NOT a terrain-avoidance database.",
        "seaLevelClamp": True, "spikeThresholdM": SPIKE_M, "cleanup": stats,
        "artifactContextMultiple": ARTIFACT_CONTEXT_MULTIPLE,
        "artifactContextFloorM": ARTIFACT_CONTEXT_FLOOR_M,
        "maxPlausibleM": MAX_PLAUSIBLE_M,
    }
    with open(os.path.join(outdir, "terrain_conus.json"), "w") as f:
        json.dump(header, f, indent=2)

    print(f"wrote {binpath} ({os.path.getsize(binpath) / 1e6:.1f} MB), "
          f"{covered}/{rows * cols} cells covered ({100.0 * covered / (rows * cols):.1f}%)")


if __name__ == "__main__":
    main()
