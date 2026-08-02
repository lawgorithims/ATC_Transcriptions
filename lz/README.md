# `lz/` — the CommSight LZ (off-field landing zone) fact-tile pipeline

Builds the **aircraft-agnostic, position-agnostic** world data that the CommSight app turns into an
advisory off-field landability heatmap. All heavy computation happens here, offline, on a desktop.
The iPad only applies aircraft-specific weighting and live ownship state.

> **Advisory only.** Nothing this pipeline produces is a certified navigation or landing-guidance
> product. It is not TAWS, not DO-276, not a terrain-avoidance database. It cannot know surface
> condition — mud, snow depth, standing water, crop height today, a fence put up last week. The
> absence of a depicted hazard is **not** evidence that there is no hazard. PIC judgment is final.

---

## The split — why the device does the last step

The pipeline emits **facts**, never verdicts. A verdict baked into a tile would be wrong for most
aircraft: a field that a 38-kt Cub can use is not a field a 120-kt single can use, and a
"developed open" park is a last resort for a fixed wing and a *preferred* site for a helicopter.

So each tile ships six quantised **fact planes**, and the app compiles the ruleset against the
pilot's aircraft profile into per-plane lookup tables plus veto/cap masks — the "murphy factors" —
and composites the final score at tile-serve time. Changing aircraft re-tints the map without
re-downloading anything.

Two consequences worth stating plainly:

- **Nonlinear across sources → here.** "Wet *and* open" is a deceptive-terrain trap that neither
  input implies alone, so it is resolved into its own column in this pipeline.
- **Nonlinear in the aircraft → on device.** Slope tolerance is a different *curve* per aircraft,
  not a scale factor, which is why the device gets LUTs rather than a multiplier.

---

## Sources and licences

Everything shipped inside a tile is US Government public domain or CC-BY. **OpenStreetMap is
quarantined** — see below.

| # | Source | Content | Licence | Refresh |
|---|---|---|---|---|
| T1 | USGS 3DEP DEM (1 m where flown, else 1/3″) | Bare-earth elevation | Public domain | Rolling |
| T3 | Annual NLCD + Land Cover Confidence | 16-class land cover | Public domain | Annual |
| T5 | Meta/WRI Global Canopy Height **v2** | Canopy height, 1 m | **CC-BY-4.0** | Static |
| T6 | USDA CDL | Crop type | Public domain | Annual (Feb) |
| T8 | USFWS NWI | Wetland polygons | Public domain | Slow |
| T9 | USGS NHDPlus HR | Rivers, waterbodies | Public domain | Slow |
| O1 | FAA DOF | Charted obstacles > ~200 ft | Public domain | 56-day |
| O2 | HIFLD transmission — **frozen snapshot** | High-voltage lines | Public domain | ⚠️ **dead upstream** |
| O8 | Census TIGER/Line roads | Road centrelines | Public domain | Annual |
| O3 | OpenStreetMap `power=*` | Distribution lines | **ODbL** | ⚠️ **quarantined** |

### ⚠️ HIFLD Open no longer exists

The HIFLD Open portal was withdrawn on **2025-08-25/26** and the site went down **2025-09-16**.
Layers moved to HIFLD *Secure*, which a commercial EFB vendor is unlikely to qualify for and which
almost certainly bars redistribution. EIA's Energy Atlas transmission layer is **not** an
independent replacement — EIA re-hosts HIFLD and says so.

So `lz/static/` holds a **frozen, vintage-stamped public-domain snapshot**, and the fetch adapter
reads it from disk and never touches the network. The pack metadata carries its real vintage, and
the UI must present it as a fixed-vintage layer — *not* as something quarterly-refreshed. A
decaying snapshot behind a UI that claims freshness is the failure mode to avoid.

### ⚠️ The ODbL quarantine — a one-way door

OSM is ODbL, which carries share-alike on any **Derivative Database**. Merging OSM geometry into a
fused wire table — clustering nearby lines, keeping the best, unioning attributes — is exactly what
converts a *Collective* Database (each source keeps its own licence) into a Derivative one. Were
proprietary wire detections ever fused into that same table, share-alike could reach them.

The structural defence, which must not be relaxed casually:

- `hazard.py` **has no OSM import.** The hazard plane is built solely from public-domain sources.
- OSM power lines are emitted as a **separate display-only GeoJSON** carrying
  `© OpenStreetMap contributors, ODbL`, never conflated with any other geometry.
- `verify.py` **proves** it: delete the OSM artifact, rebuild, and the planes must be bit-identical.

Note also that OSMF's own Produced Work guideline turns on whether the published result is *intended
for extraction of the original data*. Fact planes are a rendering input, but a queryable vector wire
layer is a different question — which is the other reason the OSM layer stays separate and visibly
attributed. Get counsel before changing this.

---

## Tile format

