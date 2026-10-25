# Marine / water-ops layer — build pipeline

Optional map layer for seaplane pilots, built from **NOAA Electronic Navigational Charts (ENC)**.
Off by default, download-gated, hosted as its own dataset (`SingularityUS/commsight-marine`) rather
than a fourth family inside `faa-charts` — see *House rules* below.

```
charts.noaa.gov/ENCs/All_ENCs.zip          822 MB, 7,303 cells, rebuilt weekly
        │
        ├─ enc_index.py            ──▶ enc_index.json      (band, scale, issue date, M_COVR bbox)
        ├─ build_marine_packs.py   ──▶ <region>.mbtiles    (vector tiles, per region)
        └─ publish.py                                      ── NOT YET WRITTEN
```

## Running it

```bash
mkdir -p /tmp/marine/enc && cd /tmp/marine/enc
curl -fsS -o All_ENCs.zip https://charts.noaa.gov/ENCs/All_ENCs.zip
unzip -tqq All_ENCs.zip && unzip -oq All_ENCs.zip          # validate BEFORE trusting it

python3 marine/enc_index.py /tmp/marine/enc/ENC_ROOT /tmp/marine/enc_index.json
python3 marine/build_marine_packs.py --index /tmp/marine/enc_index.json \
        --out /tmp/marine/out --region puget_sound
python3 marine/test_marine_packs.py
```

Indexing all 7,303 cells takes about a minute. One region takes 2–6 minutes.

## Why ENC, and not NOAA's own chart tiles

The plan this work came from assumed we would copy NOAA's pre-rendered raster tiles. **Both routes
to them are dead ends.** Measured 2026-10-23:

| Route | Result |
|---|---|
| NCDS pre-built MBTiles | The ArcGIS layer the download page drives itself from (`MarineChart_Services/ncds_tilecache_metadata`) returns **HTTP 500 "Could not find service. Service may be stopped"**; the NCDS viewer 404s. The page *is* the API, so there is no URL pattern to fall back on. |
| NOAACharts WMTS | Advertises `GoogleMapsCompatible` z0–19, but z0–z7 return blank 190–355 byte tiles and **z≥8 returns HTTP 400 "Invalid URL" even for tile 0/0**. The tile-matrix alias is not actually served. |
| MCS WMS | **Works** — real S-52 charts, `EX_GeographicBoundingBox` global, 13 display groups, PNG. But it renders on demand at **~350 ms/tile** with no useful gain from parallel connections. Covering eight seaplane regions to z16 is 17.0 M tiles ≈ **69 days** of continuous scraping and ~290 GB at the measured mean tile size. Infeasible, and an abuse of a public service. |

Rendering from ENC is one 822 MB download and then local CPU. It is also **strictly better for this
feature**: ENC is the source NOAA itself renders from, the hazard attributes arrive as queryable
data rather than painted pixels, and we decide what a seaplane pilot sees instead of cloning a
mariner's chart.

GDAL's WMS driver *does* work against the MCS endpoint if raster is ever needed
(`gdal_translate -of MBTILES` over a `<GDAL_WMS>` service XML), but note it exits **0** after
logging `ReadBlockFromFile failed` on a dropped tile — a partial pack with a success status.

> An earlier revision of this table said "≈20 days". That divided by four for parallel connections
> in the same breath as stating there is no useful gain from them. 17.0 M tiles × 350 ms serially
> is 68.9 days; a re-probe measured 573 ms/tile, which is 113 days. The conclusion was right and
> the arithmetic was not.

## Usage band → zoom window

ENC ships the same water at six generalisations. Each cell declares its band in `DSID_INTU` and its
true compilation scale in `DSPM_CSCL`; both are read from the data, never parsed from the filename.

| Band | | Zooms | Cells | Median scale | Natural zoom |
|---|---|---|---|---|---|
| 1 | Overview | z4–7 | 24 | 1:3,500,000 | 7.3 |
| 2 | General | z8–9 | 108 | 1:811,980 | 9.4 |
| 3 | Coastal | z10–11 | 343 | 1:180,000 | 11.6 |
| 4 | Approach | z12–13 | 2,307 | 1:90,000 | 12.6 |
| 5 | Harbour | z14–16 | 4,457 | 1:12,000 | 15.5 |
| 6 | Berthing | z17 | 64 | 1:4,000 | 17.1 |

These windows are **measured, not taken from the S-52 scale table** — the textbook ranges put bands
1–3 fully 1.5–2 zoom levels coarser than the scale their cells are actually compiled for. Each
window now *ends* at or just below its band's natural zoom, so no cell is pushed past the scale it
was surveyed for.

The windows are **disjoint and contiguous**, which is load-bearing: it means no two bands can emit
the same `(z, x, y)`, so band packs merge by plain concatenation with no precedence rule, and it
means every tile has exactly one chart authority rather than two contradictory depth areas.
`test_marine_packs.py` fails if anyone widens a window.

