#!/usr/bin/env python3
"""Build the Obelisk app icon: the site's obelisk mark, white on black.

    python3 Tools/make_icon.py [obelisk-black.svg] [height-ratio]

Writes BOTH `Assets.xcassets/AppIcon.appiconset/AppStore.png` and
`Assets.xcassets/BrandMark.imageset/BrandMark.png`, which carry the same artwork —
`BrandMark` is the mark shown beside the wordmark in the top bar, the What's-new sheet and
onboarding, so the two must not drift.

# Where the art comes from

The single source of truth is the WEBSITE's favicon, `public/brand/obelisk-black.svg` in
the obeliskaerospace.com repo — a black mark on a light canvas, the same file the site
serves as its light-mode favicon. Pointing at it keeps the app icon and the site mark from
diverging; there is no separate iOS artwork to re-cut.

# Why it is rendered this way

This machine has no SVG renderer (no rsvg-convert, Inkscape or ImageMagick), so QuickLook
does the rasterising. The mark is then lifted out as a COVERAGE MASK and white is painted
through it, rather than inverting the bitmap: inverting leaves grey fringing on every
anti-aliased edge, and the mask keeps those edges clean against black.

Framing is by CENTROID, not bounding box. The stepped base carries more ink than the
shaft, so a bbox-centred obelisk sits visibly low — measured at 3.6% of its own height on
this artwork.

# The hard constraint

An iOS app icon must be a full-bleed OPAQUE square with NO alpha channel. App Store
Connect rejects transparency outright, and iOS applies the rounded-corner mask itself, so
pre-rounded corners only double up. The output is therefore flat RGB at 1024x1024.

# Requirements

Pillow. There is no system Pillow here; use a venv, e.g.
    ~/CommSight/plate-georef-venv/bin/python3 Tools/make_icon.py

# History

Before the rename this script processed `Tools/icon_source.png` (a navy panel with radio
dashes and a navigation arrow) by flood-filling its white surround. That artwork is
retired with the CommSight name; the source file is kept so it can be regenerated if the
old mark is ever wanted back.
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
DEFAULT_SVG = os.path.expanduser("~/CommSight/website/public/brand/obelisk-black.svg")

OUT_ICON = os.path.join(IOS, "ATCTranscribe/Assets.xcassets/AppIcon.appiconset/AppStore.png")
OUT_BRAND = os.path.join(IOS, "ATCTranscribe/Assets.xcassets/BrandMark.imageset/BrandMark.png")

SIZE = 1024
RENDER_AT = 2048          # render large, downscale once — keeps the diagonals clean
BG = (0, 0, 0)

svg = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SVG
height_ratio = float(sys.argv[2]) if len(sys.argv) > 2 else 0.78

if not os.path.exists(svg):
    sys.exit(f"source not found: {svg}\n(pass the path to obelisk-black.svg from the website repo)")


def rasterise(path: str) -> Image.Image:
    """QuickLook the SVG to a PNG in a temp dir and load it."""
    tmp = tempfile.mkdtemp()
    subprocess.run(["qlmanage", "-t", "-s", str(RENDER_AT), "-o", tmp, path],
                   check=True, capture_output=True)
    hits = [f for f in os.listdir(tmp) if f.endswith(".png")]
    if not hits:
        sys.exit("qlmanage produced no PNG — is the source a readable SVG?")
    return Image.open(os.path.join(tmp, hits[0]))


im = rasterise(svg)
if im.mode in ("RGBA", "LA"):                      # flatten onto white so the ink stays dark
    flat = Image.new("RGB", im.size, (255, 255, 255))
    flat.paste(im, mask=im.split()[-1])
    im = flat
gray = im.convert("L")

bbox = gray.point(lambda p: 255 if p < 128 else 0).getbbox()
if not bbox:
    sys.exit("no ink found in the rendered source")

# Inverted crop: mark = 255, canvas = 0. That is the coverage mask to paint white through.
mask = ImageOps.invert(gray.crop(bbox))

target_h = round(SIZE * height_ratio)
target_w = max(1, round(mask.width * target_h / mask.height))
mask = mask.resize((target_w, target_h), Image.LANCZOS)

px = mask.load()
total = sum_x = sum_y = 0
for y in range(target_h):
    for x in range(target_w):
        v = px[x, y]
        if v:
            total += v
            sum_x += x * v
            sum_y += y * v
cx, cy = (sum_x / total, sum_y / total) if total else (target_w / 2, target_h / 2)

# Land the centroid on the canvas centre, clamped so a lopsided mark cannot run off an edge.
left = max(0, min(round(SIZE / 2 - cx), SIZE - target_w))
top = max(0, min(round(SIZE / 2 - cy), SIZE - target_h))

icon = Image.new("RGB", (SIZE, SIZE), BG)
icon.paste((255, 255, 255), (left, top), mask)

for out in (OUT_ICON, OUT_BRAND):
    icon.save(out)
    print(f"wrote {out}")
print(f"{icon.size} {icon.mode} | mark {target_w}x{target_h} ({height_ratio:.0%} height) at ({left},{top})")
