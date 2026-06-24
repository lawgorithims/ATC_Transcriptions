#!/usr/bin/env python3
"""Generate the 1024x1024 ATC_Transcribe app icon.

A control-tower glyph with radio/broadcast waves over a dark cockpit-panel gradient —
the amber phosphor accent matches the app's Cockpit theme. Output is opaque RGB,
full-bleed, NO alpha channel (App Store icon rules reject transparency; iOS applies the
rounded-corner mask itself, so we ship a square).

    python Tools/make_icon.py [out.png]      # default: the AppIcon.appiconset PNG
"""
import sys
import math
import numpy as np
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else \
    "ATCTranscribe/Assets.xcassets/AppIcon.appiconset/AppStore.png"

S = 1024
SS = 2          # supersample factor for anti-aliasing, then downscale
W = S * SS

AMBER = (255, 176, 0)
AMBER_DIM = (200, 130, 0)
TOWER = (226, 234, 240)
WINDOW = (20, 40, 56)

# --- background: radial "screen glow" gradient ---
cx, cy = W * 0.5, W * 0.42
inner = np.array([0x16, 0x35, 0x4a], float)   # teal-navy glow
outer = np.array([0x05, 0x0b, 0x13], float)   # near-black navy
yy, xx = np.mgrid[0:W, 0:W]
d = np.clip(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (W * 0.70), 0, 1)[..., None]
bg = (inner * (1 - d) + outer * d).astype(np.uint8)
img = Image.fromarray(bg, "RGB")
draw = ImageDraw.Draw(img, "RGBA")


def s(v):
    return v * SS


# --- broadcast / radio waves, emanating up-and-out from the antenna tip ---
tx, ty = s(512), s(486)
for i, r in enumerate((150, 232, 314)):
    col = AMBER if i == 0 else AMBER_DIM
    alpha = 255 - i * 55
    bbox = [tx - s(r), ty - s(r), tx + s(r), ty + s(r)]
    draw.arc(bbox, start=212, end=328, fill=col + (alpha,), width=int(s(20)))

# --- antenna mast + tip beacon ---
draw.line([(tx, ty), (tx, s(556))], fill=AMBER, width=int(s(9)))
draw.ellipse([tx - s(15), ty - s(15), tx + s(15), ty + s(15)], fill=AMBER)

# --- control-tower glyph (cab over a tapering mast and a footing) ---
cab = [(s(468), s(556)), (s(556), s(556)), (s(576), s(620)), (s(448), s(620))]
mast = [(s(484), s(620)), (s(540), s(620)), (s(558), s(806)), (s(466), s(806))]
foot = [(s(436), s(806)), (s(588), s(806)), (s(604), s(846)), (s(420), s(846))]
for poly in (cab, mast, foot):
    draw.polygon(poly, fill=TOWER)
# cab window band
draw.polygon([(s(478), s(572)), (s(546), s(572)), (s(556), s(602)), (s(468), s(602))],
             fill=WINDOW)

# --- audio waveform along the base (ties the tower to "transcribe") ---
baseY = s(900)
amp = [18, 40, 26, 64, 34, 78, 30, 52, 22, 46, 28, 38, 20]
n = len(amp)
x0, x1 = s(300), s(724)
step = (x1 - x0) / (n - 1)
for i, a in enumerate(amp):
    x = x0 + i * step
    h = s(a)
    draw.line([(x, baseY - h), (x, baseY + h)], fill=AMBER + (235,), width=int(s(10)))

img = img.resize((S, S), Image.LANCZOS).convert("RGB")
img.save(OUT)
print("wrote", OUT, img.size, img.mode)
