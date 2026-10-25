#!/usr/bin/env python3
"""encspec.py — the data contract for the marine (water-ops) layer.

ONE SOURCE OF TRUTH for: which S-57 object classes we carry, which of their attributes survive
into the tiles, and which zoom levels each ENC usage band is rendered at. `enc_index.py` and
`build_marine_packs.py` both import this; nothing else should hardcode a layer or field name.

Source: NOAA "All_ENCs.zip" — the complete US Electronic Navigational Chart set (~822 MB zipped,
~2.1 GB expanded, 7,303 cells), rebuilt weekly. Public domain (US Government work).

    https://charts.noaa.gov/ENCs/All_ENCs.zip

WHY WE RENDER FROM ENC RATHER THAN RE-TILING NOAA'S OWN CHART IMAGERY
--------------------------------------------------------------------
The original plan was to copy NOAA's pre-rendered raster tiles. Both routes to them are dead ends,
measured 2026-10-23:

  * NCDS pre-built MBTiles — the manifest layer that the download page drives itself from
    (`MarineChart_Services/ncds_tilecache_metadata`) returns HTTP 500 "Could not find service.
    Service may be stopped or it may not be configured", and the NCDS viewer 404s. There is no
    published URL pattern to fall back on; the page *is* the API.
  * NOAACharts WMTS — advertises `GoogleMapsCompatible` z0-19, but z0-z7 return blank 190-355 byte
    tiles and z>=8 returns HTTP 400 "Invalid URL" even for tile 0/0. The alias is not actually served.
  * MCS WMS (`MCS/NOAAChartDisplay/.../WMSServer`) DOES work and renders real S-52 charts — but it
    renders on demand, measured at ~350 ms/tile with no useful gain from parallel connections.
    Covering just the eight seaplane regions below to z16 is 17.0 M tiles ≈ 20 days of continuous
    scraping and ~200 GB. That is both infeasible and an abuse of a public service.

Rendering from ENC instead is one 822 MB download, then local CPU. It is also strictly better for
this feature: ENC is the *source* NOAA renders from, so we lose nothing, we get the attributes
(cable clearance, depth values) as queryable data rather than painted pixels, and we decide what a
seaplane pilot sees instead of cloning a mariner's chart.

THE HONESTY CONSTRAINT, MEASURED
--------------------------------
Across the whole puget_sound region of the 2026-10-21 set, counted once per feature from the
source cells: **56.3% of overhead cables (300 of 533) and 81.3% of bridges (984 of 1,211) carry no
charted vertical clearance at all.** A further 5.7% of bridges give only VERCCL, the clearance in
the CLOSED position, which is not the clearance an aircraft gets.

Unknown clearance is therefore the MAJORITY case, not the exception. A cable with no VERCLR must
render as "clearance not charted" and must never be dropped from the tile — a cable you cannot see
is worse than one whose height you do not know. `CLEARANCE_BEARING_LAYERS` marks the classes where
this applies so the client style and its tests can enforce it.

⚠️ An earlier version of this file cited "the Tacoma harbour cell US5WA22M, 10 cables, only 2 with
VERCLR". That cell is downloadable individually from charts.noaa.gov/ENCs/US5WA22M.zip but is NOT
in All_ENCs.zip and is not in the 7,303-cell index — so the figure, while measured from real NOAA
data, came from a cell this pipeline never reads. The percentages above are re-derived from cells
that are actually in the set. Anchor a measurement to the input the pipeline consumes, or it
describes something else.
"""

