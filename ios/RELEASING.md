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
