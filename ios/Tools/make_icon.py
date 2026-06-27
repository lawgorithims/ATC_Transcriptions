#!/usr/bin/env python3
"""Process the designed CommSight icon source into the App Store / app-icon PNG.

The source (`Tools/icon_source.png`) is a designed icon on a white canvas (a navy rounded
panel — radio/broadcast dashes, transcript lines, a navigation arrow). For iOS the icon must be
a **full-bleed opaque square with NO alpha** (App Store rejects transparency; iOS applies the
rounded-corner mask itself). So we flood-fill the white canvas outside the panel with the panel's
navy, then downscale to 1024×1024.

    python Tools/make_icon.py [source.png] [out.png]
        defaults: Tools/icon_source.png → AppIcon.appiconset/AppStore.png (+ BrandMark.imageset)
"""
import sys
from PIL import Image, ImageDraw

SRC = sys.argv[1] if len(sys.argv) > 1 else "Tools/icon_source.png"
OUT = sys.argv[2] if len(sys.argv) > 2 else \
    "ATCTranscribe/Assets.xcassets/AppIcon.appiconset/AppStore.png"
BRAND = "ATCTranscribe/Assets.xcassets/BrandMark.imageset/BrandMark.png"

im = Image.open(SRC).convert("RGB")
w, h = im.size


def navy_near(sx, sy, dx, dy):
    """Scan inward from a corner until the dark navy panel edge — that local color fills the corner."""
    x, y = sx, sy
    for _ in range(min(w, h) // 2):
        px = im.getpixel((x, y))
        if sum(px) < 240:
            return px
        x += dx
        y += dy
    return (1, 17, 55)


for sx, sy, dx, dy in [(0, 0, 1, 1), (w - 1, 0, -1, 1), (0, h - 1, 1, -1), (w - 1, h - 1, -1, -1)]:
    ImageDraw.floodfill(im, (sx, sy), navy_near(sx, sy, dx, dy), thresh=60)

out = im.resize((1024, 1024), Image.LANCZOS).convert("RGB")
out.save(OUT)
out.save(BRAND)
print("wrote", OUT, "and", BRAND, out.size, out.mode)
