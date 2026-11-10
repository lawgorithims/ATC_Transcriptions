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

# TWO SCENARIOS, because they sell different things.
#
# "enroute" is the whole panel working at once: the filed route, radar cells across it, ADS-B
# traffic, the flown track and the glide footprint. "approach" is the capability a pilot recognises
# instantly — the approach plate georeferenced onto the moving map, with its published fixes flown
# as the active route.
#
# Each carries its own crop, because the chrome does not sit in the same places: the approach frame
# has a second banner under the top bar naming the plate, and its map starts lower as a result.
#
# Every crop is in pixel coordinates of a 2064x2752 upright frame from `Tools/promo_capture.sh`.
# The boundaries are interface, and each number is why:
#   left   540   the GPS card occupies x<530; starting right of it keeps the full vertical range
#   right  2064  the full width — the map controls are off these frames' right edge
#   top          below the banners and the SIMULATED GPS strip. ⚠️ DO NOT LOWER IT "to be safe":
#                on the enroute frame the filed route runs across y≈1240-1380, and starting under
#                it cut the strongest line in the picture out of frame.
#   bottom       above the GS/ALT data bar, which starts at y=2491
# ⚠️ DO NOT DARKEN THIS INTO A BACKDROP. The first version pulled brightness to 0.58 and
# desaturation to 0.82 "so Apple's white text stays legible", and the result was grey mush that
# caught nobody's eye — which is the entire job of a featuring image. Apple's own overlay carries
# its own scrim; this asset's job is to be worth looking at. Keep the chart's colour: the magenta
# airspace, the blue airways, the radar, the orange traffic.
BRIGHTNESS = 0.94
SATURATION = 1.14

SOURCE_SIZE = (2064, 2752)          # asserted: a re-shot frame of another size would silently
                                    # move every crop boundary below

SCENARIOS = [
    ("enroute",  "promo-chart-landscape.png",    (540, 1150, 2064, 2400), "promo"),
    # ⚠️ The approach crop starts BELOW the plate's header. Taking the plate whole puts its
    # comms strip and minimums tables — a wall of small type, and a large "ILS or LOC RWY 8L"
    # title — across the top third, which competes with the editorial text Apple lays over this and
    # edges toward the no-text rule. The plan view is the part that reads as flying. The right edge
    # stops short of 2064 because the last few hundred pixels are still lower-zoom tiles.
    ("approach", "promo-approach-landscape.png", (540, 1380, 1950, 2320), "promo-approach"),
]

SRC_DIR = os.path.join(IOS, "docs/appstore/promo-src")

# (filename, width, height, horizontal anchor, vertical anchor)
#
# Anchors are the fraction of the overspill taken off the top/left, so 0.0 keeps the top or left
# edge. Vertical leans high because the interest sits in the upper half of both crops; horizontal
# leans left. In practice every target here is wider than the source ratio, so the full width is
# always kept and the horizontal anchor only matters if a narrower placement is ever added.
# ⚠️ ONE 5244x2950, NOT TWO. App Store Connect accepts that size for BOTH the header and the
# search placement, and this generator gives them identical anchors — so emitting it twice under two
# names wrote the same 14 MB file to disk twice and committed both. Upload the one file to either.
TARGETS = [
    ("promo-5244x2950.png", 5244, 2950, 0.38, 0.20),
    ("header-3840x1646.png", 3840, 1646, 0.38, 0.10),
    ("search-3840x2560.png", 3840, 2560, 0.40, 0.22),
    ("search-1920x1280.png", 1920, 1280, 0.40, 0.22),
]

def source(filename: str, crop) -> Image.Image:
    path = os.path.join(SRC_DIR, filename)
    if not os.path.exists(path):
        sys.exit(f"source not found: {path}\nRegenerate it with Tools/promo_capture.sh")
    im = Image.open(path)
    assert im.size == SOURCE_SIZE, (
        f"{filename} is {im.size}, expected {SOURCE_SIZE} — the crop numbers are pixel "
        f"coordinates in that capture and mean nothing in another")
    return im.convert("RGB").crop(crop)


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
    # ⚠️ A HINT, NOT A GRADIENT. The first version started darkening at 0.34 of the radius and
    # reached full black, which put a crazy black ring around the chart and left the corners dead.
    # It now does nothing at all until 0.82 of the way out and never exceeds 40%: enough to stop a
    # crop landing on a hard edge, not enough to be visible as an effect.
    small = 128
    g = Image.new("L", (small, small), 0)
    px = g.load()
    mx, my = (small - 1) / 2, (small - 1) / 2
    for y in range(small):                                # bounded: 128 rows
        for x in range(small):                            # bounded: 128 columns
            d = math.hypot((x - mx) / mx, (y - my) / my) / math.sqrt(2)
            px[x, y] = round(102 * min(1.0, max(0.0, (d - 0.82) / 0.18)) ** 1.2)
    mask = g.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(w / 220))

    out = im.copy()
    out.paste(Image.new("RGB", (w, h), (0, 0, 0)), (0, 0), mask)

    # A last pass of plain black at the very edge, so no crop can clip a hard chart line
    # at the frame and make the artwork look like a screenshot someone trimmed.
    edge = Image.new("L", (w, h), 0)
    ed = ImageDraw.Draw(edge)
    band = round(min(w, h) * 0.012)                       # a thin seal, not a frame
    for i in range(band):                                 # bounded by the band width
        v = round(210 * (1 - i / band) ** 1.6)
        ed.rectangle([i, i, w - 1 - i, h - 1 - i], outline=v)
    out.paste(Image.new("RGB", (w, h), (0, 0, 0)), (0, 0), edge)
    return out


def main() -> None:
    for name, filename, crop, out_name in SCENARIOS:          # bounded by the scenarios
        out_dir = os.path.join(IOS, "docs/appstore", out_name)
        os.makedirs(out_dir, exist_ok=True)
        src = source(filename, crop)
        src = ImageEnhance.Color(ImageEnhance.Brightness(src).enhance(BRIGHTNESS)).enhance(SATURATION)
        print(f"{name}: {src.width}x{src.height} from {filename} -> docs/appstore/{out_name}")

        for target, w, h, hx, vy in TARGETS:                  # bounded by the placements
            img = settle(cover(src, w, h, hx, vy), w, h)
            assert img.size == (w, h), f"{target}: composed {img.size}, wanted {(w, h)}"
            assert img.mode == "RGB", f"{target}: mode {img.mode}, wanted RGB (no alpha)"
            path = os.path.join(out_dir, target)
            img.save(path, "PNG", optimize=True)
            print(f"  {target:<24} {w}x{h}  upscale {w / src.width:.1f}x  "
                  f"{os.path.getsize(path) / 1024:,.0f} KB")


if __name__ == "__main__":
    main()
