---
license: cc-by-4.0
tags:
  - aviation
  - geospatial
  - terrain
pretty_name: CommSight LZ — off-field landability fact tiles
---

# CommSight LZ — off-field landability fact tiles

Compressed raster **facts about ground**, built for the off-field landability layer in
[CommSight](https://flycommsight.com). One file per 1°×1° cell, named by the USGS 3DEP convention
(`n33w107` = the cell whose north-west corner is 33°N 107°W, so it spans lat 32–33, lon −107…−106).

> ### ⚠️ Advisory only — not for navigation
> These tiles describe terrain and land cover. They are **not** a survey, **not** a database of
> landing sites, and **not** a landing recommendation. Surface condition, fences, livestock, crops
> in season, wires below the charted-obstacle threshold and any current obstruction are **not
> modelled**. The absence of a depicted hazard is not evidence that none is there. Pilot-in-command
> judgment is final.

## What is in a pack

Six `uint8` planes per 256×256 tile, plus the tile's DEM provenance byte:

| plane | what it is |
|---|---|
| `class` | surface class (water, wetland, developed, canopy, crop, range, barren…) |
| `conf` | confidence in that class, scaled by the source's own confidence band |
| `slope` | median slope, 0–50.8° |
| `rough` | detrended surface roughness (residual σ) |
| `hazard` | fused obstacle/hazard field from towers, roads and transmission corridors |
| `flags` | bitfield — charted obstacle, corridor, road buffer, water, wetland, coarse terrain |

**Facts, never verdicts.** Nothing here knows what aircraft is flying. Scoring happens on the
device, where the pilot's glide ratio and performance re-tint the same ground — so the same tile
means different things to a Cub and to a Malibu, and changing aircraft costs no download.

MBTiles/SQLite containers, z6–z13, planes raw-DEFLATE. `index.json` at the repo root is the
catalog: a flat `cells[]` array with bounds, size, sha256 and per-source vintages, plus `regions[]`
grouping cells into areas a pilot would recognise.

Overviews never average. Point hazards take the worst child; areal textures take the second-worst
of four, because plain `max` compounds up a pyramid until the map excludes everything (measured:
16% → 73% between z13 and z8 on the first cell). Native resolution is untouched either way.

## Coverage

Grows as cells are built. `index.json` is authoritative — a cell absent from it does not exist.
Each entry publishes `coarse_terrain_tiles`: how much of that cell had only 10 m elevation
available, where the ditch- and berm-scale checks **cannot run** and the score is capped instead.

## Sources and attribution

| source | licence |
|---|---|
| USGS 3DEP elevation (1 m where published, else 1/3″) | public domain (US Gov) |
| USGS Annual NLCD land cover + confidence | public domain (US Gov) |
| USDA NASS Cropland Data Layer | public domain (US Gov) |
| USFWS National Wetlands Inventory | public domain (US Gov) |
| FAA Digital Obstacle File | public domain (US Gov) |
| US Census TIGER/Line roads | public domain (US Gov) |
| **Meta / WRI canopy height** | **CC-BY-4.0 — attribution required** |

Canopy height data © Meta Platforms, Inc. and World Resources Institute, used under
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Source imagery is from 2016, so canopy
here is roughly a decade old and reads **low** against present-day growth. Every other input is
United States federal public-domain data.

### No OpenStreetMap data is present in these tiles

Deliberately, and it is load-bearing rather than incidental. OSM is ODbL, and conflating ODbL
geometry into the hazard plane would make this a Derivative Database — a one-way door that could
compel opening data these tiles are intended to be combinable with. The hazard plane is built
solely from public-domain federal sources, and the build pipeline **proves** it: the planes are
rebuilt with the OSM artifact deleted and compared bit-for-bit.

## Verifying a pack

Files are stored as classic Git-LFS, not Xet, because the app fetches them with a plain anonymous
`GET`. If you re-host these, keep it that way:

```bash
curl -sL -o n33w107.lzpack \
  https://huggingface.co/datasets/SingularityUS/commsight-lz/resolve/main/cells/n33w107.lzpack
sqlite3 n33w107.lzpack "SELECT name, value FROM metadata WHERE name LIKE 'lz_%';"
```

The `sha256` in `index.json` is the authority on integrity.