# ── Usage band → zoom window ────────────────────────────────────────────────────────────────────
# ENC cells carry an "intended usage" band in DSID_INTU (1 Overview … 6 Berthing); the band, not
# the filename, is authoritative — read it from the data. Each band is compiled for a scale range,
# so each gets the Web Mercator zooms whose scale denominator (559082264 / 2^z) matches.
#
# These windows are MEASURED, not taken from the S-52 scale table. Running enc_index.py over the
# 2026-10-21 set and comparing each band's median DSPM_CSCL against natural_zoom() showed the
# textbook ranges put bands 1-3 fully 1.5-2 zoom levels coarser than the scale they are actually
# compiled for — band 1's cells are 1:3.5 M (natural z7.3), not the 1:1.5 M the band nominally
# starts at.
#
# ⚠️ THESE WINDOWS DO NOT GUARANTEE "never overscale", and an earlier version of this comment
# claimed they did. Two reasons it is false:
#   * Bands 4 and 5 end ABOVE their median natural zoom — band 4 runs to z13 against a natural
#     z12.6, band 5 to z16 against z15.5. That is about half a zoom level of deliberate overscale,
#     which is reasonable (the alternative is a visible detail cliff mid-region) but it is
#     overscale, and ENC's own display standard is the thing that raises a warning for it.
#   * natural_zoom() is LATITUDE-BLIND. scale_at_zoom() is the standard WMTS denominator at the
#     equator, but Web Mercator's scale factor is 1/cos(latitude), so at the latitudes this feature
#     actually targets a tile covers far less ground than the nominal figure: ×2.0 at Puget Sound
#     (47.6°N) and ×2.1 at Juneau (58.3°N), i.e. roughly one extra zoom level of effective
#     overscale. Use natural_zoom_at() when the latitude matters.
# The windows are kept as they are because the alternative — shifting every band down a level to
# satisfy an equator-referenced rule — would throw away a zoom level of real detail everywhere.
# What is not kept is the claim that no cell is ever shown past its surveyed scale.
#
# The windows are DELIBERATELY NON-OVERLAPPING: approach and harbour cells cover the same water
# with different generalisations of the same depth areas, so admitting both at one zoom would put
# two contradictory DEPARE polygons in the same tile with no way for a style to choose. One band
# per zoom means every tile has exactly one authority. `coverage_band` records what that costs.
BAND_ZOOM = {
    1: (4, 7),    # Overview   — median 1:3,500,000  (natural z7.3)
    2: (8, 9),    # General    — median 1:811,980    (natural z9.4)
    3: (10, 11),  # Coastal    — median 1:180,000    (natural z11.6)
    4: (12, 13),  # Approach   — median 1:90,000     (natural z12.6)
    5: (14, 16),  # Harbour    — median 1:12,000     (natural z15.5)
    6: (17, 17),  # Berthing   — median 1:4,000      (natural z17.1)
}
BAND_NAME = {1: "overview", 2: "general", 3: "coastal", 4: "approach", 5: "harbour", 6: "berthing"}

def band_windows(bands_present):
    """Zoom window per band for ONE region, given only the bands that region actually has.

    BAND_ZOOM is the ideal: each band owns an exclusive window and the six of them tile z4-17. But
    a region does not necessarily have a cell in every band — the Great Lakes have no band-3
    (coastal) cells at all, so lake_superior, lake_michigan_huron and wisconsin_inland hold bands
    [2, 4, 5, 6]. Using BAND_ZOOM verbatim then leaves z10-11 with no tiles in the middle of a pack
    advertising z8-17, and MapLibre asks for those zooms and draws nothing: the layer vanishes over
    two zoom levels and reappears.

    So each present band keeps its own upper bound and has its LOWER bound dropped to meet the
    previous present band. Lake Superior becomes band 2 → z8-9, band 4 → **z10**-13, band 5 → z14-16,
    band 6 → z17: contiguous, still non-overlapping, so the lossless tile-key merge still holds.

    Extending the FINER band downward is deliberate and is the only safe direction. A band-4 cell
    shown at z10 is drawn at a coarser zoom than its 1:90,000 compilation warrants — the pilot sees
    more detail than the zoom strictly needs, which costs tile bytes and nothing else. Extending the
    COARSER band upward instead would mean drawing a 1:812,000 cell at z11, which is overscale, the
    one condition ENC's own display standard raises a warning for.

    Nothing is extended BELOW the first present band: a region with no band-1 cell honestly reports
    its minzoom rather than stretching a general-scale cell across the whole world.
    """
    present = sorted(b for b in bands_present if b in BAND_ZOOM)
    out, prev_hi = {}, None
    for b in present:
        lo, hi = BAND_ZOOM[b]
        out[b] = (lo if prev_hi is None else prev_hi + 1, hi)
        prev_hi = hi
    return out


