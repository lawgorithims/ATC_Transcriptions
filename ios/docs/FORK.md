# MapLibre Native fork — provenance

`ios/Vendor/MapLibre.xcframework` is **not** the upstream SPM package. `project.yml` comments out
`maplibre-gl-native-distribution` and links a locally-built xcframework instead, and `ios/.gitignore` ignores
`Vendor/*` — so the repo otherwise records **no version of its own map renderer**. `useMapLibreMap` defaults
**true**, so this binary is the shipping map engine, not a dev-only artifact. This file is that missing record.

## Backed up at

**Private GitHub repo `git@github.com:lawgorithims/maplibre-native.git`, branch `globe/main`** — the full fork
history (302 MB packed). This is the authoritative backup of the shipping renderer's source. Clone it and
rebuild per below. The 367 KB `ios/Vendor-src/globe-fork-delta.bundle` in this repo is a redundant offline copy.

Keep it current with `ios/Tools/sync_fork.sh` after every renderer rebuild (pushes `globe/main` + refreshes the
bundle + updates this file).

## Pinned state (update on every renderer rebuild — sync_fork.sh does this)

| | |
|---|---|
| Fork repo (local) | `~/CommSight/maplibre-native` |
| Fork remote (backup) | `git@github.com:lawgorithims/maplibre-native.git` (private) |
| Fork branch | `globe/main` |
| Fork commit | `e7843bbec2e5` |
| Upstream base | `4ec05558c849954b551c55300b31a48616d4da35` (maplibre/maplibre-native) |
| Delta vs upstream | 44 commits, 93 files |
| Recorded | 2026-07-22 |

## ⚠️ Release-integrity risks (open)

1. **The xcframework is untracked** (~48 MB, `Vendor/*` gitignored). A clean clone must rebuild the renderer
   from the backup repo (above); there is no App-Store-build-number → fork-commit mapping yet — record the fork
   commit in the release notes / What-to-Test for each build.
2. **Most of the fork delta is unreviewed.** 90+ files differ from upstream — including `subdivision.cpp`,
   `collision_index.cpp`, `placement.cpp`, `render_orchestrator.cpp` and the Metal shaders — all in the binary
   every pilot runs. Only the tile-cover / transform-state / raster-layer slice has been audited.
3. **dSYM**: the archive did not include the MapLibre.framework dSYM, so ASC can't symbolicate renderer crashes.
   The fork IS built with dSYMs (`--apple_generate_dsym`) — fold them into the archive's dSYM folder next build.

## Rebuild

```
cd ~/CommSight/maplibre-native
bazelisk build //platform/ios:MapLibre.dynamic --//:renderer=metal --compilation_mode=opt \
  --copt=-g --copt=-Oz --strip=never --output_groups=+dsyms --apple_generate_dsym
unzip bazel-bin/platform/ios/MapLibre.dynamic.xcframework.zip -d <app>/ios/Vendor/
```
