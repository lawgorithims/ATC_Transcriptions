# ⛔ EXPERIMENTAL — DO NOT MERGE

**Branch:** `experimental/maplibre-globe-prototype`

This branch is a **throwaway spike**, not production work. **Do not merge it into `main`/`plates-georef`.**
It exists to answer one question before we ever commit to a big migration:

> Could we replace `MKMapView` with a custom GPU chart renderer — specifically **MapLibre Native** — to get
> (a) a **3D globe** (which MapKit cannot render) and (b) the **on-demand, idle-at-0-fps rendering** that
> makes ForeFlight so much more battery/thermal efficient than our current map?

## Why this exists

Build-60 battery telemetry confirmed the drain is the **idle MKMapView itself** (thermal climbed nominal →
serious in ~13 min with the app idle, just showing the map). MKMapView is a general-purpose consumer-maps
engine that's always working; a purpose-built chart renderer draws only when the picture changes. This spike
evaluates the realistic path to that (MapLibre Native, rather than a from-scratch Metal renderer).

## What's in this branch

- `project.yml`: adds the **MapLibre** SwiftPM package (prebuilt XCFramework distribution, 6.x — supports
  the globe projection). **Experimental dependency; not on `main`.**
- `ATCTranscribe/Experimental/MapLibrePrototypeView.swift`: a self-contained `UIViewRepresentable` around
  `MLNMapView` that renders:
  1. a **globe** (style `projection: globe`),
  2. **real FAA sectional raster tiles** on the sphere (via ChartBundle's public XYZ endpoint — a *prototype*
     tile source, see TODO), and
  3. **vector overlays** on the globe (a magenta route line + a blue airspace polygon) via the runtime
     style API — the hard open question for our overlays.
- `ATCTranscribeApp.swift`: shows the prototype **only** behind a flag, so normal app use is untouched.

## How to run it

Nothing changes unless you opt in:

- **Simulator / Xcode:** add the `--maplibre` launch argument to the run scheme, OR
- set the `atc.experimentalMapLibreGlobe` UserDefault to `true`.

The prototype takes over the whole screen with an "EXPERIMENTAL" banner + an ✕ to exit (which clears the flag).

## What this spike does NOT do yet (the real migration work, if we proceed)

1. **Serve our own MBTiles.** The FAA tiles here come from a third-party HTTP endpoint. Production would feed
   MapLibre our bundled/offline `.mbtiles` WebP packs through a local tile provider (an embedded tile server
   or a custom source), so it works offline in the cockpit.
2. **Port every overlay** currently drawn by MapKit renderers: airspace, airways, TFRs, the georeferenced
   plate overlay + corner chrome, nearby FAA-symbol markers, traffic, ownship — each becomes a MapLibre
   source + style layer, plus label/symbol collision.
3. **Re-wire tap-to-identify** (`rankProbe`) to MapLibre's feature-query / unproject API.
4. **Gestures + camera** parity (tilt/rotate on the globe, inertia, the plate-follow chrome).
5. **Measure battery/thermal** vs MKMapView on-device with the build-60 diagnostics — the whole point.

Everything under `Core/` and the data layers (`NavDatabase`, `CIFP`, `Airways`, TFR/METAR/TAF, route
resolution, transcription) is **engine-agnostic and would be reused unchanged**; only the map presentation
shell is affected.

## Verdict gate

Before proposing a migration: confirm on-device that (a) the sectionals look correct on the sphere, (b)
overlays render acceptably, and (c) it's meaningfully lighter on battery/thermal than the MKMapView map.