MIN_ZOOM = min(z[0] for z in BAND_ZOOM.values())
MAX_ZOOM = max(z[1] for z in BAND_ZOOM.values())

# ── Object classes we carry ─────────────────────────────────────────────────────────────────────
# Keyed by S-57 acronym → the attributes we keep. Everything not listed is dropped: a raw ENC
# layer arrives with 24-42 fields, nearly all S-57 housekeeping (LNAM, FFPT_RIND, RCID, …), and
# carrying them inflated the Tacoma test pack to 2.0 MB for a single cell.
#
# `None` means "keep the whole schema" and is used by nothing — it exists so an experiment does
# not have to edit the loader.
#
# ⚠️ Fields are INTERSECTED with each cell's real schema at build time, never passed blind.
# `ogr2ogr -select` on a field a layer does not have does not warn — it silently emits ZERO
# features. Asking CBLOHD for CATBRG (a BRIDGE attribute) is how all 10 Tacoma cables vanished
# from a readback that had reported them present minutes earlier.
LAYERS = {
    # — what will kill you ————————————————————————————————————————————————————————————
    "CBLOHD": ["OBJNAM", "VERCLR", "VERCSA", "CATCBL", "CONDTN", "STATUS"],   # overhead cable
    "BRIDGE": ["OBJNAM", "VERCLR", "VERCCL", "VERCOP", "CATBRG", "HORCLR"],   # bridge
    "PYLONS": ["OBJNAM", "CATPYL", "HEIGHT", "VERLEN"],                       # pylon / bridge support
    "OBSTRN": ["OBJNAM", "CATOBS", "VALSOU", "WATLEV", "EXPSOU", "HEIGHT"],   # obstruction
    "WRECKS": ["OBJNAM", "CATWRK", "VALSOU", "WATLEV", "EXPSOU", "HEIGHT"],   # wreck
    "UWTROC": ["OBJNAM", "VALSOU", "WATLEV", "EXPSOU"],                       # underwater rock
    "MARCUL": ["OBJNAM", "CATMFA", "VALSOU", "WATLEV"],                       # marine farm — fish pens
    "WATTUR": ["OBJNAM", "CATWAT"],                                           # water turbulence
    "OFSPLF": ["OBJNAM", "CATOFP", "HEIGHT", "VERLEN"],                       # offshore platform

    # — can you get in and out ————————————————————————————————————————————————————————
    "DEPARE": ["DRVAL1", "DRVAL2", "QUASOU"],                                 # depth area
    "DRGARE": ["DRVAL1", "DRVAL2", "OBJNAM"],                                 # dredged area
    "DEPCNT": ["VALDCO"],                                                     # depth contour
    "SOUNDG": ["DEPTH"],                                                      # soundings (ADD_SOUNDG_DEPTH)
    "SBDARE": ["NATSUR", "NATQUA", "OBJNAM", "WATLEV"],                       # seabed — beaching surface
    "LNDARE": ["OBJNAM"],                                                     # land
    "COALNE": ["CATCOA", "OBJNAM"],                                           # coastline
    "SLCONS": ["CATSLC", "OBJNAM", "WATLEV"],                                 # docks, piers, ramps
    "PONTON": ["OBJNAM", "CONDTN"],                                           # floating dock
    "MORFAC": ["OBJNAM", "CATMOR", "BOYSHP"],                                 # mooring / buoy
    "SMCFAC": ["OBJNAM", "CATSCF"],                                           # small-craft facility
    "ACHARE": ["OBJNAM", "CATACH", "RESTRN"],                                 # anchorage
    "LAKARE": ["OBJNAM", "ELEVAT"],                                           # lake
    "RIVERS": ["OBJNAM"],                                                     # river
    "CANALS": ["OBJNAM"],                                                     # canal
    "SEAARE": ["OBJNAM", "CATSEA"],                                           # named water body

    # — where you may not be ——————————————————————————————————————————————————————————
    "RESARE": ["OBJNAM", "RESTRN", "CATREA"],                                 # restricted area
    "CTNARE": ["OBJNAM", "INFORM"],                                           # caution area
    "MIPARE": ["OBJNAM", "CATMPA", "RESTRN"],                                 # military practice
    "CBLARE": ["OBJNAM", "RESTRN"],                                           # submarine cable area
    "PIPARE": ["OBJNAM", "RESTRN"],                                           # pipeline area
    "PIPSOL": ["OBJNAM", "CATPIP", "DRVAL1"],                                 # submarine pipeline
    "DMPGRD": ["OBJNAM", "RESTRN"],                                           # dumping ground
    "FAIRWY": ["OBJNAM", "RESTRN"],                                           # fairway
    "TSSLPT": ["OBJNAM"],                                                     # traffic separation lane
    "DWRTPT": ["OBJNAM"],                                                     # deep-water route

    # — orientation ————————————————————————————————————————————————————————————————————
    "LIGHTS": ["OBJNAM", "CATLIT", "COLOUR", "HEIGHT", "SIGPER"],
    "BOYSPP": ["OBJNAM", "CATSPM", "COLOUR", "BOYSHP"],
    "BOYLAT": ["OBJNAM", "CATLAM", "COLOUR", "BOYSHP"],
    "BCNSPP": ["OBJNAM", "CATSPM", "COLOUR"],
    "BCNLAT": ["OBJNAM", "CATLAM", "COLOUR"],
    "LNDMRK": ["OBJNAM", "CATLMK", "HEIGHT", "FUNCTN"],
    "BUISGL": ["OBJNAM", "FUNCTN", "HEIGHT"],                                 # single building
    "BUAARE": ["OBJNAM", "CATBUA"],                                           # built-up area
    "AIRARE": ["OBJNAM"],                                                     # airport/airfield on the chart
}