Per 256×256 tile, six `uint8` planes in this **positional** order (the device indexes by position):

| # | Plane | Encoding |
|---|---|---|
| 0 | `class` | surface class enum (`CLASS_*`) |
| 1 | `conf` | 0–100 %, 255 = unknown |
| 2 | `slope_signed` | 0–254 ↔ −25.4…+25.4° in 0.2° steps about 127; 255 = nodata. **Signed** — the uphill direction is the recommendation |
| 3 | `rough` | detrended residual σ in cm, 0–254; 255 = nodata |
| 4 | `hazard` | noisy-OR fused hazard, 0–255 ↔ H ∈ [0,1] |
| 5 | `flags` | bitfield (`FLAG_*`) |

Plus a per-tile `terrain_source` byte in the header.

### Two framing decisions that silently destroy the layer if flipped

1. **TMS rows, not XYZ.** The app's reader flips on read (`MBTilesReader.tileData`,
   `ChartMapView.swift:62`), per the MBTiles spec, so the packer writes TMS. Reversed, the pack
   still opens with the right tile count and renders **mirrored north-for-south**.
2. **Raw DEFLATE, not zlib.** Apple's `COMPRESSION_ZLIB` is raw DEFLATE with no wrapper, so planes
   use `zlib.compressobj(wbits=-15)`. Python's default `zlib.compress()` adds a 2-byte header the
   device rejects — and the symptom is not an error, it is a **fully transparent layer**, which
   reads as "no risk here".

### Overviews take the worst child, never the average

`hazard`/`rough` = max, `slope` = max-|·| keeping sign, `conf` = min, `flags` = OR,
`class` = worst by severity, `terrain_source` = coarse-if-any. Averaging a hazard plane invents
safe-looking ground between two towers; averaging slope flattens a cliff. `unknown` ranks above the
good classes on purpose — "we do not know" must not be diluted by three confident neighbours.

### `terrain_source` and the coarse-DEM cap

Roughly 20 % of CONUS has no 1 m 3DEP. Where the DEM is 1/3″, the micro-relief ("hidden ditch")
veto **physically cannot fire** — a 10 m posting cannot resolve a 1.5 m ditch. That ground would
otherwise score *better* than lidar-covered ground purely because its vetoes went quiet. Each tile
therefore carries its DEM provenance and the device caps any tile that is not `fine_1m`.

---

## Pilot cell

`n33w107` — Las Cruces, New Mexico (lat 32–33 N, lon −107…−106 W). Chosen because one cell exercises
every rule class: KLRU and the irrigated Mesilla Valley (good fields), the Organ Mountains (the
energy-layer ridge case), the Rio Grande (water veto), and open Chihuahuan desert scrub.

Note the master grid is ~10 919 × 12 515 cells, not the ~9 400 × 11 100 the cell size suggests:
EPSG:5070 is a *conic* projection centred on −96°, so the quad arrives rotated ~6.3° and fills only
82 % of its own bounding box. Budget memory for the bbox.

---

## Running it

```bash
python3 lz/lzcommon.py --selftest      # geometry, projection vs GDAL, blob round-trip
python3 lz/fetch.py    --probe         # cheap version check, no downloads
python3 lz/fetch.py    --fetch
python3 lz/fetch.py    --assert-coverage
python3 lz/terrain.py  --build --verify
python3 lz/surface.py  --build --verify
python3 lz/hazard.py   --build --verify
python3 lz/package.py  --build
python3 lz/verify.py                   # the oracle gate
```

Every stage is resumable and writes provenance into `lz/data/<cell>/manifest.json`.
Requires `python3`, `numpy`, and the GDAL **command line** tools (no `osgeo` Python bindings).

### Installing the pack into the app (dev)

The pack is not bundled — the app scans `Application Support/lz/` for `*.lzpack`:

```bash
xcrun simctl get_app_container booted com.commsight.atc data
```

Copy `lz/out/n33w107.lzpack` into `<container>/Library/Application Support/lz/`, then enable
**LZ risk (dev)** in the map layers panel (7-tap the version row in Settings to unlock diagnostics).

Hosting on Hugging Face is deferred. When it happens it must use **classic Git-LFS** — anonymous
Xet-backed resolves 403 for the app (see `charts/rehost_classic_lfs.sh`).

---

## Fetch adapters must fail loud

Every adapter implements `probe()` / `fetch()` / `assert_coverage()`. `probe()` returns a cheap
version token (ETag, release tag, cycle date) so a poll costs nothing when nothing changed.

`assert_coverage()` exists because of one specific failure: if a source moves, changes schema, or
404s and the pipeline quietly emits an empty layer, **the app renders that as "no wires here"** —
the worst output this product can produce. A missing source must break the build, not thin the
hazard plane. The adapter must also distinguish *unchanged because stable* from *unchanged because
dead*, which is precisely the HIFLD case above.
