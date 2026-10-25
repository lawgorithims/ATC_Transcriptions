"""Invariants of the marine pack pipeline that cannot be checked by looking at a built pack.

WHY THESE EXIST. The marine build is a 7,303-cell fan-in whose output is one opaque 96 MB SQLite
file per region. Nothing about a finished pack reveals that a region box was mistyped, that a band
window overlaps its neighbour, or that a few hundred cells were never assigned to anything — the
pack simply comes out smaller, and smaller is indistinguishable from correct. Each test below
corresponds to a defect that was actually present in the first draft of this pipeline.

Run:  python3 marine/test_marine_packs.py
"""
import json
import os
import sqlite3
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import encspec                    # noqa: E402
import build_marine_packs as bmp  # noqa: E402

FAILURES = []


def fail(label, msg):
    FAILURES.append(f"{label}: {msg}")


def expect_exit(label, fn, expect):
    """`fn` must raise SystemExit whose message contains `expect`."""
    try:
        fn()
    except SystemExit as ex:
        got = str(ex)
        if expect not in got:
            fail(label, f"refused for the wrong reason\n    want ~{expect!r}\n    got  {got!r}")
        return
    fail(label, f"expected a refusal containing {expect!r}, got none")


def cell(ident, band, bbox, layers=None, issued="20261021"):
    return {"ident": ident, "band": band, "bbox": list(bbox), "issued": issued,
            "path": f"/nonexistent/{ident}.000", "layers": layers or {}}


# ── the invariant the whole merge rests on ──────────────────────────────────────────────────────
def test_band_windows_partition_the_zoom_range():
    """merge_band_packs concatenates band packs with a bare INSERT and no precedence rule. That is
    only safe while no two bands can emit the same (z, x, y) — i.e. while the windows are disjoint
    AND contiguous. If someone widens a window for better generalisation, this must fail loudly."""
    wins = sorted(encspec.BAND_ZOOM.items())
    for band, (lo, hi) in wins:
        if lo > hi:
            fail("band windows", f"band {band} window is inverted: z{lo}-{hi}")
    for (b1, (_, hi1)), (b2, (lo2, _)) in zip(wins, wins[1:]):
        if lo2 != hi1 + 1:
            fail("band windows",
                 f"band {b1} ends at z{hi1} and band {b2} starts at z{lo2} — "
                 f"{'overlap' if lo2 <= hi1 else 'gap'} breaks the lossless merge")
    covered = set()
    for lo, hi in encspec.BAND_ZOOM.values():
        covered |= set(range(lo, hi + 1))
    if covered != set(range(encspec.MIN_ZOOM, encspec.MAX_ZOOM + 1)):
        fail("band windows", f"windows do not cover z{encspec.MIN_ZOOM}-{encspec.MAX_ZOOM} exactly")


def test_band_windows_close_the_gap_a_missing_band_would_leave():
    """The Great Lakes have no band-3 cells, so lake_superior / lake_michigan_huron /
    wisconsin_inland hold bands [2,4,5,6]. With BAND_ZOOM used verbatim that leaves z10-11 empty
    in the middle of a pack advertising z8-17, and MapLibre draws nothing there. band_windows()
    drops each present band's lower bound to meet the previous one."""
    for bands in ([1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5], [2, 4, 5, 6], [2, 3, 4, 5, 6], [4, 5], [5]):
        w = encspec.band_windows(bands)
        if sorted(w) != sorted(bands):
            fail("band windows", f"{bands}: returned bands {sorted(w)}")
        zs = [z for b in w for z in range(w[b][0], w[b][1] + 1)]
        if len(zs) != len(set(zs)):
            fail("band windows", f"{bands}: windows overlap — the lossless tile merge breaks")
        gaps = [z for z in range(min(zs), max(zs) + 1) if z not in zs]
        if gaps:
            fail("band windows", f"{bands}: zoom(s) {gaps} are in the advertised range but no "
                                 f"band covers them")
        for b in w:
            if w[b][1] != encspec.BAND_ZOOM[b][1]:
                fail("band windows", f"{bands}: band {b} upper bound moved to {w[b][1]}; only the "
                                     f"LOWER bound may move (raising it is overscale)")
            if w[b][0] > encspec.BAND_ZOOM[b][0]:
                fail("band windows", f"{bands}: band {b} lower bound RAISED to {w[b][0]} — that "
                                     f"opens a gap rather than closing one")
    # The real Great Lakes shape, spelled out.
    w = encspec.band_windows([2, 4, 5, 6])
    if w[4] != (10, 13):
        fail("band windows", f"band 4 should stretch down to z10 to cover the absent band 3, got {w[4]}")