# Classes whose whole purpose is a vertical clearance. If one of these loses its clearance
# attribute it must still be carried and rendered as "not charted" — see the module docstring.
CLEARANCE_BEARING_LAYERS = ("CBLOHD", "BRIDGE")

# Classes a pilot must be able to see even when generalisation would normally drop them.
#
# ⚠️ THIS IS DOCUMENTATION, NOT A MECHANISM, AND IT USED TO PRETEND OTHERWISE. The builder turned
# this tuple into a per-layer MVT `CONF` of {"CBLOHD": {"simplification": 0}, ...} and believed it
# was protecting point hazards. GDAL's MVT writer reads only target_name / description / minzoom /
# maxzoom per layer — SIMPLIFICATION is a DATASET-level option with no per-layer equivalent — so
# the key was silently ignored and the exemption did nothing. The tests that covered it only
# checked that these names were spelled correctly, which they were.
#
# Simplification is now declared once for the whole pack (build_marine_packs.MVT_SIMPLIFICATION,
# set to 0) and hazard survival is VERIFIED rather than requested: verify_hazards_reach_the_tiles()
# takes real features out of the GeoPackage, computes the tile each must occupy, and decodes that
# tile. This tuple is what that check iterates over.
NEVER_SIMPLIFY = ("CBLOHD", "BRIDGE", "OBSTRN", "WRECKS", "UWTROC", "PYLONS", "MARCUL", "OFSPLF")

