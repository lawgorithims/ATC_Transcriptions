# Obelisk — Handoff: release the smaller where-not-to-go map

> For the next session, on the Mac. Written 2026-11-07. Pairs with `ios/RELEASING.md` (the gate and the
> ship) and `lz/avoid/` (the pipeline that built the map).

---

## 0. The one thing to know

**The map is rebuilt, gated and hosted. The app change that reads it is written but UNCOMMITTED.**
Releasing it means: commit, merge `main`, gate, write the release note, ship. **No map rebuild.**

Every shipped build (111–115) keeps working throughout: each catalog schema has its own address, and
the old catalog stays published untouched.

---

## 1. Where everything is (checked 2026-11-07)

| What | Where | State |
|---|---|---|
| The change | worktree `~/CommSight/atc-avoid`, branch `avoid/v1` | At `c0cd94a` (= build 111), **35 commits behind `origin/main`** (`d073d37`). 11 files modified + `lz/avoid/build.sh` new, all uncommitted. |
| Old map (catalog 2) | HF dataset `SingularityUS/commsight-avoid`, `index.json` | Built 2026-10-30, 17 bands, 1.52 GB. Read by builds 111–115. **Keep.** |
| New map (catalog 3) | same dataset, `index-v3.json` | Built 2026-10-31, 11 bands, **1.02 GB (−33%)**. Read only by the uncommitted app code. |
| Band files | same dataset, `map/` | All 28 (17 + 11) answer an anonymous ranged GET as SQLite. |
| Shipped builds | App Store Connect | Latest is 115 (2026-11-04); **expect 116 next, but query ASC first**. |
| App Store | version 1.0 | `PREPARE_FOR_SUBMISSION`, **build 112 attached**. `main`'s notes name 114 as the one to submit. |

⚠️ **On 2026-11-07 the session that wrote this change was still running `AvoidDownloadUITests` in this
worktree.** Before committing anything, make sure no `xcodebuild` is running here:

```bash
for p in $(pgrep xcodebuild); do lsof -a -p $p -d cwd -Fn | sed -n 's/^n//p'; done
```

---

## 2. What the change does

**The map format.** Land cover (water 1, developed 2, trees 4) is stored only down to z11, about 60 m.
z12 tiles keep the hazards (orchard, solar, wires, obstacle) and steep ground at full ~30 m. Land cover
was 54% of z12's bytes and is drawn only when the pilot turns on "Also shade trees, water and built-up
areas", which is off by default.

**App: 4 files.**
- `Avoid/AvoidMap.swift`: `AvoidMap.schema` "1" → "2", plus `landCoverZoom = 11` and `landCover`.
  `AvoidMapStore.maskWithLandCover(z:x:y:)` composes a z12 tile from its own bits plus its z11 parent's
  quadrant (each parent pixel covers 2×2). `reasons(lon:lat:)` uses it. The renderer uses it only
  when cover is shown, so it skips the parent fetch otherwise.
- `Avoid/AvoidMapLibrary.swift`: `catalogSchema` 2 → 3, and `catalogPath = "index-v3.json"`.
- `UI/AppModel.swift`: a comment only.
- Tests: four new in `AvoidMapTests`:
  - `testAZ12TileTakesItsLandCoverFromItsZ11ParentsQuadrant`
  - `testAPointsReasonsTakeLandCoverFromZ11ButNotItsHazards`
  - `testTheRendererDrawsZ11LandCoverOnZ12OnlyWhenCoverIsShown`
  - `testAMapOfAnotherSchemaIsRefusedAndCleanedUp`

  `AvoidDownloadUITests` now waits up to an hour.

**Pipeline: `lz/avoid/`, already run and published.**
- `merge.py` builds z11 from the FULL z12, then `strip_land_cover`.
- `gate.py` reads z12 composed with its parent's land cover and adds a hard layout check.
- `publish.py` writes `index-v{SCHEMA}.json`, deletes a band only when NO catalog lists it, and
  `--verify` checks every catalog's bands.
- `build.sh` runs the whole chain unattended, and `prep.py --cells` regenerates the cell list.

⚠️ **The one thing testers will notice.** A build with this change refuses schema-1 maps and deletes them
at launch: `AvoidMapStore.open` checks `avoid_schema`, and `reload()` removes anything that fails to
open. Anyone who downloaded the 1.52 GB map gets "Not downloaded yet" and must download about 1 GB
again. The release note has to say so (step 7).

---

## 3. Release, step by step