def test_each_band_ends_at_or_below_its_natural_zoom():
    """A cell must not be pushed past the scale it was surveyed for. These medians are measured
    from the 2026-10-21 set; the point of the test is that the windows stay anchored to them."""
    medians = {1: 3_500_000, 2: 811_980, 3: 180_000, 4: 90_000, 5: 12_000, 6: 4_000}
    for band, scale in medians.items():
        hi = encspec.BAND_ZOOM[band][1]
        nat = encspec.natural_zoom(scale)
        if hi > nat + 1.0:
            fail("overscale", f"band {band} renders to z{hi} but its median cell (1:{scale:,}) "
                              f"is only good to z{nat:.1f}")


# ── the spec is self-consistent ─────────────────────────────────────────────────────────────────
def test_clearance_layers_carry_a_clearance_field():
    for lname in encspec.CLEARANCE_BEARING_LAYERS:
        fields = encspec.LAYERS.get(lname)
        if fields is None:
            fail("clearance spec", f"{lname} is clearance-bearing but not in LAYERS at all")
        elif not any(f.startswith("VERC") for f in fields):
            fail("clearance spec", f"{lname} keeps no VERC* field, so its clearance cannot reach "
                                   f"the tiles: {fields}")


def test_never_simplify_layers_are_real_layers():
    for lname in encspec.NEVER_SIMPLIFY:
        if lname not in encspec.LAYERS:
            fail("simplify spec", f"{lname} is in NEVER_SIMPLIFY but not in LAYERS — the MVT CONF "
                                  f"would name a layer that is never written")


def test_no_per_layer_simplification_option_is_passed():
    """Regression: a per-layer MVT `CONF` of {"CBLOHD": {"simplification": 0}} was passed for a
    release and did nothing — GDAL's MVT writer reads only target_name/description/minzoom/maxzoom
    per layer, and SIMPLIFICATION is dataset-level. The old test only checked that the layer names
    were spelled right, which they were, so it confirmed an inert mechanism. Assert the builder no
    longer pretends to have one, and that it declares the real dataset-level option instead."""
    src = open(os.path.join(HERE, "build_marine_packs.py")).read()
    # Strip comments first: this file explains the old bug at length and the explanation names the
    # dead key. Grepping raw source made the test fail on its own documentation.
    code = "\n".join(ln.split("#", 1)[0] for ln in src.splitlines())
    if "def mvt_conf" in code or "mvt_conf()" in code:
        fail("simplification", "mvt_conf() is back; per-layer simplification is not a GDAL MVT key")
    if '"simplification"' in code or "CONF=" in code:
        fail("simplification", "a per-layer 'simplification'/CONF key is being passed again")
    if "SIMPLIFICATION=" not in src:
        fail("simplification", "the dataset-level SIMPLIFICATION option is not being set, so "
                               "generalisation is whatever GDAL defaults to rather than declared")
    from osgeo import gdal
    opts = gdal.GetDriverByName("MVT").GetMetadataItem("DMD_CREATIONOPTIONLIST") or ""
    if "SIMPLIFICATION" not in opts:
        fail("simplification", "this GDAL's MVT driver has no SIMPLIFICATION option at all")


