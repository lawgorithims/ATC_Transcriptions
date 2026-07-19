# MapLibre Native Globe for iOS — Fork Implementation Plan

## Context

CommSight's Map tab runs on MapLibre Native iOS 6.27.0 (Metal), fully offline (loopback MBTiles tiles + bundled glyphs + Natural Earth land base). The pilot wants a **ForeFlight-grade seamless globe**: slowly zooming out curves the chart into a sphere with no mode switch. Verified at source level: **MapLibre Native has zero globe code** — Web-Mercator is baked into the transform + every layer shader; the style `projection` key is silently ignored (globe exists only in MapLibre GL **JS**, shipped v5.0.0). Upstream's roadmap calls for an unbuilt "Projector" abstraction; issue #3161 tracks globe with no code, "Partially Funded." Decision: **build it ourselves as a fork.**

**Two settled parameters (user):**
- **Posture — HYBRID:** the projection core is clean, upstream-shaped, backend-agnostic C++ (PR-able / handoff-able to MapLibre's funded effort); shaders are authored **Metal-only** (iOS ships Metal ⇒ shader work 1× not 3–4×).
- **First shippable milestone — SEAMLESS RASTER GLOBE:** raster chart tiles + land/fill/line curve on the sphere at low zoom, smoothly becoming today's flat chart at chart zooms. Symbols/labels on the sphere are a later phase.

**Two findings that materially de-risk the effort (verified this pass):**
1. **The biggest unknown is largely solved.** Native's Metal shaders are compiled by **runtime source concatenation** (`shaders::prelude + perShaderPrelude + source` in `shader_group.hpp::getOrCreateShader`) with a **`#define` permutation + registry-cache mechanism already in place** (the `HAS_UNIFORM_*` system). We do **not** need to invent shader injection — just add a projection prelude segment, an `MLN_PROJECTION_GLOBE` define, and a cache-key bit. GL-JS-style per-projection `projectTile` becomes an idiomatic compiled variant.
2. **The core is further along than the docs suggest.** Native's tile-cover is **already frustum + bounding-volume** based (not a flat scan) — sphere covering-tiles becomes *inserting a details-provider seam*, not a port. Native already parses `roll`/`centerAltitude` (the GL-JS 3D-camera modernization is in), and its style parser silently ignores an unknown `projection` key (adding it is additive). **Dev box is macOS 26.5.2 / Xcode 26.6 — matches the `macos-26` CI runners, so toolchain risk is low.**

**Effort (research-validated, cross-checked vs maintainers' own "6-figure / multi-person" sizing):** core C++ S0–S12 ≈ **16–22 engineer-weeks**; Metal/build/app track overlaps it. One strong graphics engineer ≈ **7–11 months to the seamless-raster milestone**; a core+Metal two-person split ≈ **4–5 months**. Symbols/labels on the sphere add ~1–2 months beyond the milestone. The plan is **seam-first**: the flat map stays byte-identical to upstream at every step until the globe is explicitly switched on behind a flag.

## Development model: build-alongside CommSight + in-app Globe Dev Harness

This is developed **in lockstep with the CommSight app** across many iOS builds — each phase links the latest fork `MapLibre.xcframework` into a fresh internal TestFlight build and is exercised on real hardware, never a big-bang integration at the end. Because the shipped app must stay safe (the flat chart is the default for all normal use), globe testing lives behind a **secondary developer setting**, not the normal UI:

- **Globe Dev Harness** — a hidden **Developer** section in Settings, unlocked with the app's existing 7-tap-to-reveal gesture (the same pattern as the buried clearance test bench), so normal pilots never see it. Built in Phase 0, extended every phase.
- **Engine/projection toggle** — the load-bearing control: switch the Map tab's MapLibre render live between **Flat (Mercator, default)** and **Globe (experimental fork)**, so every build is A/B'd on-device against the flat chart. Default is always Flat; the toggle is per-device and does not alter normal-use behavior; it **no-ops gracefully** on any build whose linked xcframework lacks globe (all early builds), with the render-watchdog → classic-MKMapView fallback still underneath. New `AppModel.useGlobeProjection` (dev-only) is orthogonal to the existing `useMapLibreMap` (globe only applies when the MapLibre engine is active).
- **Test instrumentation** (grows as capability lands): force globeness (flat / globe / auto-by-zoom), a transition-zoom override, "show tile subdivision + debug tile borders" (wired to the Phase-3 debug layer), and a live `BatteryDiagnostics` readout (mapFPS / cpu% / thermal, per-engine) so the battery A/B is one screen. The Phase-6 productionization flag (`experimentalGlobe`) is simply this harness graduating from dev-only to a gated, default-off user setting.
- **Plan-in-repo:** this document is committed to the CommSight repo as `ios/docs/GLOBE_FORK_PLAN.md` and updated per phase, so the multi-build effort is tracked alongside the code (mirrors the existing `REMEDIATION.md` / `PIPELINES.md` convention).

## Ground truth: what exists vs. what we build

### MapLibre Native ALREADY HAS (we build on)
| Asset | Where | Why it matters |
|---|---|---|
| Metal shader **variant** mechanism (prelude concat + `#define` + registry cache) | `include/mbgl/shaders/mtl/{shader_group,common}.hpp`, `src/mbgl/mtl/context.cpp` | The globe shader path is an added compiled variant, not new infra |
| Consolidated per-drawable UBO plumbing (`MLN_UBO_CONSOLIDATION`) + 2 **reserved** drawable UBO slots | `include/mbgl/shaders/layer_ubo.hpp`, `renderer/layers/*_layer_tweaker.cpp`, `mtl/drawable.cpp` | Home for `ProjectionData` with no new binding machinery |
| Frustum + bounding-volume tile cover (LOD, pitch, wrap) | `util/tile_cover.cpp`, `util/bounding_volumes.*` | Sphere covering = insert a details-provider seam, not a rewrite |
| Real 3D perspective camera + depth pipeline; `roll`/`centerAltitude` already parsed | `map/transform_state.cpp` `getProjMatrix()`; fill-extrusion is true 3D | Globe = new vertex mapping + horizon logic on an existing 3D engine |
| Single tessellation choke points | `gfx/fill_generator.cpp`, `gfx/polyline_generator.cpp` (fill/line buckets) | Subdivision hooks are localized |
| Modular Drawable/Tweaker renderer; per-drawable stencil + depth state | `renderer/`, `gfx/`, `mtl/` | Two-pass stencil for seams fits the existing model |
| Render-test harness + manifests | `render-test/`, `metrics/ios-metal-render-test-runner-*.json` | Our regression gate for the Mercator refactor |
| Bazel iOS xcframework build (exact CI command known) | `platform/ios`, Bazel 8.6.0, `macos-26`/Xcode 26 | Fork build is solved; dev box matches CI |
| Style-spec `projection` property (already shipped) | maplibre-style-spec | Spec/API design is free |

### GL JS BLUEPRINT (what we port — shipped, tested, ~7,000 lines TS + ~500 GLSL; PR #3963)
`src/geo/projection/` (projection interface + ProjectionData + factory + camera helpers + covering tiles + vertical-perspective + globe adaptive + error measurement) · `src/render/subdivision.ts` (43 KB CPU tessellation) · `src/shaders/glsl/_projection_globe.vertex.glsl` (sphere math + pole sentinels + transition lerp) · **~140 KB of test suites** (`globe_transform.test`, `subdivision.test`, `mercator_transform.test`) = the C++ validation oracle.

### MISSING — the tech-tree nodes we must write
Projector seam (C++ interface + `ProjectionData`, Mercator refactored behind it) · `ProjectionData` UBO plumbing into Metal · Metal projection prelude + globe shader variants · vertical-perspective transform · sphere covering-tiles provider · subdivision module + bucket/mesh hooks · adaptive globe↔mercator transition · GPU atan-error correction (Metal readback) · sphere camera/gesture helpers · style `projection` → runtime plumbing · symbols/collision on sphere (later) · fork build/CI/app-wiring.

## Tech tree (dependency graph)

```
P0  Bootstrap + shader-variant SPIKE + render-test baseline ─────────┐
                                                                     ▼
P1  Projector SEAM: ProjectionData + Projection iface + Mercator-behind-it
    + Metal prelude/UBO plumbing + style `projection` parse   [Gate 1: mercator pixel-exact]
                     │
                     ├──► P2  Sphere math: globe_utils · vertical-perspective transform
                     │        · covering-tiles seam · SUBDIVISION module + bucket/mesh hooks   [CPU]
                     │                     │
                     └─────────────────────┼──► P3  Background + RASTER globe (subdivided mesh
                                           │        + two-pass stencil + poles)   [Gate 2: raster globe]
                                           │
                                           ├──► P4  Seamless transition + camera/gestures + atan-correct
                                           │
                                           └──► P5  FILL + LINE on sphere   [Gate 3: vector base]
                                                        │
P6  App wiring + on-demand/battery gate + CI + Settings flag + TestFlight  ◄── MILESTONE: seamless raster globe
                                                        │
P7  (later) circle/heatmap/hillshade · SYMBOLS + collision on sphere
```

Detailed file-level step breakdowns (core = S0–S12, Metal/build = P0–P13) are captured in the two design dossiers (`tasks/a5671b81…` core, `tasks/afb9ec29…` Metal); the phases below are the integrated, dependency-ordered execution plan.

---

## Phase 0 — Bootstrap, de-risk, baseline  *(additive; ~1.5–2.5 wks)*
**Goal:** prove fork → xcframework → app renders, and retire the shader-variant unknown, before writing globe code.
- **Fork + build:** fork `maplibre/maplibre-native` → `lawgorithims/maplibre-native`, branch `globe/main` off a pinned recent **`main`** SHA (record in `FORK.md`); `brew install bazelisk` (pins Bazel 8.6.0); `config.bzl` from `example_config.bzl`; run the verbatim CI build `bazel build //platform/ios:MapLibre.dynamic --//:renderer=metal --compilation_mode=opt …` → `MapLibre.dynamic.xcframework`. Record build time/disk (budget 30–60 min; box has 696 GB).
- **App smoke:** in `atc-maplibre/ios/project.yml` swap the SPM MapLibre (lines 39–41, 155–156) for the **`framework:` + `embed: true`** local-xcframework idiom already used for `Vendor/llama.xcframework` (lines 160–161). Build CommSight → charts render, watchdog silent, `BatteryDiagnostics` mapFPS ≈ 0 idle. Surfaces any 6.27.0→main API drift now.
- **Render-test baseline (device-farm-free):** run the `RenderTest` scheme on iOS Simulator against `metrics/ios-metal-render-test-runner-*.json`; check the passing set into the fork (`metrics/fork-baseline-ios-metal.txt`). This is the mercator regression gate for every later step.
- **Shader-variant spike (the ex-biggest unknown):** throwaway branch adds `#if MLN_PROJECTION_GLOBE` tint to `raster.hpp` + the define/cache-key to `shader_group.hpp`; confirm (a) both variants cache + pipeline-rebuild on shader swap, (b) variant compile cost is amortized, (c) the reserved drawable UBO slot is free on Metal (`grep idDrawableReservedVertexOnlyUBO`), (d) `[[clip_distance]]` compiles on the target iPad, (e) mercator baseline unchanged with the toggle off. Output: one-page decision memo (D1 confirmed or function-constant fallback).
- **Globe Dev Harness v0 (app-side):** add the hidden **Developer** Settings section (7-tap unlock, reuse the clearance-test-bench reveal pattern) containing the **Flat ⇄ Globe engine toggle** (`AppModel.useGlobeProjection`, dev-only, default Flat) + the live `BatteryDiagnostics` readout (mapFPS/cpu%/thermal per engine). On this stock-fork build, the Globe position just forces the (currently-inert) `projection:globe` style key + logs — proving the toggle plumbing end-to-end before any globe pixels exist, and confirming the graceful no-op + watchdog fallback. Commit `ios/docs/GLOBE_FORK_PLAN.md` (this plan) into the CommSight repo.
**Exit:** stock fork runs inside CommSight on device; dev harness toggles engine with no crash/regression (globe position == flat until globe lands); baseline recorded; spike memo. **Depends:** none.

## Phase 1 — The Projector seam  *(Gate 1; ~3–4 wks)*
**Goal:** `ProjectionData` flows to shaders with **mercator values bit-identical to today**; nothing can turn globe on yet.
- **Core (S1/S2/S5):** new `src/mbgl/projection/`: `projection_data.hpp` (POD: `mainMatrix`, `tileMercatorCoords`, `clippingPlane`, `projectionTransition`, `fallbackMatrix`), `projection.{hpp,cpp}` + `mercator_projection.*` (renderer-facing interface + factory), `projection_types.hpp`. Modify `transform_state.{hpp,cpp}`: add `projection`/`globeness`/`errorCorrection` fields (default mercator/0/0) + `getProjectionData(tileID)` (mercator: `mainMatrix = fallbackMatrix = projMatrix × matrixFor(tile)`, transition 0); carve `getProjMatrix`/`screen↔LatLng` interiors into per-projection branches. **Do NOT make `TransformState` polymorphic** (it's a value type copied across the per-frame cross-thread handoff) — globe math is stateless free functions; polymorphism lives only in the renderer-side `Projection` + map-thread `CameraHelper` interfaces. Add style `projection` parse (`style/parser.cpp` root member → `style::Projection` → `map_impl.cpp` evaluates at zoom → `Transform`).
- **Metal (P2):** new `include/mbgl/shaders/mtl/projection.hpp` (MSL `ProjectionData` structs + `projectTilePos()` in mercator/globe flavors under `#if MLN_PROJECTION_GLOBE`, `[[clip_distance]]` emit); `shaders/projection_ubo.hpp` (C++ mirror + `static_assert`); modify `shader_group.hpp` (concat + define + cache key), `common.hpp`/`layer_ubo.hpp` (insert `idGlobalProjectionParamsUBO`), the per-frame global-UBO fill site (found in P0 spike), `layer_tweaker.{hpp,cpp}` (build the consolidated `ProjectionTileUBO` vector). **UBO split (D2):** per-frame `GlobalProjectionParamsUBO {mat4 projection_matrix; float4 clipping_plane; float transition;}` (atan-correction pre-folded CPU-side) + per-drawable `ProjectionTileUBO {mat4 fallback_matrix; float4 tile_mercator_coords;}` in the reserved slot. **Horizon (D3):** MSL `[[clip_distance]]` (native uses depth for layer order, so don't hijack `gl_Position.z`).
**Exit — Gate 1:** flag off ⇒ **pixel-exact** mercator baseline (the concat recompiles every shader, so this gate is mandatory); Metal frame capture shows both UBOs bound with sane values under a forced-globe debug toggle. **Depends:** P0.

## Phase 2 — Sphere math + geometry  *(mostly additive; hot-path steps render-gated; ~6–8 wks)*
**Goal:** all sphere primitives + tessellation, validated against ported GL JS tests; mercator still identical.
- `projection/globe_utils.*` — inverse-mercator→sphere, unit-vector, radius/zoom compensation, pan-center, pole handling. *(port `globe_utils.ts`; test to 1e-9)* — **additive.**
- `projection/vertical_perspective.*` — globe matrices, ray–sphere unproject, clipping plane, per-tile globe `ProjectionData`. *(port `vertical_perspective_transform.ts`)* — additive (nothing sets globeness yet).
- `projection/globe_covering_tiles_details_provider.*` + parameterize `util/tile_cover.cpp` with a `CoveringTilesDetailsProvider` seam; the **mercator provider reproduces current behavior exactly**. — **hot path, highest-risk refactor; gate hard.**
- `util/subdivision.*` + `subdivision_granularity_settings.hpp` — CPU retessellation (fill 128/line 512/tile 128 granularity, pole sentinels ±32767, 16-bit index cap). *(port `subdivision.ts` — the single most valuable test port)* — **additive** (no call sites yet).
- Bucket/mesh integration: route `fill_bucket.cpp`/`line_bucket.cpp` through subdivision when granularity>0 (byte-identical when 0); `projection/tile_mesh.*` for raster/background globe meshes. — **hot path** (fill/line layout).
**Exit:** ported `globe_utils`/`vertical_perspective`/`subdivision`/`covering` C++ tests green; mercator baseline bit-identical with globe off. **Depends:** P1.

## Phase 3 — First curved pixels: background + raster globe  *(Gate 2; ~3–4 wks)*
**Goal:** the shippable seamless raster sphere.
- **Metal (P3/P4-bg):** `background.hpp`/`debug.hpp` vertex → `projectTilePos`; `render_background_layer.cpp` sources the subdivided tile mesh (native already tiles background — small change). Debug borders first (they make raster debuggable).
- **Raster (P4 + core S12):** `raster.hpp` vertex → `projectTilePos` (pole vertices carry explicit texcoords); `render_raster_layer.cpp` sources the per-tile subdivided mesh incl. pole fans, enables back-face culling in globe mode; **two-pass stencil** (borderless meshes write stencil ref; bordered pass draws only where unmarked) via a small additive per-drawable `StencilMode` API + the existing `nextStencilID` pool — kills tile-boundary/pole seams and double-blend.
**Harness:** this is the **first internal build where flipping the dev Globe toggle shows an actual curved sphere** — the user can watch raster-globe progress on-device from here on. Wire the "debug tile borders + subdivision" overlay (built in P3) into the harness.
**Exit — Gate 2:** aviation raster charts curve correctly at z<7; no seams at borders/poles/antimeridian at all pitches; new globe render tests under a fork manifest (`metrics/fork-globe-*.json`); mercator baseline green; frame capture shows expected vertex budget + no stray passes. **Depends:** P2.

## Phase 4 — Seamless transition + camera + precision  *(~3–4 wks)*
**Goal:** the ForeFlight z≈7→12 hand-off, correct gestures, stable alignment.
- **Transition (core S9 + Metal P5):** `projection/globe_projection.*` adaptive preset (globeness = pure function of camera+style, expands `"globe"`→`interpolate zoom 11→12`; **no self-scheduling timers** — protects on-demand rendering); shader-side `interpolateProjection` lerps against `fallback_matrix` by `projectionTransition` (shaders never swap during the transition; pole opacity fade). Exercises P1's prelude across background/raster/debug.
- **Camera/gestures (core S10):** `projection/{camera_helper,mercator_camera_helper,globe_camera_helper}.*`; `transform.cpp` delegates `moveBy`/`easeTo`/anchor handling to the projection's helper (pan keeps point under finger via `computeGlobePanCenter`, zoom-about-anchor, `getZoomAdjustment` by latitude). **No `platform/ios` changes** (verified: `MLNMapView.mm` only calls `Map::moveBy/jumpTo/easeTo`).
- **Precision (core S11 + Metal P7):** `projection_error_measurement.*` state machine (4-frame readback + 6-frame wait, 0.5 s smoothing) + Metal 1×1 offscreen R32Float readback via `addCompletedHandler` (never blocks); **fires only when globe active AND camera moved AND ≥1 s elapsed** — piggybacks existing frames, schedules none. Correction folds into the corrected matrix only.
**Exit:** scripted zoom z3→z12→z3 shows no popping/seam-flash; on-device gesture matrix (pan at pole, pinch at edge, fling across antimeridian, double-tap) correct; alignment stable 0–75° latitude. **Depends:** P2 (+ P3 for a visible globe).

## Phase 5 — Fills + lines on the sphere  *(Gate 3; ~2 wks, parallelizable with P3/P4 shader work)*
**Goal:** land/water fills + boundaries/airways/routes curve at low zoom.
- **Metal (P6):** `fill.hpp` (all 4 variants) + `line.hpp` (all variants) vertex → `projectTilePos` + clip-distance horizon culling + globe line-extrusion; `{fill,line}_layer_tweaker.cpp` fill `ProjectionTileUBO`. Geometry subdivision already lands at bucket build (Phase 2).
**Exit — Gate 3:** vector base map curves; long lines follow curvature without artifacts; mercator baseline green. **Depends:** P1 (shaders), P2 (bucket subdivision).

## Phase 6 — App integration, battery gate, ship  *(MILESTONE; ~2 wks spread)*
**Goal:** seamless raster+vector globe reaches TestFlight behind a flag, with battery parity proven.
- **On-demand audit (P8 — north star):** verify no new per-frame invalidation (transition pure-function, atan gated, atmosphere/sky **not ported**, UBOs under existing dirty checks). **Exit criterion: `BatteryDiagnostics` mapFPS ≈ 0 at idle** on globe at z3 and z10 over 10-min windows, matching mercator within noise, transcription OFF.
- **Fork CI (P9):** `.github/workflows/fork-ios.yml` on `macos-26` — build `//platform/ios:MapLibre.dynamic` (artifact + SHA), `bazel test //platform/ios/test`, RenderTest on simulator vs the P0 baseline + fork-globe manifest. Disable inherited upstream workflows (missing secrets). **Rebase policy:** pin `UPSTREAM_SHA`; rebase on each upstream iOS release tag (~monthly); commit stack partitioned [upstream-submittable core] → [Metal-only] → [fork-ops]; re-capture baseline after each rebase.
- **App wiring (P10):** `project.yml` → `Vendor/MapLibre.xcframework` (`framework:`+`embed:`, keep removed SPM lines commented for rollback); `Scripts/update-maplibre.sh` (build/unzip/rsync + stash dSYMs).
- **Flag + fallback + gates (P11):** **graduate the dev-harness Globe toggle into a gated user setting** — the same `useGlobeProjection` plumbing, now surfaced as `experimentalGlobe` in normal Settings (default OFF; off ⇒ byte-identical style to today; prefer a runtime `MLNMapView.projection` API if the core lands one). The hidden Developer harness stays for deeper test controls. Keep the watchdog→classic-MKMapView fallback; add an intermediate tier (on stall with globe on, reload once without the projection key before classic fallback; log which tier fired). **Ship gates:** TF1 fork-parity build (no globe exposed) → TF2 raster globe behind the flag, internal testers (after P3/P4/P8) → TF3 fill/line globe, wider ring (after P5/P7) → GA only with battery parity + zero tier-2/3 activations in telemetry + both render manifests green.
**Depends:** P3/P4 (TF2), P5 (TF3).

## Phase 7 — Later: remaining layers + symbols on the sphere  *(post-milestone)*
- **Circle/heatmap/hillshade/color-relief (P12, ~1–2 wks):** mechanical once P1 exists (heatmap only in the world-space accumulation pass). Custom layers documented mercator-only.
- **Symbols + collision (P13, XL ~1 mo):** `symbol.hpp` variants project anchors + billboarding + map-aligned tangent-plane text; CPU `collision_index.cpp`/`placement.cpp` project via the core Projector, AABBs from projected box corners+midpoints, horizon-prune before placement. Interface agreed with core early; battery re-check (placement runs on camera change only). **This is the hard deferred piece** — the labels-on-a-sphere problem GL JS spent the most effort on.

---

## Key technical decisions (settled)
- **D0 — Fork posture:** hybrid. Core commits upstream-shaped (PR-able / handoff-able to MapLibre's funded globe effort); Metal-only shaders; skip GL/Vulkan/WebGPU.
- **D1 — Shader variants:** compile-time `#define MLN_PROJECTION_GLOBE` through native's existing prelude-concat + registry-cache permutation (no new mechanism). Fallback: `MTLFunctionConstantValues` specialization.
- **D2 — ProjectionData:** per-frame `GlobalProjectionParamsUBO` + per-drawable `ProjectionTileUBO` in a reserved drawable slot; mercator binds neither (hot path untouched).
- **D3 — Horizon culling:** MSL `[[clip_distance]]`, not `gl_Position.z` (native uses depth for layer ordering). Fallback: z-encode remapped to Metal clip volume with a per-layer depth audit.
- **D4 — Transform:** `TransformState` stays one concrete value type; globe math = stateless free functions; the "Projector" polymorphism lives only in renderer-side `Projection` + map-thread `CameraHelper`. CPU uses the vertical-perspective path whenever globeness>0; only the *shader* blends.

## Logistics (settled)
- **Fork:** `lawgorithims/maplibre-native`, `globe/main` off pinned `main`; partitioned commit stack; rebase on iOS release tags.
- **Build:** Bazel 8.6.0 via bazelisk → `MapLibre.dynamic.xcframework`; dev box Xcode 26.6 = CI parity. Not swift-buildable from source (always xcframework → binary consumption).
- **App consumption:** `framework:` + `embed: true` local-xcframework idiom (proven for `Vendor/llama.xcframework`) over an SPM local binary package (avoids SPM binary-cache friction).
- **Safety:** render watchdog + classic-MKMapView fallback retained; globe ships behind a default-off Settings flag until the battery gate passes.

## Verification & ship gates
- **Mercator regression:** every hot-path step re-runs the Phase-0 render-test baseline; **bit-identical required** (Gate 1 pixel-exact after the shader concat; Gates 2/3 after raster and fill/line).
- **Globe correctness:** ported GL JS unit suites (globe_transform / subdivision / mercator_transform) as C++ tests; new fork globe render manifests (`metrics/fork-globe-*.json`); Metal frame captures.
- **Battery (north star):** `BatteryDiagnostics` v2 A/B — {globe on/off} × {idle@z3, idle@z10, scripted pan/zoom} × 30 min, transcription OFF; **mapFPS ≈ 0 at idle on globe** is a hard gate.
- **On-device (the primary test vehicle):** every phase ships an internal TestFlight build; the user validates globe progress by flipping the hidden **Globe Dev Harness** toggle (Flat ⇄ Globe) and comparing against the flat chart on the same device — seamless zoom (no pop/seam-flash), gesture matrix, curvature at low zoom, no pole/antimeridian artifacts, live mapFPS/battery readout, watchdog fallback exercised. Normal users only ever see the flat map until GA.
- **Ship:** TF1 (fork parity) → TF2 (raster globe, flagged, internal) → TF3 (fill/line, wider) → GA on battery parity + zero fallback-tier activations + green manifests.

## Effort roll-up
Core C++ (S0–S12) ≈ 16–22 eng-weeks; Metal/build/app overlaps. **One strong graphics engineer ≈ 7–11 months to the seamless-raster milestone (Phases 0–6); ~4–5 months with a core+Metal two-person split.** Symbols/labels (Phase 7) add ~1–2 months. This sits within the maintainers' independent "6-figure / multi-person" sizing — the plan buys control of the timeline and the exact ForeFlight seamless experience, at the cost of carrying a large fork (rebase policy above) against a low-zoom-only feature. The seam-first ordering means the fork is safely shippable (flat map identical) at every step, and the whole effort can be paused after any phase without regressing today's app.
