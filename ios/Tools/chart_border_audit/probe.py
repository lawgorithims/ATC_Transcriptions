"""Adversarial border probe: live tile server vs an independent oracle built from the pack files.

usage: probe.py PACKDIR PORT SUFFIX(_SEC|ENR_L) MODE
  MODE "pairs"          -> print touching pairs with a centre point (lat lon a b)
  MODE "check a b z..." -> probe the band between packs a and b at the given zooms
"""
import sqlite3, io, sys, os, math, glob, urllib.request, json
from PIL import Image

PACKDIR, PORT, KIND, MODE = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
OVERZOOM, ANCESTOR = 5, 4

def packs():
    out = {}
    for f in sorted(glob.glob(os.path.join(PACKDIR, "*.mbtiles"))):
        name = os.path.basename(f)[:-8].split("-")[0]
        if KIND not in name: continue
        c = sqlite3.connect(f)
        m = dict(c.execute("select name,value from metadata"))
        b = [float(v) for v in m["bounds"].split(",")]
        out[name] = dict(f=f, c=c, b=b, minz=int(m["minzoom"]), maxz=int(m["maxzoom"]))
    return out

P = packs()

def blob(p, z, x, y):
    r = p["c"].execute("select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
                       (z, x, (1 << z) - 1 - y)).fetchone()
    return r[0] if r else None

def lon2x(lon, z): return int((lon + 180) / 360 * (1 << z))
def lat2y(lat, z):
    r = math.radians(lat); return int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z))

def piece(p, z, x, y, S=256):
    """What this pack alone can put on tile z/x/y (native, ancestor or overzoom), as an S×S RGBA."""
    if z < p["minz"]: return None
    if z <= p["maxz"]:
        raw = blob(p, z, x, y)
        if raw: return Image.open(io.BytesIO(raw)).convert("RGBA").resize((S, S))
        steps = range(1, ANCESTOR + 1)
    elif z <= p["maxz"] + OVERZOOM:
        steps = [z - p["maxz"]]
    else:
        return None
    for s in steps:
        az = z - s
        if az < p["minz"]: break
        raw = blob(p, az, x >> s, y >> s)
        if not raw: continue
        im = Image.open(io.BytesIO(raw)).convert("RGBA")
        n = 1 << s; w = im.width / n
        ox, oy = (x % n) * w, (y % n) * w
        return im.crop((int(ox), int(oy), int(ox + w), int(oy + w))).resize((S, S), Image.BILINEAR)
    return None

def opaque(im): return sum(1 for a in im.getchannel("A").get_flattened_data() if a > 200) / (im.width * im.height)

def served(z, x, y):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/{z}/{x}/{y}", timeout=10) as r:
            return Image.open(io.BytesIO(r.read())).convert("RGBA").resize((256, 256))
    except urllib.error.HTTPError as e:
        return None if e.code == 404 else "ERR"
    except Exception:
        return "ERR"

if MODE == "pairs":
    names = sorted(P)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            A, B = P[a]["b"], P[b]["b"]
            w, s, e, n = max(A[0], B[0]), max(A[1], B[1]), min(A[2], B[2]), min(A[3], B[3])
            if w < e and s < n:
                print(f"{(s + n) / 2:.3f} {(w + e) / 2:.3f} {a} {b} {P[a]['maxz']} {P[b]['maxz']} {e - w:.2f} {n - s:.2f}")
    sys.exit()

a, b = sys.argv[5], sys.argv[6]
zooms = [int(z) for z in sys.argv[7:]]
A, B = P[a]["b"], P[b]["b"]
w, s, e, n = max(A[0], B[0]), max(A[1], B[1]), min(A[2], B[2]), min(A[3], B[3])
# Cap the band so a long shared edge stays within what the map has mounted around the centre.
cl, ct = (w + e) / 2, (s + n) / 2
w, e = max(w, cl - 0.5), min(e, cl + 0.5)
s, n = max(s, ct - 0.5), min(n, ct + 0.5)
report = {"pair": f"{a}/{b}", "z": {}}
for z in zooms:
    tiles = [(x, y) for x in range(lon2x(w, z), lon2x(e, z) + 1) for y in range(lat2y(n, z), lat2y(s, z) + 1)]
    bad, checked, errs, worst = [], 0, 0, 0.0
    for x, y in tiles:
        pieces = [pc for pc in (piece(P[k], z, x, y) for k in P
                  if P[k]["b"][0] - .05 <= (x / (1 << z)) * 360 - 180 + 360 / (1 << z) and
                     (x / (1 << z)) * 360 - 180 <= P[k]["b"][2] + .05) if pc is not None]
        if len(pieces) < 2: continue                     # only seams: 2+ packs can contribute
        oracle = Image.new("RGBA", (256, 256))
        for pc in pieces: oracle = Image.alpha_composite(oracle, pc)
        o = opaque(oracle)
        if o < 0.05: continue
        got = served(z, x, y); checked += 1
        if got == "ERR": errs += 1; continue
        g = 0.0 if got is None else opaque(got)
        gap = o - g
        worst = max(worst, gap)
        if gap > 0.03: bad.append((x, y, round(o, 2), round(g, 2)))
    report["z"][z] = dict(seam_tiles=checked, errors=errs, short=len(bad), worst_gap=round(worst, 3), examples=bad[:4])
print(json.dumps(report))
