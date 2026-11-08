#!/usr/bin/env python3
"""Georeference FAA AIRPORT DIAGRAMS, which the FAA does not publish as geospatial PDFs.

WHY THIS TOOL EXISTS AT ALL. `build_plate_georef_embedded.py` reads the page->ground transform the
FAA embeds in each plate PDF (/VP -> /Measure /GEO -> /GPTS + /LPTS). That is authoritative and
exact, and it is the right way to do this -- but it only works where the FAA ships it, and the FAA
ships it for approach charts ONLY. Probed across the 2611 cycle, an airport diagram carries no /VP,
no /Measure, no /GPTS, no /LPTS, no /GCS: nothing. So every APD was a georeference miss, and a miss
is what hides the ownship dot, the ADS-B traffic and the "Overlay on map" action -- on the one chart
a pilot reads while the aircraft is actually moving on the ground.

WHAT IS USED INSTEAD, and why it is not guesswork. An APD draws each runway as a long thin filled
strip, at the chart's own scale, and the FAA drew those strips from the same survey that fills
`apt.sqlite`. So the control points are already there on both sides:

    drawn runway strip endpoints  <->  surveyed runway end coordinates (APT_RWY_END)

Two matched endpoints fix a similarity (scale, rotation, translation) exactly. The point is what
happens NEXT: every OTHER runway on the field then scores that transform without having contributed
to it. At a multi-runway airport this is a genuine out-of-sample test, and it is a demanding one --
a wrong strip pairing throws the other runways off by hundreds of metres. Measured over the cycle,
accepted multi-runway fits land at a few metres RMS and their rotations come out on clean multiples
of 90 degrees, which is what a cartographic product should do and what a lucky fit would not.

THE SINGLE-RUNWAY PROBLEM, stated plainly. With one runway the fit consumes both control points, so
its residual is 0.0 by construction and proves NOTHING; reporting that as a quality figure would be
the most misleading number in the app. Those fits are therefore held to an independent test the fit
cannot launder: the strip's own WIDTH. The fit uses the centreline endpoints only and never looks at
the cross-axis extent, so `strip_width x scale` against the surveyed runway width is free evidence,
and it is exactly the evidence that separates a runway from a taxiway (35-75 ft) or a terminal
apron. A single-runway fit that cannot pass the width test is dropped rather than published, because
the failure mode here is not a blank screen -- it is an ownship dot on the wrong taxiway.

Emits the same schema as `plate_georef.json`, plus `kind: "apd"` so the runtime can apply bounds
that suit a 2 km page instead of a 70 km approach plan view (`PlateGeorefEntry.isPlausible`), and
plus `matchedRunways` / `widthErrPct` so an entry can be audited later without re-running the fit.

Usage:
    build_apd_georef.py --cache DIR [--procedures J] [--out J] [--merge-into J] [--limit N] [-v]

`--cache` is a CYCLE-SCOPED directory of plate PDFs (see fetch_plates.py -- never share one between
cycles; plate filenames are stable across cycles and their contents are not).
"""
import argparse
import json
import math
import os
import sqlite3
import sys

import fitz
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
NAV = os.path.join(HERE, "../ATCTranscribe/Resources/nav")

# ---- Acceptance gates ---------------------------------------------------------------------------
# Deliberately conservative: a rejected diagram costs the pilot a feature, an accepted bad one puts
# their aircraft in the wrong place on a taxiway. The multi-runway residual gate is the one that
# does the real work; the rest are range checks that keep nonsense out.
# Out-of-sample residual ceiling for multi-runway fits. Set from the measured distribution rather
# than picked: over the 2611 cycle the accepted fits run median 2.9 m / p90 6.8 m / p99 14.4 m, with
# exactly one entry in 891 above 20 m. So 20 is where the data stops supporting the fit, and it is
# also comfortably inside a runway width (a 150 ft runway is 46 m), which is the error that would
# actually mislead someone taxiing.
MAX_RMS_M = 20.0
SCALE_BAND = (2.0, 40.0)  # metres of ground per PDF point. Observed: 5.9 (KASE) to 17.7 (KDFW)
WIDTH_TOL_PCT = 60.0      # strip width vs surveyed runway width, single-runway fits only
MIN_STRIP_LEN_PT = 30.0   # a shorter mark is a taxiway label or a hold bar, not a runway
MIN_ASPECT = 6.0          # runways are long and thin; this drops buildings, aprons and the border


