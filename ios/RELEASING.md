# Pre-submission checklist

What has to be true before a build goes to TestFlight or the App Store. `RECOVERY.md` covers how to
ship from a bare machine; this covers what to ship.

## 1. Refresh the bundled nav data — at SUBMISSION, not every cycle

**The rule: refresh the bundle when you submit a build, and at no other time.**

This used to be a 28-day chore, and it was skipped: on 2026-10-20 the bundled `cifp.sqlite` was cycle
2607 and `apt.sqlite` was 2026-07-09, both **76 days past expiry**, and a clean install opened on a
red "2 datasets have expired" banner. It is no longer a chore, because `NavDataLibrary` now updates
procedures, airports and the plate index over the air. The bundle is only the **floor** — what a
first launch with no signal has to work from — so it needs to be current when it ships and nothing
more.

Each refresh also costs ~30 MB of git history permanently. Doing it per cycle instead of per release
buys nothing a download does not already cover, and the repository pays for it forever.

```bash
# the cycle IN FORCE today, not the next one — see §2
python3 ios/Tools/build_cifp.py       --date <YYMMDD>     --out ios/ATCTranscribe/Resources/nav/cifp.sqlite
python3 ios/Tools/build_apt.py        --date <YYYY-MM-DD> --out ios/ATCTranscribe/Resources/nav/apt.sqlite
python3 ios/Tools/build_procedures.py                     --out ios/ATCTranscribe/Resources/nav/procedures.json
```

`plate_georef.json` rolls **with** `procedures.json`, never on its own. It stores a page→ground
transform per plate PDF, and the app fetches that PDF from the cycle `procedures.json` names — so if
the two disagree, the overlay gets a transform for geometry the pilot is not looking at. Measured on
the 2607→2610 roll: of 9,007 plates in both, 24 had a transform that moved — 22 by more than 500 m,
14 by more than 2 km, the worst (`00095VA.PDF`) by 17.6 km on a ~68 km-wide page. Every one of those
24 rows stays comfortably inside `isPlausible`, so nothing at runtime can catch it: a stale table
misplaces silently rather than gapping. Needs PyMuPDF + numpy (no system python here has `fitz` — there is a venv at
`~/CommSight/plate-georef-venv`), ~2.6 GB of plate PDFs and about 10 minutes at 16 workers:

The table has **two halves and they are built by two different tools**, in this order:

```bash
CACHE=<scratch>/plates_cache_<cycle>            # one dir PER CYCLE — contents differ, filenames don't
python3 ios/Tools/fetch_plates.py --cycle <cycle> --cache "$CACHE"   # re-run until it exits 0

# 1. approach charts — the FAA's own embedded transform
~/CommSight/plate-georef-venv/bin/python3 ios/Tools/build_plate_georef_embedded.py \
        --cache "$CACHE" --iap-only --out <scratch>/iap_georef.json

# 2. airport diagrams — fitted, then MERGED into the same file
~/CommSight/plate-georef-venv/bin/python3 ios/Tools/build_apd_georef.py \
        --cache "$CACHE" --merge-into <scratch>/iap_georef.json \
        --out ios/ATCTranscribe/Resources/nav/plate_georef.json
```

Each builder counts an uncached plate as a silent skip, so a half-finished download yields a valid,
correctly-shaped, half-empty table. `PlateGeorefTests` holds the floors (>85% of each index, cycles
equal, no orphan rows).

**The approach half** is the FAA's own page→ground transform, read out of the geospatial PDF — exact,
nothing inferred. Cycle 2611 covers 9,898 of 11,162 IAPs (88.7%). The missing ~11% carry no `/VP`
viewport at all (the FAA does not publish them as geospatial PDFs — mostly military and high-altitude
charts) and correctly fall back to hand-align.

**The airport-diagram half is FITTED**, because the FAA publishes no embedded transform for airport
diagrams whatsoever — probed across 2611, an APD has no `/VP`, `/Measure`, `/GPTS`, `/LPTS` or `/GCS`.
So every diagram used to be a georeference miss, which is what hid the ownship dot, the ADS-B traffic
and "Overlay on map" on the one chart a pilot reads while the aircraft is moving on the ground.
`build_apd_georef.py` instead matches the runway strips the chart DRAWS to the surveyed runway ends in
`apt.sqlite`: two matched endpoints fix a similarity exactly, and every other runway on the field then
scores it without having contributed to it. Cycle 2611: **890 of 925 diagrams (96.2%)**, out-of-sample
residual median 2.9 m / p90 6.7 m / max 17.5 m, and 881 of 891 rotations landing within 1° of a right
angle — which is what a cartographic product does and a lucky fit does not. A single-runway diagram
consumes both control points in the fit, so its residual is 0.0 by construction and proves nothing;
those are gated instead on the drawn runway WIDTH, which the fit never looks at. 227 of the published
rows rest on that check alone.