# ── regions.conf ────────────────────────────────────────────────────────────────────────────────
def test_real_regions_conf_parses_and_is_sane():
    regions = bmp.load_regions(os.path.join(HERE, "regions.conf"))
    if len(regions) < 20:
        fail("regions", f"only {len(regions)} regions parsed; the file defines many more")
    for r in regions:
        w, s, e, n = r["bbox"]
        # ⚠️ The antimeridian trap. The first draft wrote `-172.0 | -15.0 | 147.0 | 20.5` for the
        # Pacific islands: it passes min<max, and silently describes the Americas instead. A box
        # that wide is always this mistake — the real western-Pacific regions use positive
        # longitudes on their own side of the line.
        if e - w > 60.0:
            fail("regions", f"{r['name']} spans {e-w:.0f}° of longitude — almost certainly an "
                            f"antimeridian box written as min<max")
        if n - s > 60.0:
            fail("regions", f"{r['name']} spans {n-s:.0f}° of latitude")
        if not (-180 <= w < e <= 180 and -90 <= s < n <= 90):
            fail("regions", f"{r['name']} bbox out of range: {r['bbox']}")


def test_regions_conf_refusals():
    def write(text):
        fh = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False)
        fh.write(text)
        fh.close()
        return fh.name

    p = write("a | A | -10 | 10 | -5 | 20\na | A2 | -4 | 10 | -1 | 20\n")
    expect_exit("duplicate region name", lambda: bmp.load_regions(p), "duplicate region name")
    os.remove(p)

    p = write("a | A | -5 | 10 | -10 | 20\n")
    expect_exit("inverted bbox", lambda: bmp.load_regions(p), "not min<max")
    os.remove(p)

    p = write("a | A | -10 | 10 | -5\n")
    expect_exit("short row", lambda: bmp.load_regions(p), "expected 6 fields")
    os.remove(p)

    p = write("a | A | west | 10 | -5 | 20\n")
    expect_exit("non-numeric", lambda: bmp.load_regions(p), "non-numeric bbox")
    os.remove(p)

    p = write("# only comments\n\n")
    expect_exit("empty file", lambda: bmp.load_regions(p), "no regions defined")
    os.remove(p)


def test_orphan_cells_abort_the_build():
    """The 585-cell miss. A cell in no region is charted water that silently never ships."""
    regions = [{"name": "r", "label": "R", "bbox": [-10, 10, -5, 20]}]
    inside = cell("IN", 5, [-9, 11, -8, 12])
    outside = cell("OUT", 5, [100, 11, 101, 12])
    bmp.assign_cells([inside], regions)        # must not raise
    expect_exit("orphan cell", lambda: bmp.assign_cells([inside, outside], regions),
                "fall in NO region")


def test_real_regions_cover_the_inland_water_that_was_missed():
    """Regression for the specific gaps the first regions.conf had.

    Every coordinate below was CONFIRMED against the 2026-10-21 ENC set to have charted water
    (a DEPARE feature) within 2 km, at the usage band noted. They are therefore water this
    pipeline can actually serve, and a region box that does not reach them is a defect.

    Deliberately NOT asserted here, because NOAA charts no water within 2 km of either:
        Lake Hood, Anchorage AK (61.18, -149.97) — the busiest seaplane base in the world
        Moosehead Lake, ME      (45.65,  -69.70)
    They are the clearest evidence that the marine chart layer cannot be the whole feature; both
    need the inland waterbody source (USGS NHD). See marine/README.md."""
    regions = bmp.load_regions(os.path.join(HERE, "regions.conf"))
    spots = [
        ("Columbia R. at Tri-Cities, WA", 46.23, -119.10),   # band 5  US5WA4IU
        ("Snake R. at Lewiston, ID",      46.42, -117.02),   # band 5  US5WA5DW
        ("Lake Champlain, VT",            44.48,  -73.21),   # band 5  US5VT1ED
        ("Hudson R. at Albany, NY",       42.65,  -73.75),   # band 5  US5NYC4J
        ("San Francisco Delta, CA",       38.06, -121.84),   # band 5  US5OAKIO
        ("Lake Winnebago, WI",            44.00,  -88.42),   # band 5  US5WI2UL
        ("Lake Pend Oreille, ID",         48.17, -116.42),   # band 4  US4ID1VC
        ("Long Island Sound, CT",         41.15,  -72.90),   # band 5  US5CT1CK
        ("Kenmore Air Harbor, WA (S60)",  47.76, -122.26),   # band 5  US5SEAHM
        ("Ketchikan, AK",                 55.35, -131.67),   # band 5  US5KTNHD
        ("Miami Seaplane Base, FL",       25.78,  -80.17),   # band 5  US5MIACC
    ]
    for label, lat, lon in spots:
        hit = [r["name"] for r in regions
               if r["bbox"][0] <= lon <= r["bbox"][2] and r["bbox"][1] <= lat <= r["bbox"][3]]
        if not hit:
            fail("coverage", f"{label} ({lat},{lon}) falls in no region")