def surveyed(db, icao):
    """(ref lat/lon, [(designator, end1 ENU, end2 ENU, length_m, width_m)]) for one airport."""
    a = db.execute("select lat, lon from airport where icao=? and lat is not null",
                   (icao,)).fetchone()
    if not a:
        return None, []
    lat0, lon0 = a
    rows = db.execute("""select r.designator, r.width_ft, e.end_id, e.lat, e.lon
                         from runway r
                         join airport a on a.ident = r.ident
                         join runway_end e on e.ident = r.ident and e.designator = r.designator
                         where a.icao = ? and e.lat is not null""", (icao,)).fetchall()
    grouped = {}
    for desig, width_ft, _end, la, lo in rows:
        grouped.setdefault((desig, width_ft), []).append(enu(la, lo, lat0, lon0))
    out = []
    for (desig, width_ft), ends in grouped.items():
        if len(ends) != 2:            # a single surveyed end gives no vector to match
            continue
        q1, q2 = ends
        out.append((desig, q1, q2, float(np.linalg.norm(q2 - q1)),
                    (width_ft or 0.0) * 0.3048))
    return (lat0, lon0), out


def enu(lat, lon, lat0, lon0):
    """Flat-earth metres east/north of the reference point. Same formula as the embedded builder."""
    return np.array([(lon - lon0) * 111320.0 * math.cos(math.radians(lat0)),
                     (lat - lat0) * 111320.0])


def strips(path, limit=60):
    """Long thin drawn shapes, as (length_pt, width_pt, end1, end2) in page points, y UP.

    Each path's points are reduced by PCA: the principal axis is the strip's centreline, the extreme
    projections along it are its ends, and the cross-axis extent is its width. Width is carried out
    of here unused by the fit on purpose -- it is the independent evidence the single-runway gate
    needs (see the module docstring).
    """
    doc = fitz.open(path)
    page = doc[0]
    # ⚠️ NOT `width` / `height`: the loop below binds `width` to each strip's thickness, so naming
    # the PAGE dimensions that returned the last strip's thickness as the page width — and the page
    # width is what scales the whole georeference (`widthMeters`), so every diagram would have been
    # placed at a page span of a few metres.
    page_w, page_h = page.rect.width, page.rect.height
    found = []
    for p in page.get_drawings():
        pts = []
        for item in p["items"]:
            for v in item[1:]:
                if isinstance(v, fitz.Point):
                    pts.append((v.x, page_h - v.y))
                elif isinstance(v, fitz.Rect):
                    pts += [(v.x0, page_h - v.y0), (v.x1, page_h - v.y0),
                            (v.x1, page_h - v.y1), (v.x0, page_h - v.y1)]
                elif isinstance(v, fitz.Quad):
                    pts += [(q.x, page_h - q.y) for q in (v.ul, v.ur, v.lr, v.ll)]
        if len(pts) < 2:
            continue
        a = np.array(pts, float)
        centre = a.mean(0)
        _, _, vt = np.linalg.svd(a - centre, full_matrices=False)
        along = (a - centre) @ vt[0]
        across = (a - centre) @ vt[1]
        length = float(along.max() - along.min())
        width = max(float(across.max() - across.min()), 1e-6)
        if length < MIN_STRIP_LEN_PT or length / width < MIN_ASPECT:
            continue
        found.append((length, width,
                      centre + vt[0] * along.min(), centre + vt[0] * along.max()))
    doc.close()
    found.sort(key=lambda r: -r[0])
    return (page_w, page_h, found[:limit])     # captured before close(): `page` is dead after it


def sim_from_pair(p1, p2, q1, q2):
    """Similarity page->ground with p1->q1 and p2->q2, as (a, b, t); ground = [[a,-b],[b,a]]p + t."""
    dp, dq = p2 - p1, q2 - q1
    den = float(dp @ dp)
    if den < 1e-9:
        return None
    a = float(dp @ dq) / den
    b = float(dp[0] * dq[1] - dp[1] * dq[0]) / den
    return a, b, q1 - np.array([a * p1[0] - b * p1[1], b * p1[0] + a * p1[1]])


def apply(sol, p):
    a, b, t = sol
    return np.array([a * p[0] - b * p[1], b * p[0] + a * p[1]]) + t


def score(sol, runways, cands):
    """Best endpoint residual per surveyed runway, and the strip each one matched."""
    res, pairs = [], []
    for desig, q1, q2, _len_m, _w_m in runways:
        best = None
        for length, width, s1, s2 in cands:
            for x, y in ((s1, s2), (s2, s1)):
                d = (float(np.linalg.norm(apply(sol, x) - q1))
                     + float(np.linalg.norm(apply(sol, y) - q2))) / 2
                if best is None or d < best[0]:
                    best = (d, x, y, q1, q2, width, desig)
        if best:
            res.append(best[0])
            pairs.append(best)
    return res, pairs


