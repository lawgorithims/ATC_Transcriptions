#!/usr/bin/env python3
"""Georeference FAA plates from the AUTHORITATIVE transform the FAA embeds in every plate PDF.

FAA d-TPP plates are geospatial PDFs (ISO 32000-2): each page carries a /VP viewport with a /Measure /GEO
dict holding /GPTS (ground control points in lat/lon, NAD83) and /LPTS (their positions as fractions of the
/BBox), plus /GCS (the datum). That's the exact page→ground registration the FAA used to make the chart —
no OCR, no symbol detection, no inference. We read it and convert to the app's PlateGeorefEntry
(centerLat/Lon of the full page, the geographic width the page spans, and a clockwise-from-north rotation).

Usage: build_plate_georef_embedded.py [--procedures J] [--cache D] [--out J] [--limit N] [--iap-only]
"""
import fitz, re, json, os, math, argparse
import numpy as np

NAV = os.path.join(os.path.dirname(__file__), "../ATCTranscribe/Resources/nav")

def _arr(name, s):
    m = re.search(r'/' + name + r'\s*\[([^\]]*)\]', s, re.S)
    return [float(x) for x in m.group(1).split()] if m else None

def embedded_georef(path):
    """Return (centerLat, centerLon, widthMeters, rotationDeg, rmsPx) from the embedded transform, or None."""
    try:
        doc = fitz.open(path); pg = doc[0]; W, H = pg.rect.width, pg.rect.height
        d = doc.xref_object(pg.xref, compressed=False)
    except Exception:
        return None
    bbox, gpts, lpts = _arr("BBox", d), _arr("GPTS", d), _arr("LPTS", d)
    doc.close()
    if not (bbox and gpts and lpts) or len(gpts) < 6 or len(gpts) != len(lpts):
        return None
    x0, y0, x1, y1 = bbox; Wb, Hb = x1 - x0, y1 - y0
    if Wb <= 1 or Hb <= 1 or W <= 1 or H <= 1:
        return None
    npt = len(gpts) // 2
    geo = np.empty((npt, 2)); pix = np.empty((npt, 2))          # geo=(lon,lat)  pix=(x, y-top-left)
    for i in range(npt):
        lat, lon = gpts[2*i], gpts[2*i+1]; u, v = lpts[2*i], lpts[2*i+1]
        if not (abs(lat) <= 90 and abs(lon) <= 180 and 0 <= u <= 1 and 0 <= v <= 1):
            return None
        geo[i] = (lon, lat)
        pix[i] = (x0 + u*Wb, H - (y0 + v*Hb))                    # PDF bottom-left → image top-left
    # affine pixel→geo (lon,lat) — small area, so affine ≈ the true homography (sub-px residual)
    A = np.linalg.lstsq(np.hstack([pix, np.ones((npt, 1))]), geo, rcond=None)[0]   # 3x2
    def p2g(x, y):
        lon, lat = np.array([x, y, 1.0]) @ A
        return lat, lon
    # round-trip residual (px) as a quality read
    Ainv = np.linalg.lstsq(np.hstack([geo, np.ones((npt, 1))]), pix, rcond=None)[0]
    predpix = np.hstack([geo, np.ones((npt, 1))]) @ Ainv
    rms_px = float(np.sqrt(((predpix - pix) ** 2).sum(1)).max())
    # convert to the app's similarity: center = geo(page centre); width = ground metres across the page;
    # rotation = clockwise-from-north angle of the page +x axis.
    clat, clon = p2g(W/2, H/2)
    lat_e, lon_e = p2g(W, H/2); lat_w, lon_w = p2g(0, H/2)
    def enu(la, lo, la0, lo0):
        return ((lo-lo0)*111320.0*math.cos(la0*math.pi/180), (la-la0)*111320.0)
    ee, en = enu(lat_e, lon_e, clat, clon); we, wn = enu(lat_w, lon_w, clat, clon)
    dx_e, dx_n = ee - we, en - wn                                # ground vector for page +x (west→east across page)
    widthMeters = math.hypot(dx_e, dx_n)
    rotationDeg = math.degrees(math.atan2(dx_n, dx_e))           # 0 = +x points east = north-up
    # normalize
    r = rotationDeg % 360
    if r > 180: r -= 360
    return clat, clon, widthMeters, r, rms_px


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--procedures", default=os.path.join(NAV, "procedures.json"))
    ap.add_argument("--cache", default="/Users/bsusl/CommSight/plate-georef-out/plates_cache")
    ap.add_argument("--out", default="/Users/bsusl/CommSight/plate-georef-out/plate_georef_embedded.json")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--iap-only", action="store_true")
    args = ap.parse_args()

    proc = json.load(open(args.procedures)); cycle = proc.get("cycle", "")
    recs = []
    for icao, rs in proc["airports"].items():
        for r in rs:
            if args.iap_only and r["c"] != "IAP": continue
            recs.append((r["f"], icao, r["n"]))
    if args.limit: recs = recs[:args.limit]

    plates = {}; n_ok = n_no = n_missing = 0; worst = 0.0
    for i, (pdf, icao, name) in enumerate(recs):
        p = os.path.join(args.cache, pdf)
        if not os.path.exists(p): n_missing += 1; continue
        g = embedded_georef(p)
        if not g: n_no += 1; continue
        clat, clon, width, rot, rms = g
        worst = max(worst, rms)
        plates[pdf] = {"airport": icao, "name": name, "centerLat": round(clat, 6), "centerLon": round(clon, 6),
                       "widthMeters": round(width, 1), "rotationDeg": round(rot, 2),
                       "rmsMeters": round(rms, 2), "inliers": 4}
        n_ok += 1
        if (i+1) % 2000 == 0: print(f"  …{i+1} processed, {n_ok} georeferenced")
    with open(args.out, "w") as f:
        json.dump({"cycle": cycle, "plates": plates}, f, separators=(",", ":"), sort_keys=True)
    print(f"cycle={cycle}  georeferenced={n_ok}  no-embedded-geo={n_no}  not-cached={n_missing}  "
          f"worst-GCP-residual={worst:.2f}px  -> {args.out} ({os.path.getsize(args.out)} bytes)")


if __name__ == "__main__":
    main()
