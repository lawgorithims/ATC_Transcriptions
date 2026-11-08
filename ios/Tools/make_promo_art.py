#!/usr/bin/env python3
"""App Store promotional artwork — the header and search-results assets.

These are NOT screenshots, and that is the whole constraint. Apple's featuring artwork
gets the app name and its own editorial text laid over it, is cropped to several aspect
ratios, and is rejected when it carries a device frame, a wordmark, a tagline or a picture
of the UI. So this draws brand artwork instead: the obelisk mark in white on the same pure
black as the app icon, standing at the centre of a set of glide rings.

Nothing here contains text, by design. There is nowhere to put it that Apple will not
cover, and a tagline in the artwork is a rejection.

Run it with the venv that carries Pillow:

    ~/CommSight/plate-georef-venv/bin/python3 Tools/make_promo_art.py

Sizes come from App Store Connect's own list. 5244x2950 is accepted for both placements;
the rest are the alternates it offers, generated so there is no scramble if it asks for a
different one.
"""
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
OUT_DIR = os.path.join(IOS, "docs/appstore/promo")

# The same source `make_icon.py` uses, and it has to stay that way: `obelisk-mark-black.svg`
# is the shaft ALONE, while this one carries the stepped plinth under it. Promotional art
# showing a different silhouette from the app icon beside it is worse than no art.
DEFAULT_SVG = os.path.expanduser(
    "~/CommSight/website/public/brand/obelisk-black.svg")
RENDER_AT = 3072          # render large, downscale once — keeps the diagonals clean
BG = (0, 0, 0)            # the icon's own black, not a near-black

# (filename, width, height, how tall the mark stands relative to the canvas)
#
# The search-results mark is drawn larger than the header's: that asset is seen small, so
# the silhouette has to survive being scaled down, while the header has room to breathe.
TARGETS = [
    ("header-5244x2950.png", 5244, 2950, 0.56),
    ("header-3840x1646.png", 3840, 1646, 0.62),
    ("search-5244x2950.png", 5244, 2950, 0.64),
    ("search-3840x2560.png", 3840, 2560, 0.60),
    ("search-1920x1280.png", 1920, 1280, 0.60),
]

svg = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SVG
if not os.path.exists(svg):
    sys.exit(f"source not found: {svg}")


def mark_mask() -> Image.Image:
    """The obelisk as a coverage mask: 255 where the mark is, 0 where the canvas shows."""
    tmp = tempfile.mkdtemp()
    subprocess.run(["qlmanage", "-t", "-s", str(RENDER_AT), "-o", tmp, svg],
                   check=True, capture_output=True)
    hits = [f for f in os.listdir(tmp) if f.endswith(".png")]
    if not hits:
        sys.exit("qlmanage produced no PNG — is the source a readable SVG?")

    im = Image.open(os.path.join(tmp, hits[0]))
    if im.mode in ("RGBA", "LA"):             # flatten onto white so the ink stays dark
        flat = Image.new("RGB", im.size, (255, 255, 255))
        flat.paste(im, mask=im.split()[-1])
        im = flat
    gray = im.convert("L")

    bbox = gray.point(lambda p: 255 if p < 128 else 0).getbbox()
    if not bbox:
        sys.exit("no ink found in the rendered source")
    return ImageOps.invert(gray.crop(bbox))


def vignette(w: int, h: int) -> Image.Image:
    """A barely-there lift at the centre, so a flat black field still has a middle.

    Built small and scaled up: a radial gradient computed per pixel at 5244 wide is slow
    for no benefit, since the thing is almost invisible on purpose.
    """
    small = 96
    g = Image.new("L", (small, small), 0)
    px = g.load()
    mid = (small - 1) / 2
    for y in range(small):
        for x in range(small):
            d = math.hypot((x - mid) / mid, (y - mid) / mid)
            px[x, y] = max(0, round(14 * (1.0 - min(1.0, d) ** 1.6)))
    return g.resize((w, h), Image.BICUBIC)


def compose(w: int, h: int, height_ratio: float, mask: Image.Image) -> Image.Image:
    canvas = Image.new("RGB", (w, h), BG)

    # Centre lift first, so everything else sits on top of it.
    canvas.paste((255, 255, 255), (0, 0), vignette(w, h))

    target_h = round(h * height_ratio)
    target_w = max(1, round(mask.width * target_h / mask.height))
    m = mask.resize((target_w, target_h), Image.LANCZOS)

    cx = w // 2
    base_y = round(h * 0.78)            # where the obelisk stands; rings radiate from here
    top = base_y - target_h

    # Glide rings, centred on the base. Thin, dim, and spaced so the outer ones fall off
    # the edge of the wider crops rather than ending in a visible circle.
    rings = Image.new("L", (w, h), 0)
    rd = ImageDraw.Draw(rings)
    unit = min(w, h)
    lw = max(2, round(unit / 760))
    for i in range(1, 7):
        r = unit * 0.17 * i
        rd.ellipse([cx - r, base_y - r, cx + r, base_y + r],
                   outline=max(3, round(20 - i * 2.4)), width=lw)

    # A compass tick ring: an aviation cue that stays abstract, and the one element that
    # gives the eye a scale. Every 10 degrees, longer every 30.
    tick_r = unit * 0.665
    for deg in range(0, 360, 10):
        a = math.radians(deg - 90)
        inner = tick_r - unit * (0.028 if deg % 30 == 0 else 0.014)
        rd.line([cx + inner * math.cos(a), base_y + inner * math.sin(a),
                 cx + tick_r * math.cos(a), base_y + tick_r * math.sin(a)],
                fill=30 if deg % 30 == 0 else 18, width=lw)

    canvas.paste((255, 255, 255), (0, 0), rings)

    # The mark last, in pure white, so no ring crosses it.
    canvas.paste((255, 255, 255), (cx - target_w // 2, top), m)
    return canvas


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    mask = mark_mask()
    print(f"mark rasterised at {mask.width}x{mask.height}")

    for name, w, h, ratio in TARGETS:
        img = compose(w, h, ratio, mask)
        assert img.size == (w, h), f"{name}: composed {img.size}, wanted {(w, h)}"
        assert img.mode == "RGB", f"{name}: mode {img.mode}, wanted RGB (no alpha)"
        path = os.path.join(OUT_DIR, name)
        img.save(path, "PNG", optimize=True)
        kb = os.path.getsize(path) / 1024
        print(f"  {name:<24} {w}x{h}  mark {ratio:.0%} h  {kb:,.0f} KB")


if __name__ == "__main__":
    main()