def drawn_half_width(cands, x, y, expect_half_pt):
    """How far the runway's drawn edges lie from its centreline, in page points, or None.

    A runway is not one shape, and it is not drawn the same way twice. At a big field the pavement
    is a filled polygon whose own cross-axis extent IS the width. At a small one the pavement is a
    single path covering runway and taxiways together -- too fat to be a strip at all -- and the only
    thin shapes along the runway are its two edge lines and a dashed centreline, each of which has a
    cross-axis extent of about zero. Measuring one strip therefore reported "width 0", i.e. 100% off,
    and threw away correct fits at exactly the single-runway airports that have nothing else to
    corroborate them.

    So measure the FAMILY: every thin shape lying along the matched line, each contributing its own
    midpoint offset plus half its own thickness, and take the outermost. That yields the same answer
    whether the runway was drawn as one polygon or as two edges.

    The lateral search is bounded to three times the expected half-width, and that bound is what
    keeps the test honest: a parallel taxiway 150 m off the centreline would otherwise be swept in
    and report a runway five times too wide. `expect_half_pt` comes from the SURVEYED width and the
    fitted scale, so a fit whose scale is wrong looks for the edges in the wrong place and does not
    find them -- which is the whole point of running this test.
    """
    axis = y - x
    length = float(np.linalg.norm(axis))
    if length < 1e-6 or expect_half_pt <= 0:
        return None
    axis = axis / length
    normal = np.array([-axis[1], axis[0]])
    mid = (x + y) / 2.0
    limit = 3.0 * expect_half_pt
    lo = hi = None
    for cand_len, cand_w, s1, s2 in cands:
        d = s2 - s1
        n = float(np.linalg.norm(d))
        if n < 1e-6 or abs(cand_len - length) > 0.25 * length:
            continue
        if abs(float(np.dot(d / n, axis))) < math.cos(math.radians(3.0)):
            continue
        offset = (s1 + s2) / 2.0 - mid
        along = abs(float(np.dot(offset, axis)))
        perp = float(np.dot(offset, normal))
        if along > 0.15 * length or abs(perp) > limit:
            continue
        near, far = perp - cand_w / 2.0, perp + cand_w / 2.0
        lo = near if lo is None else min(lo, near)
        hi = far if hi is None else max(hi, far)
    if lo is None:
        return None
    return max(abs(lo), abs(hi))


def refine(pairs, tol):
    """Least-squares similarity over every inlier endpoint pair."""
    rows, rhs = [], []
    for d, x, y, q1, q2, _w, _desig in pairs:
        if d > tol:
            continue
        for p, q in ((x, q1), (y, q2)):
            rows.append([p[0], -p[1], 1, 0]); rhs.append(q[0])
            rows.append([p[1], p[0], 0, 1]); rhs.append(q[1])
    if len(rows) < 4:
        return None
    sol, *_ = np.linalg.lstsq(np.array(rows), np.array(rhs), rcond=None)
    return float(sol[0]), float(sol[1]), np.array([sol[2], sol[3]])


def width_error_pct(sol, cands, pairs, runways):
    """Smallest disagreement between a drawn runway's edges and its surveyed width, as a percent.

    Independent of the fit for every entry (the fit uses centreline endpoints only), and the ONLY
    evidence a single-runway fit has. Returns None when nothing could be measured.
    """
    scale = math.hypot(sol[0], sol[1])
    best = None
    for _d, x, y, _q1, _q2, _w_pt, desig in pairs:
        surveyed_w = next((w for dz, _1, _2, _3, w in runways if dz == desig), 0.0)
        if surveyed_w <= 1.0 or scale <= 0:
            continue
        expect_half_pt = (surveyed_w / 2.0) / scale
        drawn_half = drawn_half_width(cands, x, y, expect_half_pt)
        if drawn_half is None:
            continue
        err = abs(drawn_half - expect_half_pt) / expect_half_pt * 100.0
        best = err if best is None else min(best, err)
    return best