1. **Make sure the worktree is idle.** See the check in §1.
2. **Commit the change on `avoid/v1`.** Include this file and `lz/avoid/build.sh`:
   ```bash
   cd ~/CommSight/atc-avoid
   git add lz/avoid ios/ATCTranscribe ios/ATCTranscribeTests ios/ATCTranscribeUITests ios/HANDOFF_AVOID_MAP_RELEASE.md
   git status --short
   ```
3. **Merge `main`.**
   ```bash
   git fetch origin && git merge origin/main
   ```
   - **Expected conflicts:** `lz/avoid/merge.py`, `prep.py` and `publish.py`. `main`'s only change there
     is the CommSight → Obelisk rename, already applied by hand on this branch, so keep this branch's
     side.
   - `UI/AppModel.swift` should merge cleanly, because `main` never touched that comment.
4. **Fix one stale claim.** `AvoidMapLibrary.catalogPath`'s comment and `publish.py`'s docstring say
   catalog 2 serves builds "up to 114". It is **every build before the one that carries this change**:
   115 reads it too, and so would any build shipped from `main` before this lands.
5. ~~**Gate it,** per `RELEASING.md` §3.~~ — **DONE 2026-11-08** on `0e6f18b` (this branch merged to
   `main`, plus the veto's disjointness guard). Signed Debug build ("Sign to Run Locally"), own
   simulators, both deleted afterwards. **Do not re-run it to see the same numbers; it is 45 minutes.**
   - **Unit:** 2,490 executed / **9** skipped / 0 failures.
     ⚠️ **SIGNED IS WHY IT IS 9.** The same suite on an unsigned build reports **11**: the two Keychain
     tests in `InstallIdentityTests` skip, exactly as `RELEASING.md` §3 warns. If you see 11, you built
     with `CODE_SIGNING_ALLOWED=NO` — it is not a regression. (That is how it was first misread here.)
   - **UI, iPad Pro 13-inch (M5):** 71 executed / 13 skipped / 0 failures, 42 min, zero runner restarts.
     The 13, read: 6 `ConsoleUITests` (EFB-only build, correct), 3 opt-in (both screenshot jobs and the
     ~1 GB download of step 6), 3 `PanelFitUITests` (see below), 1 `LZLayerUITests` tap that landed on
     nothing scored.
   - ⚠️ **AN iPAD RUN ALONE LEAVES THE PHONE UNMEASURED.** `PanelFitUITests` is `requireCompactWidth`
     and skips at 1032pt — and those three tests are the whole iPhone-fit guard (top bar, layers panel,
     data-activity panel). Run them separately: on an iPhone 17 Pro, 3 executed / 0 skipped / 0 failures.
     `Tools/uitests.sh` is iPad-only by design and will not tell you this.
   - **Seed a pack before the UI run.** A fresh simulator has none, so `LZLayerUITests`'s pack-dependent
     cases skip with "no .lzpack installed" — on an LZ release that is the half most worth measuring.
     Copy one into `<app data container>/Library/Application Support/lz/`; `n33w107.lzpack` is the Las
     Cruces cell those tests fly at (KLRU, 32.2894/-106.9219). The device must be **booted** for
     `simctl get_app_container`, and shut it down again so the UI run boots clean.
   - **Release build:** `** BUILD SUCCEEDED **`, 0 errors. 7 warning kinds, every one pre-existing and
     none in `Avoid/` or in any file this release changes (checked against the commits' own hunks).
   - ⚠️ **THE VETO ITSELF IS STILL UNEXERCISED BY ALL OF THIS.** Nothing in the suite installs the avoid
     map, so `LZTileCompositor.avoidMask` returns nil throughout and the veto is inert by design. A green
     gate says this release does not break anything; it does not say the veto works. Step 6 is the first
     thing that touches it, and the ground-truth eval is the only thing that measures it.
6. **Prove the app can use the hosted map.** This is opt-in and moves about 1 GB:
   ```bash
   TEST_RUNNER_AVOID_DOWNLOAD_E2E=1 xcodebuild test-without-building -project ATCTranscribe.xcodeproj -scheme ATCTranscribe -destination 'id=<sim udid>' -derivedDataPath <dd> -only-testing:ATCTranscribeUITests/AvoidDownloadUITests -parallel-testing-enabled YES -parallel-testing-worker-count 1
   ```
   - The parallel-testing clone survives other sessions' `simctl shutdown all`, which killed three runs.
   - The link measured 0.37 MB/s on 2026-11-07, so budget up to an hour.
   - Also walk the **upgrade path** once: build 115 with the old map installed, then this build.
     Expect the old bands deleted at launch, Downloads offering about 1 GB, and the legend saying
     "Not downloaded yet".
   - Then run `~/chartenv/bin/python -I lz/avoid/publish.py --verify`. Do not run `--publish`; the
     data is already up.
7. **Release note.** `main`'s newest note is build 111; builds 112–115 shipped without notes. Add the
   new build to `WhatsNew.releaseNotes`, then update the `WhatsNewTests` pins: the build list,
   `releaseNotes.first?.build`, and the visible list. Draft:
   > **A smaller where-not-to-go map.** It now downloads at about 1 GB instead of 1.5 GB. Trees, water
   > and built-up areas are stored at about 60 m instead of 30 m, which is where the saving comes from.
   > Power lines, obstacles, solar farms, orchards and steep ground keep their full detail. **If you
   > downloaded the map before, download it again** (Settings › Downloads › Where not to go): this
   > build cannot read the old one and removes it.
8. **Ship** with `Tools/ship_testflight.sh` from a clean tree. Credentials and the recipe are in
   `ios/RECOVERY.md` and `RELEASING.md` §4. Query App Store Connect for the next build number first.
   - **If this build is the App Store submission,** bundle the nav cycle in force (`RELEASING.md` §1–2).
     2611 is in force until 2026-11-26, and 2612 after that. Then attach this build to version 1.0,
     which currently has 112.
9. **Push to `main`.**

---

## 4. The old catalog: keep it, retire it later

`index.json` and its 17 bands stay hosted for as long as any build that reads catalog 2 is in use:
- TestFlight builds expire 90 days after upload, so build 115 lasts until early February 2027.
- If App Store 1.0 ships with a build at or below 115, they must stay for as long as that version is
  installed anywhere.

**To retire it,** delete `index.json` from the dataset. The next `publish.py` run then removes its 17
bands as stale, because no catalog lists them. Never delete bands by hand.

---

## 5. Decide before release

- **The downloader gives up on a 60-second stall.** `FileDownloader` uses `URLSession` `.default` with
  no retry. One stall over 60 s fails a band with "The download did not finish". Finished bands are
  kept, and the button then fetches only the rest. On about 1 GB over a weak link this *will* happen.
  A bounded retry per band in `AvoidMapLibrary.fetch`, using URLSession resume data, is a small change
  and worth making before an App Store release. *Recommended.*
- **Which build goes to the App Store.** Version 1.0 has 112 attached. It reads catalog 2, which is fine;
  it just lacks the smaller map and every fix since.
- **Pricing.** The avoid map is not in the entitlement table, so it is free in practice. The flight
  briefing shows the out-of-glide summary, and `routeGlideExposure` is Pro + Performance.

---

## 6. The numbers behind the catalog-3 build

These come from that build's gate report (2026-10-31); the work directory was deleted after publishing.
- **Size:** 1.517 → 1.017 GB (−32.9%), 17 → 11 bands (largest 111 MB), z12 937 → 461 MB.
- **Gate:** passed. Every hazard rate and every z10 rate is identical to the 2026-10-30 build.
- **z12 land-cover checks:** moved slightly (residential +2.7 points, forest +1.2).
- **Runways at FAA-listed fields:** 99.8 → 99.6% clear (bar 98%). The difference is z11 water spilling
  onto two estimated Florida strips (FD37, 4FL9), and it shows only with cover on.
- **Layout check:** z12 holds no land cover, and z11 has it on 91–96% of tiles (bar 50%).
- **Detail kept:** land cover at a point is kept 97% of the time.

---

## 7. Things that bit while building it

- **`grep` is ugrep here.** In this machine's interactive shell `grep` is a function wrapping ugrep, and
  `grep -qv` exits 0 on EMPTY input. Use awk for "a line matching X but not Y", as `build.sh` does.
- **`pgrep -f <script>` matches its own wait loop.** In a wait loop it finds the waiting shell's own
  command line, so the loop never ends. Wait on a PID.
- **Other sessions' `simctl shutdown all` kills your runs.** Use the parallel-testing clone (step 6).
- **Uploads ran at about 1 MB/s.** The 11 bands took 18 minutes.
- **xcodebuild's success line is not `** BUILD SUCCEEDED **` for test actions.** `build-for-testing`
  prints `** TEST BUILD SUCCEEDED **` and `test-without-building` prints `** TEST EXECUTE SUCCEEDED **`.
  A gate script grepping for the plain one reports a passing build as a silent failure.
- **`simctl get_app_container` needs a BOOTED device.** On a shut-down one it exits 149 with
  "Unable to lookup in current state: Shutdown", which looks like a sandbox denial and is not one.