⚠️ **`rotationDeg` is CLOCKWISE-from-north** (`PlateSimilarity.Placement`'s convention), so both
builders negate the counter-clockwise angle they fit. `build_plate_georef_embedded.py` did NOT, from
its first commit, and nothing noticed for cycles: approach plan views are north-up and the largest
rotation in the whole table is 1.41°, so the error was twice a number that is nearly zero. Checked
against the FAA's own embedded control points on `05932IL31.PDF` (KFFC, rotation 1.33°), the old
entry misplaced them by 14.09 page points and the corrected one by 1.35. It had to be found before
diagrams could ship at all: a diagram is routinely turned a quarter turn to fit a long runway onto a
portrait page, and a ±90° page read as ∓90° misplaces ownship by kilometres.

Then confirm the counts did not collapse. A builder that fetches a bad source and writes a valid,
nearly-empty database is the failure mode that has actually happened here (`build_sua.py`, 2026-10-19,
2,829 → 1,286 features), so compare against the outgoing file before you commit:

```bash
sqlite3 <new>.sqlite "select count(*) from airport;"   # vs the same query on the old one
```

`BundledNavDataTests` enforces the rest — dateable provenance, nothing effective in the future,
nothing more than one extra cycle stale, and the same corpus checks a download must pass.

## 2. Bundle the cycle IN FORCE, never the next one

The FAA posts each cycle weeks early, so "grab the newest file on the server" is the natural mistake
and it is the dangerous one.

`NavDataUpdate.activeURL` re-checks `isNotYetEffective` on an **installed** (downloaded) database, so
a download cannot go live early. It then falls through to the bundle **unconditionally** — the bundle
is never date-checked, because it was never supposed to be ahead of anything. A bundled future cycle
is therefore served as current: no banner, no refusal, nothing on screen to notice. That is worse
than shipping stale data, which at least announces itself.

Next cycle belongs in the staging pipeline instead (§5), where devices pre-download it and it
activates by itself at 0901Z on its effective date.

## 3. Checks that must pass

```bash
cd ios
~/.xcodegen/xcodegen/bin/xcodegen generate
xcodebuild -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -configuration Debug build-for-testing
xcodebuild ... test-without-building -only-testing:ATCTranscribeTests     # unit
xcodebuild ... test-without-building -only-testing:ATCTranscribeUITests   # UI
# and a RELEASE build, which the simulator loop never exercises:
xcodebuild -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

UI-suite skips are expected and should be *read*, not counted: transcription tests skip in an
EFB-only build (correct), landability tests skip without an `.lzpack` in the simulator, and the
screenshot job is opt-in. A skip proves nothing — if a skip count changes, find out why.

Build the simulator gate **signed**, as above, with no `CODE_SIGNING_ALLOWED=NO`. An unsigned
simulator build has no keychain access group, so the install id cannot be stored: the two Keychain
tests in `InstallIdentityTests` skip, saying so, and the unit skip count goes up by two. Only the
Release build above is unsigned.

## 4. Build number

`BUILD_NUMBER` must be the next unused integer; App Store Connect rejects one it has seen before.
`MARKETING_VERSION` stays on the 1.0 train (see the note in `project.yml`), so build N ships as
1.0 (N).

## 5. Cycle rolls are NOT app releases

Charts and nav data roll on their own clocks and do not need a build. On or after the effective date:

```bash
CYCLE=<MM-DD-YYYY> OUT=<packs dir> python3 charts/publish_packs.py --promote        # no re-upload
python3 nav/publish_nav.py --publish --from-dir <next-cycle build dir>
```

Both publishers share one flag shape: the ACTION (`--publish` / `--stage-next`, plus `--promote` for
charts) is exclusive, and `--dry-run` modifies whichever you pick, so every mode can be rehearsed.

Staging ahead of the date is `--stage-next` on both, and it is what makes the roll invisible to
pilots who have the app open.

## 6. What only a release can deliver

Anything in the **app binary**: `NavDataLibrary` itself, the download policy, the pre-cache, the
Features gate. Devices on an older build get none of it no matter what is published, because the
code that reads the manifest is the thing being shipped.
