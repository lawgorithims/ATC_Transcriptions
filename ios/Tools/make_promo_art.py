#!/usr/bin/env python3
"""App Store promotional artwork — the header and search-results assets.

WHAT CHANGED, AND WHY THE OLD VERSION WAS WRONG
-----------------------------------------------
This script used to draw the Obelisk mark in white on black. That was a mistake, and an
instructive one: it was written to satisfy "no device frame, no wordmark, no tagline" and
then put the one other prohibited thing in the middle of the frame. **App icons and logos
are on Apple's prohibited list for featuring artwork**, alongside taglines, URLs, pricing
and hardware. So the old asset was not merely weak marketing — a logo on black, which told
a browsing pilot nothing about the app — it was built out of the element most likely to get
it rejected.

What is allowed, and what actually sells an electronic flight bag, turn out to be the same
thing: the chart. This draws the app's own enroute render — the New York Class B shelves,
the airways through them, restricted areas and the ownship — with every piece of interface
chrome cropped away, then darkened so it reads as artwork rather than as a screenshot.

THE RULES THIS ENCODES
  - no logo or app icon            (prohibited, and what the old version got wrong)
  - no text of any kind            (Apple lays its own title and editorial copy over this)
  - no device frame or hardware    (prohibited)
  - focal point near the centre    (it is cropped to several aspect ratios)
  - calm, dark edges               (so Apple's overlaid white text stays legible)

TWO HONEST LIMITATIONS, both fixed the same way and not fixable here:

⚠️ THE SOURCE IS A 2x PORTRAIT iPAD CAPTURE. The crop is 1680 px across, so the 5244-wide
targets are upscaled about 3.1x and the chart linework is soft at full size. It survives
the darkening better than you would expect, but it is not a sharp asset.

⚠️ THE CHART BOUNDARY IS IN FRAME, bottom right: a dark wedge where the enroute raster ends
and the high-altitude layer shows through. It is real output, not a rendering fault, but it
reads as missing data. The crop is pulled left and the vignette crushes it, which reduces it
rather than removing it — at this zoom there is no rectangle of this capture that is both
big enough and clear of it.

BOTH want the same fix: a landscape capture pass. An iPad in landscape yields 2752 px across
instead of 2064, and a map zoomed one step in has no boundary in frame. That needs
`AppStoreScreenshotTests` taught to rotate and to shoot a chrome-free frame; until then this
is the best honest artwork from what exists.

Run it with the venv that carries Pillow:

    ~/CommSight/plate-georef-venv/bin/python3 Tools/make_promo_art.py

Sizes come from App Store Connect's own list. 5244x2950 is accepted for both placements;
the rest are the alternates it offers, generated so there is no scramble if it asks for a
different one.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
OUT_DIR = os.path.join(IOS, "docs/appstore/promo")

# The day enroute shot. The night plate-on-map frame was tried first and is worse for this:
# the plate is a near-white slab that lands dead centre, which is the one place Apple's white
# title text goes. This frame's interest is spread across it and darkens evenly.
SOURCE = os.path.join(IOS, "docs/appstore/iPad-Pro-13-inch-M5/01-map.png")
SOURCE_SIZE = (2064, 2752)          # asserted: a re-shot screenshot of another size would
                                    # silently move every crop boundary below

# The chrome-free rectangle of that capture, as (left, top, right, bottom).
#
# Every edge is a piece of interface, and each one is why that number is what it is:
#   left   0     nothing intrudes from the left below the GPS panel
#   top    1160  the GPS panel ends at y=1156; above this line it is in frame
#   right  1680  the NRST button and zoom stack live at x>=1954, but the crop stops well
#                short of them to leave the chart-boundary wedge mostly outside
#   bottom 2420  the GS/ALT data bar starts at y=2477, the tab bar below it
CROP = (0, 1160, 1680, 2420)

# Day charts are near-white, and this asset is a backdrop for someone else's white text.
# Darkening is what makes it a backdrop; the slight desaturation stops the airspace magenta
# from glowing once the luminance comes down.
BRIGHTNESS = 0.58
SATURATION = 0.82

# (filename, width, height, horizontal anchor, vertical anchor)
#
# Anchors are the fraction of the overspill taken off the top/left, so 0.0 keeps the top or
# left edge. Vertical leans high because the Class B shelves sit in the upper third of the
# crop; horizontal leans left because the chart boundary is on the right.
TARGETS = [
    ("header-5244x2950.png", 5244, 2950, 0.38, 0.20),
    ("header-3840x1646.png", 3840, 1646, 0.38, 0.16),
    ("search-5244x2950.png", 5244, 2950, 0.38, 0.20),
    ("search-3840x2560.png", 3840, 2560, 0.40, 0.22),
    ("search-1920x1280.png", 1920, 1280, 0.40, 0.22),
]


def source() -> Image.Image:
    if not os.path.exists(SOURCE):
        sys.exit(f"source not found: {SOURCE}\nRegenerate it with Tools/appstore_screenshots.sh")
    im = Image.open(SOURCE)
    assert im.size == SOURCE_SIZE, (
        f"source is {im.size}, expected {SOURCE_SIZE} — the CROP numbers are pixel "
        f"coordinates in that capture and mean nothing in another")
    return im.convert("RGB").crop(CROP)


def cover(im: Image.Image, w: int, h: int, hx: float, vy: float) -> Image.Image:
    """Scale to fill w x h without distortion, then take a window of it.

    Scale-to-COVER, never fit: a letterboxed bar would be a flat edge Apple's crop could
    land on, and a stretched chart is an immediately wrong-looking chart.
    """
    scale = max(w / im.width, h / im.height)
    sw, sh = max(w, round(im.width * scale)), max(h, round(im.height * scale))
    big = im.resize((sw, sh), Image.LANCZOS)
    left = round((sw - w) * min(1.0, max(0.0, hx)))
    top = round((sh - h) * min(1.0, max(0.0, vy)))
    return big.crop((left, top, left + w, top + h))


def settle(im: Image.Image, w: int, h: int) -> Image.Image:
    """Darken and calm the edges, leaving the middle alone.

    Two jobs, one gradient. Apple crops this to aspect ratios nobody here chose, so the
    frame has to fall away rather than end on something that looks cut; and it lays its
    own white title text over the result, which a bright chart corner would swallow.
    """
    small = 128
    g = Image.new("L", (small, small), 0)
    px = g.load()
    mx, my = (small - 1) / 2, (small - 1) / 2
    for y in range(small):                                # bounded: 128 rows
        for x in range(small):                            # bounded: 128 columns
            d = math.hypot((x - mx) / mx, (y - my) / my) / math.sqrt(2)
            px[x, y] = round(255 * min(1.0, max(0.0, (d - 0.34) / 0.66)) ** 1.25)
    mask = g.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(w / 220))

    out = im.copy()
    out.paste(Image.new("RGB", (w, h), (0, 0, 0)), (0, 0), mask)

    # A last pass of plain black at the very edge, so no crop can clip a hard chart line
    # at the frame and make the artwork look like a screenshot someone trimmed.
    edge = Image.new("L", (w, h), 0)
    ed = ImageDraw.Draw(edge)
    band = round(min(w, h) * 0.045)
    for i in range(band):                                 # bounded by the band width
        v = round(255 * (1 - i / band) ** 1.4)
        ed.rectangle([i, i, w - 1 - i, h - 1 - i], outline=v)
    out.paste(Image.new("RGB", (w, h), (0, 0, 0)), (0, 0), edge)
    return out


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    src = source()
    src = ImageEnhance.Color(ImageEnhance.Brightness(src).enhance(BRIGHTNESS)).enhance(SATURATION)
    print(f"source chart region {src.width}x{src.height} from {os.path.basename(SOURCE)}")

    for name, w, h, hx, vy in TARGETS:
        img = settle(cover(src, w, h, hx, vy), w, h)
        assert img.size == (w, h), f"{name}: composed {img.size}, wanted {(w, h)}"
        assert img.mode == "RGB", f"{name}: mode {img.mode}, wanted RGB (no alpha)"
        path = os.path.join(OUT_DIR, name)
        img.save(path, "PNG", optimize=True)
        print(f"  {name:<24} {w}x{h}  anchor {hx:.2f}/{vy:.2f}  "
              f"upscale {w / src.width:.1f}x  {os.path.getsize(path) / 1024:,.0f} KB")


if __name__ == "__main__":
    main()