# S-57 driver options. SPLIT_MULTIPOINT + ADD_SOUNDG_DEPTH turn SOUNDG's multipoint soundings into
# one point per depth with a DEPTH attribute, which is the only form a vector tile can carry.
# RETURN_PRIMITIVES/RETURN_LINKAGES off drop the topology tables we never read.
OGR_S57_OPTIONS = (
    "RETURN_PRIMITIVES=OFF,RETURN_LINKAGES=OFF,LNAM_REFS=OFF,"
    "SPLIT_MULTIPOINT=ON,ADD_SOUNDG_DEPTH=ON,RECODE_BY_DSSI=ON"
)

# Web Mercator scale denominator at a zoom level, for cross-checking a cell's DSPM_CSCL against
# the band window it was assigned.
def scale_at_zoom(z: int) -> float:
    return 559082264.0287178 / (2 ** z)

def natural_zoom(compilation_scale: int) -> float:
    """The zoom whose EQUATOR scale denominator matches a cell's compilation scale.

    Latitude-blind on purpose — this is the figure the band windows were chosen against, and the
    one enc_index.py reports. For what a pilot actually sees, use natural_zoom_at()."""
    import math
    if not compilation_scale or compilation_scale <= 0:
        return float("nan")
    return math.log2(559082264.0287178 / compilation_scale)


def natural_zoom_at(compilation_scale: int, latitude: float) -> float:
    """natural_zoom() corrected for Web Mercator's 1/cos(latitude) scale factor.

    A tile at 48°N covers about half the ground a tile at the equator does, so a cell reaches its
    compilation scale a full zoom level EARLIER than natural_zoom() suggests. At the latitudes this
    feature targets the difference is one whole level, which is the difference between modest and
    material overscale."""
    import math
    z = natural_zoom(compilation_scale)
    if z != z:                              # NaN
        return z
    lat = max(-85.0, min(85.0, latitude))
    return z - math.log2(1.0 / math.cos(math.radians(lat)))


# ── Shared with the publisher ───────────────────────────────────────────────────────────────────
# ⚠️ THESE LIVE HERE, NOT IN build_marine_packs, BECAUSE THE PUBLISHER MUST NOT NEED GDAL.
# publish.py imported build_marine_packs for exactly these two things, and that module imports
# osgeo at module scope — so the publisher could not run anywhere on this machine: the only
# environment with huggingface_hub (~/chartenv) has no GDAL, and the environment with GDAL has no
# huggingface_hub. It failed with ModuleNotFoundError: No module named 'osgeo' before reaching a
# single line of its own code. encspec.py is deliberately free of third-party imports.

# Features are CLIPPED to the region box grown by this margin, not merely spatially filtered, so
# that a feature crossing a region edge still meets its neighbour without a seam.
CLIP_MARGIN_DEG = 0.25


def load_regions(path):
    """Parse regions.conf into [{name, label, bbox}]. Refuses rather than guessing."""
    import sys
    regions = []
    with open(path) as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 6:
                sys.exit(f"{path}:{ln}: expected 6 fields, got {len(parts)}: {raw.rstrip()}")
            name, label = parts[0], parts[1]
            try:
                w, s, e, n = (float(parts[2]), float(parts[3]), float(parts[4]), float(parts[5]))
            except ValueError:
                sys.exit(f"{path}:{ln}: non-numeric bbox: {raw.rstrip()}")
            if not (w < e and s < n):
                sys.exit(f"{path}:{ln}: bbox is not min<max: {w},{s},{e},{n}")
            regions.append({"name": name, "label": label, "bbox": [w, s, e, n]})
    if not regions:
        sys.exit(f"{path}: no regions defined")
    names = [r["name"] for r in regions]
    dupes = {x for x in names if names.count(x) > 1}
    if dupes:
        sys.exit(f"{path}: duplicate region name(s): {sorted(dupes)}")
    return regions