def test_overlaps_is_symmetric_and_edge_inclusive():
    a, b = [-10, 10, -5, 20], [-5, 20, 0, 30]      # touching at one corner
    if not (bmp.overlaps(a, b) and bmp.overlaps(b, a)):
        fail("overlaps", "touching boxes should count as overlapping (edge seams need it)")
    c = [-4, 10, -1, 20]
    if bmp.overlaps(a, c) or bmp.overlaps(c, a):
        fail("overlaps", "disjoint boxes reported as overlapping")


# ── clipping ────────────────────────────────────────────────────────────────────────────────────
def test_clip_geom_covers_the_region_and_stays_on_the_globe():
    g = bmp.clip_geom([-125.5, 46.0, -121.5, 49.5])
    x0, x1, y0, y1 = g.GetEnvelope()
    m = bmp.CLIP_MARGIN_DEG
    if not (abs(x0 - (-125.5 - m)) < 1e-9 and abs(x1 - (-121.5 + m)) < 1e-9):
        fail("clip geom", f"longitude envelope {x0},{x1} does not match bbox ± {m}")
    if not (abs(y0 - (46.0 - m)) < 1e-9 and abs(y1 - (49.5 + m)) < 1e-9):
        fail("clip geom", f"latitude envelope {y0},{y1} does not match bbox ± {m}")

    # ⚠️ The clamp this test used to exercise was the LATITUDE one, via a comment claiming
    # arctic_alaska has "n + margin > 90". It does not: 82.0 + 0.25 = 82.25, so no region in the
    # file reaches the latitude clamp and the assertion could never fail. The clamp real data DOES
    # hit is the LONGITUDE one — aleutians has w = -180.0 and nw_pacific_bering has e = 180.0 —
    # and it was untested. It silently removes the margin on that side, which is a real (accepted)
    # seam at the antimeridian, so pin the behaviour rather than leave it to be rediscovered.
    for bbox, side in (([-180.0, 49.5, -163.5, 66.5], "west"),
                       ([147.5, 18.5, 180.0, 68.5], "east")):
        cg = bmp.clip_geom(bbox)
        cx0, cx1, _, _ = cg.GetEnvelope()
        if cx0 < -180.0 or cx1 > 180.0:
            fail("clip geom", f"{side} clip reaches {cx0},{cx1} — off the globe")
        if side == "west" and abs(cx0 - (-180.0)) > 1e-9:
            fail("clip geom", f"west edge clamped to {cx0}, expected exactly -180")
        if side == "east" and abs(cx1 - 180.0) > 1e-9:
            fail("clip geom", f"east edge clamped to {cx1}, expected exactly 180")

    # And the latitude clamp itself, with a box that genuinely needs it.
    polar = bmp.clip_geom([-170.0, 59.0, -140.0, 89.9])
    _, _, _, py1 = polar.GetEnvelope()
    if py1 > 90.0:
        fail("clip geom", f"latitude {py1} exceeds 90 — an unprojectable clip polygon")


