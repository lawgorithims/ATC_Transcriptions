# Renderer source backup

`ios/Vendor/MapLibre.xcframework` is a locally-built fork of MapLibre Native, and
`useMapLibreMap` defaults **true** — so that binary is the shipping map engine. The fork
lives in a working copy at `~/CommSight/maplibre-native` (branch `globe/main`) that is
**not pushed anywhere**, and `Vendor/*` is gitignored, so nothing else in this repo records
the renderer's source.

`globe-fork-delta.bundle` closes that gap. It is a git bundle of every fork commit on top
of public upstream, so the renderer can be fully reconstructed from this repo plus GitHub.

| | |
|---|---|
| Upstream base | `4ec05558c849954b551c55300b31a48616d4da35` (maplibre/maplibre-native) |
| Fork tip | `46e455b29bf6d7596ba3f69385beb12476563369` (`globe/main`) |
| Contents | 42 commits, 89 files |

## Restore

```bash
git clone https://github.com/maplibre/maplibre-native.git
cd maplibre-native
git fetch ../path/to/globe-fork-delta.bundle 'refs/heads/*:refs/heads/*'
git checkout globe/main            # verify: git rev-parse HEAD == the fork tip above
```

Then rebuild the xcframework per `ios/docs/FORK.md`.

## Keep it current

Regenerate on every renderer rebuild, and update the tip SHA here and in `FORK.md`:

```bash
cd ~/CommSight/maplibre-native
git bundle create <repo>/ios/Vendor-src/globe-fork-delta.bundle \
  4ec05558c849954b551c55300b31a48616d4da35..globe/main
```

**This is a stopgap, not a substitute for a real remote.** Create
`lawgorithims/maplibre-native` on GitHub and push `globe/main` — a bundle is not a
mirror: it has no CI, no PRs, no history browsing, and it silently goes stale.