## What was measured

Built from the **2026-10-21** set.

| Region | Cells | Tiles | Size | Bands |
|---|---|---|---|---|
| `puget_sound` | 292 | 92,607 | 95.8 MB | 1–5 |

Known hazards from the Tacoma cell `US5WA22M`, verified by decoding the finished pack's z16 tiles:

| Hazard | Charted | Recovered from pack |
|---|---|---|
| Overhead cable | 14.0 m / 46 ft | ✓ |
| Overhead cable | 52.7 m / 173 ft | ✓ |
| Hylebos-area bridge | 8.8 m | ✓ |

## Two findings that constrain the feature

### 1. Unknown clearance is the *majority* case

Counted once per feature from the source cells of the `puget_sound` region box:

| | Has `VERCLR` | Only closed-position `VERCCL` | **No clearance at all** |
|---|---|---|---|
| `CBLOHD` overhead cables (533) | 43.7 % | — | **56.3 %** |
| `BRIDGE` (1,211) | 13.0 % | 5.7 % | **81.3 %** |

By band, the picture is worse the further out you look: band 3 cables are 89 % unknown, band 4
55 %, band 5 50 %. `VERCCL` is the clearance in the **closed** position, which is not the
clearance an aircraft gets, so it cannot be counted as known.

A cable with no charted clearance must render as **"clearance not charted"** and must never be
dropped from the tile. A cable you cannot see is more dangerous than one whose height you do not
know. `encspec.CLEARANCE_BEARING_LAYERS` marks the classes this applies to, and
`verify_hazards_reach_the_tiles()` decodes real tiles to confirm they survived the build.

> ⚠️ An earlier revision of this table published **39.2 %** and **60.5 %** with denominators of
> 186 and 334. Those came from scanning only the pack's z16 tiles and de-duplicating by feature
> id — which misses every feature whose band does not reach z16 and cannot de-duplicate reliably
> across tile boundaries. The error ran in the direction that makes charted clearance look *more*
> available than it is, by 17 and 21 points. Measure this from the source cells, not from tiles.

### 2. NOAA does not chart most seaplane water

Measured over **all 561** `site_type='C'` seaplane bases in `apt.sqlite` (not a sample), testing
for a charted water feature within 2 km:

| | bases | share |
|---|---|---|
| Harbour or berthing (z14+) | 126 | 22.5 % |
| Approach (z12–13) | 59 | 10.5 % |
| Coastal or coarser | 9 | 1.6 % |
| **No charted water within 2 km** | **367** | **65.4 %** |

So **33.0 %** have approach-or-better coverage — genuinely useful for a landing decision — and
roughly two thirds have nothing. Confirmed uncharted, all `site_type='C'`: St Peters and Van Buren
ME, Joe Clouds AK, Cutfoot Sioux and Christenson Point MN, Lakeside Lodge and Lucky Landing ME.

> ⚠️ An earlier revision led with "Lake Hood, Anchorage — the busiest seaplane base in the world —
> is not charted." That was wrong twice over: Lake Hood (LHD) is `site_type='A'` in `apt.sqlite`,
> so it is not one of the 561 bases this section is about, and charted `DEPARE`/`SEAARE` lie about
> 1,400 m from its coordinate — inside the 2 km threshold, so this test scores it as *covered*.
> Note also that a 2 km radius is generous: it says NOAA charts water nearby, not that it charts
> the water you would land on.

**The marine chart layer cannot be the whole feature.** It serves coastal and navigable-river
operations very well — the Inside Passage, Puget Sound, the Columbia/Snake, Lake Champlain and the
NY canals, the SF Delta, the Florida coast — and not the inland lakes that are the majority of US
float flying. The inland waterbody source (USGS NHD, labelled explicitly as *uncharted*: no
bathymetry, no obstruction survey) is the larger half of the work, not an optional later phase.

## House rules this pipeline follows

- **Its own dataset repo**, per `lz/publish.py`: *"house style is one repo per content class."*
  `charts/publish_packs.py` also hardcodes a family registry iterated as the authoritative key set
  in nine places, and its currency maths is FAA 56-day cycles — ENC updates weekly, so a marine
  pack forced through that model would mis-report its own currency.
- **The artifact carries its own provenance.** `enc_vintage` is stamped into the MBTiles
  `metadata` table, mirroring `faa_cycle` in the FAA packs, and is derived from the newest
  `DSID_ISDT` among the cells in the pack — so a pack built from a stale download cannot label
  itself current. A pack with no vintage is never written.