# ── verify_pack actually refuses bad packs ──────────────────────────────────────────────────────
def _pack(tmpdir, name="p.mbtiles", md=None, tiles=1):
    path = os.path.join(tmpdir, name)
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER,
                            tile_data BLOB,
                            PRIMARY KEY (zoom_level, tile_column, tile_row));
    """)
    base = {"format": "pbf", "enc_vintage": "20261021",
            "json": json.dumps({"vector_layers": [{"id": "CBLOHD", "fields": {"VERCLR": "Number"}}]}),
            "bounds": "-125.45,45.75,-121.25,49.75",
            "data_bounds": "-125.40,46.10,-121.60,49.40",
            "region_bbox": "-125.2,46.0,-121.5,49.5"}
    base.update(md or {})
    con.executemany("INSERT INTO metadata VALUES (?,?)", list(base.items()))
    for i in range(tiles):
        con.execute("INSERT INTO tiles VALUES (?,?,?,?)", (16, 100 + i, 200, b"x"))
    con.commit()
    con.close()
    return path


def test_verify_pack_flags_each_defect():
    with tempfile.TemporaryDirectory() as td:
        cases = [
            ("clean",            {},                               None),
            ("wrong format",     {"format": "png"},                "expected 'pbf'"),
            ("undated",          {"enc_vintage": ""},              "undated artifact"),
            # The guard reads data_bounds (the PRE-clamp extent); overriding `bounds` would be
            # testing the clamp, which is exactly the tautology this replaced.
            ("overstated bounds", {"data_bounds": "-134.4,38.4,-116.3,61.25"},
                                                                   "outside region_bbox"),
            ("cable layer lost", {"json": json.dumps({"vector_layers": []})},
                                                                   "layer absent"),
        ]
        for label, md, want in cases:
            p = _pack(td, f"{label.replace(' ','_')}.mbtiles", md)
            probs = bmp.verify_pack(p, {"CBLOHD": 10}, label)
            if want is None:
                if probs:
                    fail("verify_pack", f"{label}: unexpected problems {probs}")
            elif not any(want in x for x in probs):
                fail("verify_pack", f"{label}: expected a problem containing {want!r}, got {probs}")

        p = _pack(td, "empty.mbtiles", {}, tiles=0)
        if not any("zero tiles" in x for x in bmp.verify_pack(p, {}, "empty")):
            fail("verify_pack", "an empty pack was accepted")


def test_filter_rect_matches_the_clip_envelope():
    """⚠️ THE ONE-LINE BUG THAT DELETED 13,512 FEATURES. build_band_gpkg clipped to bbox+margin but
    spatially filtered on the bare bbox, so any feature living only in the margin ring was never
    read — including 349 charted underwater rocks and 120 obstructions — while the pack still
    advertised bounds covering that ring. Assert the filter is derived from the clip, not the box."""
    src = open(os.path.join(HERE, "build_marine_packs.py")).read()
    if "SetSpatialFilterRect(*bbox)" in src:
        fail("filter/clip", "the spatial filter uses the tight region bbox again; features that "
                            "lie only in the clip margin will be silently dropped")
    if "filter_rect" not in src or "clip.GetEnvelope()" not in src:
        fail("filter/clip", "the spatial filter is no longer derived from the clip envelope")


def test_coverage_guard_catches_a_hole_assignment_misses():
    """assign_cells only asks whether a cell's bbox TOUCHES a region; the data is cut per feature,
    so a cell can be assigned and still have charted area in a hole between boxes. This is the
    Kodiak case: 8,936 band>=4 features were in no pack while the build reported success."""
    # The real shape of the Kodiak defect: the region's south edge (57.5) cuts through the cell,
    # so the cell IS assigned on the strip above it while everything below is in no region at all.
    regions = [{"name": "sc_alaska", "label": "SC", "bbox": [-154.5, 57.5, -151.0, 63.5]}]
    hole = cell("US4AK4IG", 4, [-152.4, 57.3, -151.8, 57.6])
    assigned = bmp.assign_cells([hole], regions)
    if assigned["sc_alaska"] != [hole]:
        fail("coverage hole", "fixture is wrong: the cell must be ASSIGNED for this to be the bug "
                              "under test — assignment passing is the whole point")
    expect_exit("coverage hole", lambda: bmp.assert_regions_cover_detailed_cells([hole], regions),
                "charted area outside every region")
    # A cell fully inside is fine.
    ok = cell("US5OK", 5, [-153.0, 58.0, -152.0, 59.0])
    bmp.assert_regions_cover_detailed_cells([ok], regions)
    # Bands 1-3 are overview cells spanning oceans; they are reported, not fatal.
    coarse = cell("US1PO02M", 1, [-152.4, 57.3, -151.8, 57.6])
    bmp.assert_regions_cover_detailed_cells([coarse], regions)


def test_reconciliation_is_per_cell_not_a_shared_counter():
    """The first shortfall check summed every cell into one per-layer counter and compared it with
    the expectation of only the wholly-contained cells — so an edge cell's features masked a
    contained cell losing everything. Assert the attribution exists."""
    src = open(os.path.join(HERE, "build_marine_packs.py")).read()
    if "per_cell" not in src:
        fail("reconciliation", "build_band_gpkg no longer returns per-cell counts, so a shortfall "
                               "cannot be attributed and the check goes back to being vacuous")
    if "cell {c['ident']} layer" not in src:
        fail("reconciliation", "the shortfall message no longer names the cell that lost features")


def test_bounds_guard_tests_the_data_not_the_clamp():
    """merge_band_packs clamped bounds into exactly the window verify_pack then checked them
    against — arithmetically incapable of failing. The guard must read the pre-clamp extent."""
    src = open(os.path.join(HERE, "build_marine_packs.py")).read()
    if "data_bounds" not in src:
        fail("bounds guard", "no data_bounds is recorded, so the bounds check is testing the clamp")
    probs = []
    with tempfile.TemporaryDirectory() as td:
        p = _pack(td, "overstated.mbtiles",
                  {"data_bounds": "-134.4,38.4,-116.3,61.25"})       # pre-clamp extent is huge
        probs = bmp.verify_pack(p, {"CBLOHD": 10}, "overstated")
    if not any("outside region_bbox" in x for x in probs):
        fail("bounds guard", f"an overstated data extent was accepted: {probs}")


def test_verify_pack_flags_an_unpopulated_zoom_window():
    """A region with no cells in a middle usage band produces a pack whose minzoom..maxzoom spans
    zooms holding no tiles; MapLibre asks for them and draws nothing. 6 of the 42 real regions
    already had this shape."""
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "holey.mbtiles")
        con = sqlite3.connect(path)
        con.executescript("""
            CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER,
                                tile_data BLOB,
                                PRIMARY KEY (zoom_level, tile_column, tile_row));
        """)
        md = {"format": "pbf", "enc_vintage": "20261021",
              "json": json.dumps({"vector_layers": [{"id": "DEPARE", "fields": {}}]}),
              "bounds": "-125.45,45.75,-121.25,49.75",
              "data_bounds": "-125.40,45.80,-121.30,49.70",
              "region_bbox": "-125.5,46.0,-121.5,49.5"}
        con.executemany("INSERT INTO metadata VALUES (?,?)", list(md.items()))
        # band 3 (z10-11) and band 5 (z14-16) present, band 4 (z12-13) missing entirely
        for z in (10, 11, 14, 15, 16):
            con.execute("INSERT INTO tiles VALUES (?,?,?,?)", (z, 1, 1, b"x"))
        con.commit(); con.close()
        probs = bmp.verify_pack(path, {}, "holey")
    if not any("hold no tiles" in x for x in probs):
        fail("zoom window", f"a pack with an empty z12-13 window was accepted: {probs}")


def test_input_floor_rejects_a_truncated_enc_set():
    if bmp.MIN_EXPECTED_CELLS < 1000:
        fail("input floor", f"MIN_EXPECTED_CELLS is {bmp.MIN_EXPECTED_CELLS} — too low to "
                            f"distinguish a truncated download from a smaller chart world")


def run():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
            except Exception as ex:
                fail(name, f"raised {type(ex).__name__}: {ex}")


run()
if FAILURES:
    print(f"FAILED ({len(FAILURES)}):")
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)
print("marine pipeline: band windows, region coverage, clipping and pack refusals all check out")