def fit(pdf_path, ref, runways):
    """Georeference one airport diagram, as (entry, None) or (None, reason)."""
    page_w, page_h, cands = strips(pdf_path)
    if not cands:
        return None, "no candidate strips"

    tol = max(MAX_RMS_M * 2, 60.0)

    def rank(sol):
        """How good a hypothesis is: (runways it explains, residual, drawn-width agreement).

        ⚠️ THE THIRD TERM IS NOT A REFINEMENT, it is the whole answer at a single-runway airport.
        With one runway the two control points are consumed by the fit, so EVERY candidate strip
        scores a perfect zero residual and explains exactly one runway — every hypothesis ties, and
        a search ranked on residual alone silently keeps whichever it happened to try first. At KBGR
        that was a 441 pt boundary line rather than the 330 pt runway, a 34% scale error, and the fit
        was then rejected by the width gate for being exactly as wrong as the search had made it.
        Ranking on the independent evidence picks the runway instead, and the gate goes on to confirm
        it rather than to clean up after a coin toss.
        """
        res, pairs = score(sol, runways, cands)
        inl = sum(1 for r in res if r < tol)
        werr = width_error_pct(sol, cands, pairs, runways)
        # ⚠️ THE RESIDUAL IS ROUNDED TO THE METRE, and it has to be. A single-runway fit's residual
        # is zero up to floating-point noise, so comparing raw doubles let 1e-14 against 0.0 settle
        # the ranking before the width term was ever consulted: at KBGR a 323 pt taxiway whose
        # residual happened to land on exactly 0.0 beat the 330 pt runway whose residual was 3e-14,
        # and the width evidence that would have separated them never got a vote. Rounding also says
        # something true of the multi-runway case: half a metre of residual is not evidence, and
        # where two fits are that close the drawn width is the better discriminator.
        return (inl, -round(float(np.median(res))), -(werr if werr is not None else 1e6)), res, pairs

    best = None
    for _length, _width, s1, s2 in cands[:24]:
        for desig, q1, q2, _len_m, _w_m in runways:
            for pp in ((s1, s2), (s2, s1)):
                sol = sim_from_pair(pp[0], pp[1], q1, q2)
                if sol is None:
                    continue
                scale = math.hypot(sol[0], sol[1])
                if not (SCALE_BAND[0] < scale < SCALE_BAND[1]):
                    continue
                key, res, pairs = rank(sol)
                if best is None or key > best[0]:
                    best = (key, sol, res, pairs)
    if best is None:
        return None, "no hypothesis in the scale band"

    _, sol, res, pairs = best
    for _ in range(3):                                  # re-fit on inliers, then re-score
        better = refine(pairs, tol)
        if better is None:
            break
        sol = better
        res, pairs = score(sol, runways, cands)

    inliers = [r for r in res if r <= tol]
    if not inliers:
        return None, "refit lost every runway"
    matched = len(inliers)
    rms = math.sqrt(float(np.mean(np.square(inliers))))
    scale = math.hypot(sol[0], sol[1])
    if not (SCALE_BAND[0] < scale < SCALE_BAND[1]):
        return None, f"scale {scale:.1f} m/pt outside the band"

    width_err = width_error_pct(sol, cands, pairs, runways)
    if matched >= 2:
        if rms > MAX_RMS_M:
            return None, f"out-of-sample residual {rms:.1f} m"
    else:
        # A single-runway fit has a residual of 0.0 by construction. Publishing one on that basis
        # would be the most misleading number in the app, so it stands or falls on the width test.
        if width_err is None:
            return None, "single runway and nothing to corroborate it"
        if width_err > WIDTH_TOL_PCT:
            return None, f"single runway, drawn width off by {width_err:.0f}%"

    lat0, lon0 = ref
    centre = apply(sol, np.array([page_w / 2.0, page_h / 2.0]))
    clat = lat0 + centre[1] / 111320.0
    clon = lon0 + centre[0] / (111320.0 * math.cos(math.radians(lat0)))
    # ⚠️ CLOCKWISE-from-north, so NEGATED. `PlateSimilarity.Placement.rotationDeg` is clockwise
    # (`forwardModel` sends page +x to the ground direction (cos r, -sin r)), while the fit above is
    # the ordinary counter-clockwise one. Getting this backwards is invisible on an approach plate,
    # because FAA plan views are north-up and every rotation in that table is under 1.5 degrees -- and
    # it is catastrophic on an airport diagram, where the page is routinely turned a quarter turn to
    # fit a long runway. Measured through the app's own `worldToPixel` at the +/-90 degree diagrams:
    # 22-54 page points of error with the sign as the counter-clockwise fit produces it, 0.2-1.8 with
    # it negated. (`build_plate_georef_embedded.py` had the same error; see its note.)
    rot = -math.degrees(math.atan2(sol[1], sol[0]))
    rot = rot - 360 if rot > 180 else rot
    return {
        "centerLat": round(clat, 6),
        "centerLon": round(clon, 6),
        "widthMeters": round(page_w * scale, 1),
        "rotationDeg": round(rot, 2),
        "rmsMeters": round(rms, 2),
        "inliers": matched * 2,
        "kind": "apd",
        "matchedRunways": matched,
        "widthErrPct": None if width_err is None else round(width_err, 1),
    }, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--procedures", default=os.path.join(NAV, "procedures.json"))
    ap.add_argument("--apt", default=os.path.join(NAV, "apt.sqlite"))
    ap.add_argument("--cache", required=True, help="cycle-scoped dir of plate PDFs")
    ap.add_argument("--out", required=True)
    ap.add_argument("--merge-into", help="an existing plate_georef.json to fold these into")
    ap.add_argument("--limit", type=int)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    proc = json.load(open(args.procedures))
    cycle = str(proc.get("cycle", ""))
    recs = [(r["f"], icao, r["n"]) for icao, rs in proc["airports"].items()
            for r in rs if r["c"] == "APD"]
    recs.sort()
    if args.limit:
        recs = recs[:args.limit]

    db = sqlite3.connect(args.apt)
    plates, reasons, rmss, rots = {}, {}, [], []
    single = 0
    for i, (pdf, icao, name) in enumerate(recs, 1):
        path = os.path.join(args.cache, pdf)
        if not os.path.exists(path):
            reasons["not cached"] = reasons.get("not cached", 0) + 1
            continue
        ref, runways = surveyed(db, icao)
        if not runways:
            reasons["no paired surveyed runway ends"] = reasons.get("no paired surveyed runway ends", 0) + 1
            continue
        try:
            entry, why = fit(path, ref, runways)
        except Exception as exc:                        # one bad PDF must not end the run
            entry, why = None, f"error: {type(exc).__name__}"
        if entry is None:
            key = why.split(" ")[0] if why else "unknown"
            reasons[why if key in ("no", "single", "refit") else key] = \
                reasons.get(why if key in ("no", "single", "refit") else key, 0) + 1
            if args.verbose:
                print(f"  skip {icao} {pdf}: {why}")
            continue
        entry["airport"] = icao
        entry["name"] = name
        plates[pdf] = entry
        rmss.append(entry["rmsMeters"])
        rots.append(entry["rotationDeg"])
        if entry["matchedRunways"] < 2:
            single += 1
        if i % 100 == 0:
            print(f"  ...{i}/{len(recs)} processed, {len(plates)} georeferenced", flush=True)
    db.close()

    multi = [r for r, e in zip(rmss, plates.values()) if e["matchedRunways"] >= 2]
    print(f"\ncycle={cycle}  airport diagrams={len(recs)}  georeferenced={len(plates)}"
          f"  ({len(plates) / max(len(recs), 1) * 100:.1f}%)")
    print(f"  verified by other runways: {len(plates) - single}   width-checked only: {single}")
    if multi:
        q = np.percentile(multi, [50, 90, 99])
        print(f"  out-of-sample residual (m): median {q[0]:.1f}  p90 {q[1]:.1f}  p99 {q[2]:.1f}"
              f"  max {max(multi):.1f}")
    near90 = sum(1 for r in rots if min(abs(((r - k) + 180) % 360 - 180) for k in (0, 90, -90, 180)) < 1.0)
    print(f"  rotation within 1 deg of a right angle: {near90}/{len(rots)}")
    if reasons:
        print("  not georeferenced:")
        for k, v in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"    {v:5d}  {k}")

    out = {"cycle": cycle, "plates": plates}
    if args.merge_into:
        base = json.load(open(args.merge_into))
        if str(base.get("cycle", "")) != cycle:
            sys.exit(f"refusing to merge: {args.merge_into} is cycle {base.get('cycle')}, "
                     f"procedures.json is {cycle}")
        overlap = set(base["plates"]) & set(plates)
        if overlap:
            sys.exit(f"refusing to merge: {len(overlap)} keys already present, e.g. {sorted(overlap)[:3]}")
        merged = dict(base["plates"])
        merged.update(plates)
        out = {"cycle": cycle, "plates": merged}
        print(f"  merged: {len(base['plates'])} existing + {len(plates)} diagrams = {len(merged)}")
    with open(args.out, "w") as f:
        json.dump(out, f, separators=(",", ":"), sort_keys=True)
    print(f"-> {args.out} ({os.path.getsize(args.out):,} bytes)")


if __name__ == "__main__":
    main()