- **Every indexed cell must land in a region.** The first `regions.conf` missed 585 of 7,303 cells
  and the miss was not in the ocean: 82 harbour cells on the Columbia/Snake, 62 on Lake Champlain
  and the NY canals, 41 on the lower Columbia, 25 in the SF Delta, 22 on Lake Winnebago. Prime
  floatplane water, lost to a region list that looked complete because it named every coast.
- **Features are clipped, not merely spatially filtered.** A band-1 coastline is one geometry
  running from Mexico to Alaska, so filtering alone left the Puget Sound pack advertising
  `bounds=-134.4,38.4,-116.3,61.25`. The client picks a pack by its bounds, so that pack would have
  been selected for water it holds no soundings for.
- **Reconciliation only compares cells wholly inside the region.** Comparing clipped edge cells
  against whole-cell counts produced two false aborts on the first run. A guard that cries wolf on
  correct output is worse than none, because people learn to pass it with `--force`.

## The publisher

`marine/publish.py`, modelled on `lz/publish.py`: merges into the hosted catalog rather than
overwriting it, verifies every upload with an anonymous ranged GET the way the app fetches, uploads
the index last, and forces `HF_HUB_DISABLE_XET=1` before importing `huggingface_hub`.

```bash
python3 marine/publish.py --list
python3 marine/publish.py --dry-run --index /tmp/marine/enc_index.json
python3 marine/publish.py --publish --index /tmp/marine/enc_index.json
```

Two things it does that the other publishers do not:

- **It distinguishes "no catalog yet" from "cannot read the catalog".** HuggingFace will not leak
  repo existence, so a dataset that does not exist answers **401, not 404**, for every path under
  it. Measured: repo present + file present → `/api/datasets` 200, index 206; repo present + file
  absent → 200 / **404**; repo absent → **401 / 401**. A 401 on the index is therefore ambiguous
  and is disambiguated by probing the repo. The dangerous case — repo present, catalog not
  anonymously readable — is refused, because if this script cannot read it anonymously then
  neither can the app, and composing a fresh index would take every other region away from every
  pilot who has one. (`publish_nav.py --stage-next` did exactly that once and would have written
  `"datasets": {}` over the live manifest.)
- **It refuses a pack older than the ENC data available for its own region** (`--index`), not one
  older than its sibling packs. The sibling comparison was tried and is provably noisy: 12 of the
  43 regions have no cell newer than 2026-10-01 simply because that is when NOAA last reissued
  them, and `antarctica`'s newest available cell is 2025-05-13 — 521 days old and perfectly
  current. Vintage spread between regions is real survey currency, not staleness.

It must run in an environment with `huggingface_hub`; on this machine that is `~/chartenv`, which
has no GDAL. `publish.py` therefore imports only `encspec` (free of third-party imports) and never
`build_marine_packs`, which imports `osgeo` at module scope. Importing the latter made the
publisher unable to run anywhere at all.

## Not yet built

- Client `MarinePackLibrary` + `NetworkActivity.Category.marine` + a `/marine/…` provider on
  `MBTilesHTTPServer`, following the LZ pattern.
- MapLibre vector source/layers and a seaplane-specific style. **Vector tiles cannot render on
  MapKit**, so the marine toggle must be *hidden* when `useMapLibreMap` is false (which defaults
  **true**, `AppModel.swift:767`) rather than left silently dead.

  > ⚠️ An earlier revision justified this by claiming `showHazards`/`showSmoke` are "read only
  > inside `ChartMapView.updateUIView` and therefore inert for the majority of pilots who get
  > MapLibre". That is not true and is a bad precedent to cite. Only the *map overlay* is
  > MapKit-only (`ChartMapView.swift:970`); `showHazards` also gates hazard **fetching**
  > (`AppModel.swift:4185`) and the hazard **alert** (`AppModel.swift:4222`, `:4272`), both of
  > which work regardless of engine. The marine case stands on its own: a vector source has no
  > MapKit renderer at all.
- Inland waterbodies from USGS NHD (see finding 2 — this is the larger half).
- Restriction advisories (NPS / wilderness / USACE) with sourced wording that never states
  permission.

## Open questions

- **Licensing.** data.gov metadata for NOAA ENC says *"Limitations of use: None (Public Domain)"*
  and the packs carry NOAA attribution. Confirm with Coast Survey before re-hosting derived tiles.
- Total volume for all 43 regions. The three built packs give 2.9–7.1 GB depending on which
  per-cell rate you extrapolate from (Puget Sound's 95.8 MB / 292 cells scales to 4.3 GB over the
  13,116 cell-region assignments); call it **~4.8 GB** hosted. An earlier revision said "8–15 GB",
  which its own stated basis did not support.
- Whether lower-band cells should be clipped to the `M_COVR` coverage of higher-band cells. Not
  needed while the zoom windows are disjoint, but it is what would allow a band to extend past its
  own window into areas the next band does not cover.
