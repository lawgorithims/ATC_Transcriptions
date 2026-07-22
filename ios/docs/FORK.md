# MapLibre Native fork — provenance

`ios/Vendor/MapLibre.xcframework` is **not** the upstream SPM package. `project.yml` comments out
`maplibre-gl-native-distribution` and links a locally-built xcframework instead, and `ios/.gitignore` ignores
`Vendor/*` — so the repo otherwise records **no version of its own map renderer**. `useMapLibreMap` defaults
**true**, so this binary is the shipping map engine, not a dev-only artifact. This file is that missing record.

## Pinned state (update on every renderer rebuild)

| | |
|---|---|
| Fork repo (local only) | `~/CommSight/maplibre-native` |
| Fork branch | `globe/main` |
| Fork commit | `fd9f5d93783d5527b0c582b539930ba30b145a20` |
| Upstream base | `4ec05558c849954b551c55300b31a48616d4da35` (maplibre/maplibre-native) |
| Delta vs upstream | 40 commits, 89 files |
| xcframework binary sha256 | `9453aa297168548e11d2237df2ef340caccf472eed491b8830e045ee6b956c2a` |
| Recorded | 2026-07-22T19:41:14Z |

## ⚠️ Release-integrity risks (open)

1. **The fork is not pushed anywhere.** `lawgorithims/maplibre-native` does not exist on GitHub, so the
   renderer source for the shipping binary exists on exactly one machine. Create the fork and push `globe/main`.
2. **The xcframework is untracked** (~48 MB, `Vendor/*` gitignored). A clean clone cannot build, and there is
   no App-Store-build-number → fork-commit mapping. Record the fork commit in the release notes for each build.
3. **Most of the fork delta is unreviewed.** 89 files differ from upstream — including `subdivision.cpp`,
   `collision_index.cpp`, `placement.cpp`, `render_orchestrator.cpp` and the Metal shaders — all of which are
   in the binary every pilot runs. Only the tile-cover / transform-state slice has been audited.

## Rebuild

```
cd ~/CommSight/maplibre-native
bazelisk build //platform/ios:MapLibre.dynamic --//:renderer=metal --compilation_mode=opt \
  --copt=-g --copt=-Oz --strip=never --output_groups=+dsyms --apple_generate_dsym
unzip bazel-bin/platform/ios/MapLibre.dynamic.xcframework.zip -d <app>/ios/Vendor/
```
