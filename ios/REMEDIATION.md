# CommSight iOS — Remediation Specification

**Scope:** the 23 verified findings from the 2026-07 whole-app audit (3 high / 7 medium / 13 low).
**Audience:** the developer executing a fix. Each entry states the symptom, the root cause, the
REQUIRED change (exact code where practical), what must NOT break (named tests/invariants), the
new tests required, and QA notes. Statuses are updated as fixes land.

**House rules for every fix (non-negotiable):**
- NASA/JPL Power-of-10 as practiced in this repo: statically bounded loops (with a loop-bound
  assert), guard-and-recover parameter validation, no recursion, no function pointers stored as
  data, zero app-source warnings.
- Copy the repo's established idioms — do not invent new ones:
  - *Epoch-guard off-main:* `AppModel.syncGrounding` / `ChartMapView.Coordinator.refreshContext`.
  - *Error surfacing:* injected `onFailure`/`onTrouble: @Sendable (String) -> Void` closure →
    `Task { @MainActor in … }` (see `micFailure` in `AppModel.beginCapture`).
  - *Bounded reconnect:* `StratuxAudioSource.connectAttempts` + one-shot `troubleSurfaced`.
  - *Stored cancellable:* `efbCancellable`.
  - *Currency re-check after an async prompt:* the calibration flow (`recordCalibrationAmbient`).
  - *Timeout race:* `CascadeCorrector.withTimeout` (but see L6 — it must NOT be copied there).
- **Parity locks:** `SlotSnap.apply` and `CallsignSnap.snapTranscript` are byte-parity-locked to
  the Python reference via `SnapParityTests` + `snap_fixtures.json`. The only safe way to change
  their behavior is a defaulted parameter/condition that is FALSE for every fixture (precedent:
  the Swift-only nav-band branch in `snapFrequency`). After touching them, run `SnapParityTests`
  AND `python3 ios/Tools/parity_check.py`.
- Full unit suite green after every group; per-group commit; check `git status` for
  parallel-session work in `AppModel.swift` before committing.

---

## HIGH

### H1 — Mic/USB capture dies silently after an audio interruption
**Severity:** HIGH · **Files:** `Audio/AudioSource.swift` (DeviceAudioSource),
`Audio/AudioSessionManager.swift`, `UI/AppModel.swift` (~1437-1458)
**Status:** FIXED in f8af58e

**Symptom.** Siri, an alarm, an incoming-call banner, or a Bluetooth/USB route change stops the
`AVAudioEngine`; nothing restarts it. The UI keeps showing the last transcript as if live — the
worst failure mode for a glance instrument.

**Root cause.** The app registers **zero** `AVAudioSession` observers (verified by grep:
no `interruptionNotification`, `routeChangeNotification`, or `mediaServicesWereResetNotification`
anywhere). The only liveness check is a one-shot 3.5 s startup watchdog that never re-arms.

**Required change.**
1. **Pure classifier** (new, in `AudioSessionManager.swift`) so the decision logic is unit-testable:

```swift
enum AudioSessionEvent: Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case inputRouteLost           // routeChange .oldDeviceUnavailable
    case mediaServicesReset
    case irrelevant

    static func classify(name: Notification.Name, userInfo: [AnyHashable: Any]?) -> AudioSessionEvent {
        if name == AVAudioSession.mediaServicesWereResetNotification { return .mediaServicesReset }
        if name == AVAudioSession.interruptionNotification {
            guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return .irrelevant }
            switch type {
            case .began: return .interruptionBegan
            case .ended:
                let opts = AVAudioSession.InterruptionOptions(
                    rawValue: (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
                return .interruptionEnded(shouldResume: opts.contains(.shouldResume))
            @unknown default: return .irrelevant
            }
        }
        if name == AVAudioSession.routeChangeNotification {
            guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return .irrelevant }
            return reason == .oldDeviceUnavailable ? .inputRouteLost : .irrelevant
        }
        return .irrelevant
    }
}
```

2. **Observers live inside `DeviceAudioSource`** (it owns the engine, the `NSLock`, the
   continuation, and the failure closure; `AudioSessionManager` is a stateless enum and cannot own
   observers). Register in `makeStream()`, remove in `stop()`. This ordering is what makes the fix
   safe against `handleScenePhase`: backgrounding calls `stop()` *before* `deactivate()`, so the
   observers are gone before deactivation can emit stray notifications, and any already-queued
   handler no-ops on the `continuation == nil` guard.
3. **Two channels:** keep `onFailure` (terminal: AppModel flips `.error` + deactivates); add
   `onNotice: (@Sendable (String) -> Void)? = nil` (transient: AppModel sets `detail` only; the
   session stays `.live`). AppModel adds `micNotice` beside `micFailure`; both
   `DeviceAudioSource(...)` constructions gain `onNotice: micNotice`.
4. **Event handling:**
   - `.interruptionBegan` → under the lock, take + tear down the engine, set `interrupted = true`;
     notice *"Audio paused by another app — resuming when it finishes."*
   - `.interruptionEnded` → attempt restart **regardless of `shouldResume`** (the app's entire
     purpose is capture the user explicitly started); re-activate the session first
     (`AudioSessionManager.activate(recording: true, preferUSB:)`) then rebuild the engine —
     preserving the load-bearing "engine built only after the session is active" invariant.
   - `.inputRouteLost` → notice + restart on the new route. The rebuilt engine must re-query
     `inputFormat` fresh (a route change means a new format/converter — never reuse).
   - `.mediaServicesReset` → `onFailure` (*"The system audio service was reset. Press Start to
     resume."*) + full `stop()` — every handle we hold is invalid.
5. **Refactor** the engine build (old lines ~89-128) into `startEngine() -> Bool` that atomically
   tears down any prior engine under the lock first, then builds/installs/starts.
6. **Bounded single-flight restart:** `recovery: Task<Void, Never>?` guarded nil-check (one
   recovery at a time; a route-change + interruption double-fire coalesces);
   `maxAttemptsPerEvent = 3` at 0.5 s spacing (loop-bound assert);
   `maxRestartsPerSession = 10` → exhausted = `onFailure("Audio keeps dropping — press Start to
   retry.")` + stop.
7. **Repeating liveness watchdog** replaces the one-shot (keep the 3.5 s startup grace and
   message byte-identical): the tap increments `buffersSeen` (an `OSAllocatedUnfairLock<Int>`);
   a bounded loop (5 s period, `maxLivenessChecks = 17_280` ≈ 24 h) compares the counter; if
   unchanged and not interrupted/recovering → `scheduleRestart`. Safe: the input tap fires
   ~12×/s with near-zero-RMS buffers even in a silent room — a stall means a dead route, never a
   quiet user.

**Must NOT break.** `handleScenePhase` background teardown/resume; the mic-permission "engine
after session activation" fix; `micFailure`'s deactivate-on-error semantics; the startup watchdog
message/timing. No unit tests exist for DeviceAudioSource (device-only) — the classifier is the
testable seam.

**New tests.** `AudioSessionEventTests.swift`: classifier matrix — began; ended+option 1 →
shouldResume true; ended bare → false; malformed/missing keys → irrelevant; routeChange
`.oldDeviceUnavailable` → inputRouteLost; `.categoryChange` → irrelevant; media-reset name.

**Manual QA (device).** Siri over a live mic session; a timer alarm; an incoming-call banner
(`.inactive` — deliberately not torn down); USB unplug mid-session; background → foreground.
Each: capture resumes (or the UI honestly shows error/paused), never a silent frozen "live" view.

---

### H2 — Rapid model switching can hold 2-3 Whisper compiles in memory → OOM kill
**Severity:** HIGH · **Files:** `UI/AppModel.swift` (switchModel ~1775-1845, beginModelLoad,
cancelModelLoad ~1763-1769, setupLive ~664-682), `Transcription/ATCTranscriber.swift` (:76-90),
`UI/SettingsSheet.swift` (:211-236)
**Status:** FIXED in 877a43a

**Symptom.** Tapping between model options while one is compiling starts a second (third…)
multi-GB CoreML compile concurrently; jetsam kills the app.

**Root cause.** `loadTask?.cancel()` is cooperative and `WhisperKit(config)` never checks it;
the `modelSwapGeneration` guard fires only *after* the compile returns. The picker deliberately
disables only the currently-loading button.

**Required change (three layers).**
1. **Picker lock** — `SettingsSheet.swift:234`:
   `.disabled(!available || model.loadingModel != nil)` + rewrite the stale keep-tappable comment.
   Verified this cannot wedge: `loadingModel` is cleared by the 30 s swap watchdog, the 60 s
   initial-load watchdog, both load-task completions, and `cancelModelLoad`.
2. **Task chaining** (NOT a yield-spin loop — main-actor CPU burn/priority inversion; NOT a
   hand-rolled semaphore — cancel-while-waiting subtleties). In `switchModel` and
   `beginModelLoad`, before reassigning `loadTask`:

```swift
let predecessor = loadTask   // chain anchor: the (possibly still-compiling) superseded load
loadTask = Task {
    // Serialize CoreML compiles: cancellation cannot interrupt an in-flight WhisperKit(config),
    // so wait for the superseded load to actually RETURN before starting ours. Linear chain
    // (each task awaits only its immediate predecessor): no cycle, no deadlock.
    if let predecessor { await predecessor.value }
    guard modelSwapGeneration == gen else { return }   // superseded while we queued
    let ok = await setupLive(...)                       // existing body unchanged
    ...
}
```

   **Companion (load-bearing):** `cancelModelLoad` must KEEP the `loadTask` reference (delete only
   `loadTask = nil`) — nil-ing it breaks the chain anchor and re-opens the overlap.
3. **Pre-compile bail** — first line of `ATCTranscriber.load()`: `try Task.checkCancellation()`.
   Safe with setupLive's catch: superseders bump `modelSwapGeneration` BEFORE `cancel()`, so a
   `CancellationError` always carries a stale generation and the catch's generation gate blocks
   any UI writes (no "failed to load: cancelled" flash).

**Must NOT break.** Old-session-stays-live-until-commit (setupLive commit block untouched — the
chain only delays the new compile's start); watchdog unlock + messages; ConsoleUITests
test3/test3b/test4 (they tap via `if isEnabled` guards → skip, never fail). Accepted trade:
mid-load "change their mind" now waits ≤30 s for the watchdog unlock.

**New tests.** `ATCTranscriberCancelTests.testLoadBailsBeforeCompileWhenCancelled` — self-cancel
via `withUnsafeCurrentTask { $0?.cancel() }` before `load()` → expect `CancellationError`
(a folder error instead means the check is missing) and `isLoaded == false`.

**Manual QA (device, both models downloaded).** Rapid-tap A→B→A during a slow compile: picker
locks, Xcode memory gauge never shows two resident compiles, watchdog unlocks at 30 s, the final
selection lands.

---

### H3 — Always-on frequency snap silently rewrites a correctly-heard handoff frequency
**Severity:** HIGH · **Files:** `Core/SlotSnap.swift` (apply :67, snapFrequency :196-213,
onRaster :191-194), `Engine/LivePipeline.swift` (:265)
**Status:** FIXED in 055bf89

**Symptom.** "Contact center 133.65" where the airport publishes 133.75 (but not 133.65) →
the transcript shows **133.75**. A single-digit rewrite to another plausible, official-looking
frequency; handoff frequencies are exactly the ones absent from a single airport's table. Runs
even with every correction toggle off.

**Product decision (owner, 2026-07-11).** A heard value that is already a **valid airband
channel** (in-band 118–136.99 AND on-raster) is NEVER rewritten — verdict reads `unverified`.
Only a garbled/impossible value (off-raster or out-of-band) may snap to a unique Levenshtein-1
published candidate.

**Parity constraint (verified, load-bearing).** The fixture set CONTAINS an in-band on-raster
snapped case (127.55 → 126.55), so the policy CANNOT be unconditional inside `snapFrequency` —
it must be gated on a **defaulted parameter** that fixtures never pass (they call
`SlotSnap.apply(text, context:)` with two args → flag false → byte-identical path).

**Required change.**
1. **Restore Python parity in `onRaster`** (the Swift port lags the reference's live FP#4 fix):
   accept the universal 2-decimal shorthand for `.xx5` channels ("124.67" = 124.675) via a fixed
   2-iteration loop over `[mhz, mhz + 0.005]`. Without this, common spoken handoff forms
   ("126.42") are classed garbled and stay snappable — the exact bug class being killed.
   Fixture-safe: no fixture reaches the raster check with an in-band off-25 kHz value (verified
   per-value: 126.55×4, 127.55×2, 141.2, 121.8).
2. **Flag-gated guard** in `snapFrequency`, between the `verified` check and the edit-1 snap:

```swift
// PRODUCT POLICY (Swift-only, 2026-07-11; python-legacy deliberately NOT updated — same pattern
// as the nav-band branch below): a heard value that is already a plausible airband channel
// (in-band + on-raster) is NEVER rewritten — it is most likely a handoff to a facility outside
// this airport's published table. Only a garbled/impossible value may snap. The parity fixtures
// never set `conservative`, so the Python-validated behavior below is byte-identical.
if conservative, airband.contains(heard), onRaster(heard) { return ("unverified", nil) }
```

   threaded from `apply(_:context:telephony:conservativeFrequencies: Bool = false)`.
3. **`LivePipeline.process`** passes `conservativeFrequencies: true` unconditionally (there is no
   setting — the policy is unconditional). The adoption gate needs NO change: an `unverified`
   edit has `applied == false`, so no rewrite is adopted, `SnapGrounding` emits
   `"unverified frequency"` to the confidence gate, and `CorrectionValidator`'s digit guard
   blocks any LLM rewrite of the digits — the policy holds end-to-end.
4. One-line note in `python-legacy/docs/PIPELINE.md` (SlotSnap frequency row) recording the
   deliberate iOS-only divergence.

**Must NOT break.** `SnapParityTests` (all three), `AirportContextStoreTests.
testFrequencyNeverSnapsAcrossBands` + `testILSFrequencySnapsInNavBand` (nav-band branch untouched
by the airband-only gate), `VicinityGroundingTests`, `SnapReplayTests`, `renderFrequency`/`trimFreq`.

**New tests.** New `SlotSnapPolicyTests.swift` (ctx: `["TWR":[133.65]]`):
valid 133.75 → NOT snapped, verdict `unverified`, `applied == false`;
shorthand 133.62 (= 133.625) → protected (pins the onRaster restore);
garbled 133.61 (off-raster both arms) → still snaps to 133.65;
out-of-band 141.2 → `invalid`; heard 133.65 → `verified`;
same input WITHOUT the flag → `snapped` (unit twin of the fixture guarantee);
nav-band branch unaffected by the flag.
Plus `SnapReplayTests.testReplayConservativeFrequencyPolicyThroughProcess` (through the real
`process()` with grounding pushed via `setGroundingAirports`).

---

## MEDIUM

### M1 — Loud cockpit → transcribes engine noise forever
**Severity:** MED · **Files:** `Audio/VADSegmenter.swift`, `Engine/LivePipeline.swift` (run loop)
**Status:** FIXED in c567635

**Symptom.** Ambient RMS above ~0.144 (the auto-gate ceiling `maxNoiseFloor 0.08 × noiseMargin
1.8`) makes every frame read as speech; the 8 s cap re-opens forever → nonstop Whisper on noise.

**Policy.** **Surface, do NOT auto-adapt.** Raising/re-seeding the floor is forbidden — the clamp
exists so a loud steady VOICE can't train the floor (`testLoudContinuousSignalStillReadsAsSpeech`
pins it; a long readback storm must keep transcribing). The correct escape hatch already exists:
the calibrated absolute gate (uncapped). Suggest-don't-act is house style.

**Required change.** A bounded runaway detector: **3 consecutive max-cap emits with zero
intervening sub-gate frames** (~24 s gapless "speech" — real ATC always has PTT gaps).
- `noteCapEmit()` at the plain cap-emit and the streaming `.speaking` cap-emit — NOT the
  `.confirmingOnset` merged cap (reached only after a gap; counting it double-counts a
  non-runaway).
- Reset: `if !sp { consecutiveCapEmits = 0 }` right after `isSpeechFrame`; also in
  `resetToIdle()`; `setSquelch` resets the counter AND re-arms the one-shot `runawaySurfaced`
  latch (one nag per squelch configuration).
- `consumeRunawayNoise() -> Bool` poll-and-clear; `LivePipeline.run` polls it after each
  `feed()` and forwards *"Constant noise on the input — the channel never goes quiet. Calibrate
  the squelch in Settings."* on M3's `onTrouble` channel.
- Segmentation behavior itself is UNCHANGED — segments still emit; detection must not gate audio.

**Must NOT break.** All pinned VAD invariants: `testLoudContinuousSignalStillReadsAsSpeech`
(300 frames = one cap → no latch), `testMaxSegmentCapEmits`, `testContinuousAmbient…`,
`testCalibratedAbsoluteGateAppliedUncapped`, `testDefaultsAreTunedForLowLatency`, all streaming
tests (none feeds ≥3 gapless caps).

**New tests** (`now: { 0 }`, `frames(n, amp)` style): gapless 810 frames → 3 segments AND latch
true, second consume false, one-shot holds; single cap no latch; one sub-gate frame resets;
`setSquelch` re-arms; streaming twin.

---

### M2 — Transcript lines can append out of order; the last line before a stream end can vanish
**Severity:** MED · **Files:** `Engine/LivePipeline.swift` (run/emit), `Engine/TranscriptionSession.swift` (:54-73)
**Status:** FIXED in c567635

**Root cause.** Each `onRecord` hops to the main actor via an independent `Task {}` (no FIFO
guarantee); the terminal `.stopped` flip can win the race against the final drained record's
pending append, whose `guard status == .live…` then drops it.

**Required change.** Make `onRecord` async and await it end-to-end:
- `run(source:onRecord: @escaping @Sendable (TranscriptRecord) async -> Void, …)`;
  `emit()` does `await onRecord(record)`.
- Session closure: `{ [weak self] record in await MainActor.run { self?.append(record) } }`.
  Sequential awaits ⇒ FIFO order AND `run()` cannot return (and flip status) until every append
  has landed — the natural-end drop is fixed by construction. The terminal block is UNCHANGED.
- **Preserved semantics:** explicit user `stop()` still drops in-flight drain records via the
  :235 guard (documented behavior — add one sentence to that comment).
- Call sites (grep-verified, 4): only `TranscriptionSession:55` changes. `ATCKitProbe/main.swift`
  (×2), `SnapReplayTests:65`, `FusionShadowLogTests:59` pass sync closures that implicitly
  convert — no edits; verify a warning-free build.
- `onLevel`/`onActivity` stay sync (last-write-wins meter / idempotent bracket).

**New tests.** `LivePipelineOrderingTests.swift` — N scripted records arrive in order, all
present before `run` returns; a feed ending MID-SPEECH (only record comes from `flush()`).
`TranscriptionSessionDrainTests.swift` (@MainActor) — natural end keeps the final record
(`detail == "Stream ended."`); explicit stop still drops in-flight.

---

### M3 — A decode error silently discards the whole transmission
**Severity:** MED · **Files:** `Engine/LivePipeline.swift` (:228 + run), `Engine/TranscriptionSession.swift`,
`UI/AppModel.swift` (beginCapture), `UI/SidebarView.swift` (LatencyCard)
**Status:** FIXED in c567635

**Root cause.** `(try? await transcriber.transcribe(…)) ?? .empty` swallows every error; empty
text → `return nil` → the transmission vanishes with no indication.

**Required change.**
- do/catch. **`catch is CancellationError` → plain `return nil`** (stop() cancels the run task;
  without this every user stop would flash "Decode failed"). Other errors: `NSLog` +
  `onTrouble?("Decode failed — a transmission may have been lost.")` + `return nil` (no fake
  record).
- `onTrouble` stored on the pipeline like `onRefined`, set in `run()` (defaulted-nil param;
  shared with M1).
- **Plumbing correction (verified):** `session.detail` is NOT mirrored into AppModel. The
  session's `noteTrouble(msg, forward:)` increments `stats.addDecodeFailure()` (new
  `decodeFailures` on `LatencyStats` — `$stats` IS mirrored) and forwards to an AppModel-supplied
  closure; `beginCapture` passes `{ msg in Task { @MainActor in self?.detail = msg } }` (the
  Stratux onTrouble pattern). Status stays `.live`.
- Diag: `LatencyCard` gains a decode-failures cell rendered only when `> 0`.
- Keep `ATCTranscriber`'s internal fallback `try?` (legit fallback path).

**New tests.** `LivePipelineDecodeFailureTests.swift` — throwing transcriber → 0 records + ≥1
trouble message; `CancellationError` → 0 records + 0 trouble; `LatencyStats` counter unit.

---

### M4 — First-run mic-permission grant can start capture on stale state
**Severity:** MED · **Files:** `UI/AppModel.swift` (start :1406-1433, stop :1499-1507)
**Status:** FIXED in 3c7a350

**Root cause.** The `requestRecordPermission` completion re-checks only `granted`. While the
dialog sits open, the session can be swapped (model switch), the run stopped/standby'd/
backgrounded, or the source re-picked — and `start()` sets nothing synchronously pre-prompt.

**Required change.**
- Pre-prompt token: `.starting` is currently unused (the session jumps straight to `.live`) →
  set `status = .starting; detail = "Waiting for microphone permission…"` synchronously before
  the prompt; capture `let requested = source`.
- Completion guard via a pure predicate (unit-testable; the dialog is not):

```swift
nonisolated static func captureRequestStillCurrent(sessionMatches: Bool, status: SessionStatus,
                                                   sceneActive: Bool, source: SourceKind,
                                                   requested: SourceKind) -> Bool {
    sessionMatches && status == .starting && sceneActive && source == requested
}
```

  Abort silently on failure; denied → `.error` with the Settings-path message.
- **Companion fix in `stop()`:** `if status == .starting { status = .stopped }` so
  Stop-during-prompt genuinely aborts (today `session.stop()` no-ops on a never-started session).
- Verified benign side effects: `.starting` → power button reads "Stop" during the prompt
  (correct affordance — and it now aborts); calibration disabled; standby/background reset
  `.starting` → the completion aborts.

**New tests.** `StartPermissionGuardTests` — table-driven predicate matrix (all-current true;
stale session/status/scene false; source mismatch false, usb-vs-mic strict).
**Manual QA.** Open the first-run prompt, then before answering: model swap / Stop / background /
source re-pick — grant each; capture starts only in the untouched case.

---

### M5 — The number-word guard misses teens/tens ("fifteen" → "fifty" passes)
**Severity:** MED · **Files:** `Core/CorrectionValidator.swift` (:209-217)
**Status:** FIXED in 6511f35

**Root cause.** `spokenDigits` maps only units + "oh"; teens/tens words produce empty digit
lists on both sides, so an LLM edit `fifteen→fifty` passes every guard (ratio 0.67 > 0.55).

**Required change.** Keep `spokenDigitWords` as-is; extend only the lookup, reusing the canonical
tables the same file already uses in `phoneticSkeleton`:

```swift
private func spokenDigits(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { !$0.isLetter })
        .compactMap { tok -> String? in
            let w = String(tok)
            if let d = Self.spokenDigitWords[w] { return d }                              // unit / oh
            if let n = ATCNormalize.teens[w] ?? ATCNormalize.tens[w] { return String(n) } // 15 / 50
            return nil
        }
}
```

"fifteen"→["15"] vs "fifty"→["50"] differ → rejected. Whole-token matching means "attention"
can't trip on "ten"; the "fourty" spelling variant maps like "forty" (a spelling fix passes).
**Collateral verified clean:** digitizing edits (fifteen→15) are already rejected by the numeral
guard; spoken renumbering is `normalizeNumbers`' job (validator-free); no existing test proposes
a teens/tens edit.

**New tests.** `SecurityGuardTests.testTeensAndTensWordSwapRejected` (permissive allowed-set so
the NEW guard is provably the rejector: fifteen→fifty, thirteen→thirty) +
`testNonNumericEditNearTeensStillPasses` (control: a benign fix near "fifteen" passes).

---

### M6 — Phonetic correction picks a different name run-to-run on a tie
**Severity:** MED · **Files:** `Core/ATCCorrector.swift` (:252-258)
**Status:** FIXED in 6511f35

**Root cause.** Stage-3 phonetic fallback iterates `Array(canon.keys)` (Swift Dictionary order is
per-process random) with strict `r > bestRatio` and no tie-break. Stage 2 (`closestMatch`) added
the difflib tie-break for exactly this reason; stage 3 didn't.

**Required change.** Deterministic difflib-style tie-break, no force-unwrap:

```swift
for nv in normVocab where keys[nv] == key && nv != nw {
    let r = SequenceMatcher(nw, nv).ratio()
    guard r >= phoneticMin else { continue }
    let wins: Bool
    if let b = best { wins = r > bestRatio || (r == bestRatio && nv > b) } else { wins = true }
    if wins { best = nv; bestRatio = r }
}
```

Comment records the Python divergence-on-tie (Python is vocab-order-first-wins; no parity value
exercises a tie — verified in `parity_check.py` + `testPhoneticFallback`, both single-term
vocab) so a future fixture-regen surprise is diagnosable in seconds.

**New test.** `ATCCorrectorTests.testPhoneticTieBreakIsDeterministic` — "golf" vs
`["Gelf","Gilf"]` (shared phonetic key, ratio tie 0.75 < the 0.84 stage-2 cutoff → stage 3
decides), both vocab orders, repeated runs → always "Gilf".

---

### M7 — Heat/app-switch destroys the map and loses the pilot's pan/zoom
**Severity:** MED · **Files:** `UI/AppModel.swift` (thermal :269/:628-631), `UI/MapHostView.swift`,
`UI/ChartMapView.swift` (framing :391-403)
**Status:** FIXED in 3c7a350

**Root cause.** (a) `thermalSerious` is a raw `>= .serious` compare with no hysteresis — a device
hovering at the threshold flips it repeatedly, and each flip destroys/recreates the
`ChartMapView` (new Coordinator, `didFrame` reset → snaps to default framing + full context
refetch). (b) Nothing preserves the user's camera across a legitimate teardown.

**Required change.**
- **(a) Exit dwell:** `applyThermal(serious:)` — enter immediately; exit via a single
  `thermalClearTask` sleeping 60 s, cancelled on re-entry (cancellation replaces an epoch —
  exactly one pending clear), with a fire-time re-check of the live thermal state.
- **(b) Camera preservation, no new delegate work:** piggyback the EXISTING settle hook
  (`regionDidChangeAnimated` → `onVisibleRegion`, already debounced 0.4 s, lands in MapHostView).
  Store `SavedMapCamera` (plain doubles + `savedAt`) transiently on AppModel — deliberately NOT
  `@Published` (settle-rate writes must not re-render the console) and NOT UserDefaults (a fresh
  launch should frame the route). New defaulted `restoreCamera` input on `ChartMapView`
  (RouteMapSheet untouched); the restore goes FIRST in the `!didFrame` chain and claims
  `didFrame`; pure `cameraIsFresh(savedAt:now:)` (30 min staleness).
- Verified precedence: the `--preview-proc` procedure reconcile runs BEFORE the `!didFrame` chain
  and claims `didFrame` → on a rebuild with a preview active the procedure re-frames (intended —
  comment it). Fresh launch → no saved camera → existing route/launchCenter framing runs.

**Must NOT break.** Fresh-launch route framing; `--chart-center`/`--chart-layer` launch paths;
the thermal teardown itself (the power-saving goal stays); MapInteractionTests; ChartLibraryTests.

**New tests.** `MapCameraTests` — `cameraIsFresh` at 0 s / 29 min → true; 30 / 31 min → false.
Dwell = manual QA (debug 2 s dwell: map blanks instantly on `.serious`, returns after cooling,
camera intact).

---

## LOW

### L1 — Feed monitor goes permanently silent after an interruption
**Files:** `Audio/AudioMonitor.swift` · **Status:** FIXED in f8af58e
**Fix (final): self-heal in `play()` only — NO observer** (play is called ~2×/s on a live feed →
recovery within one chunk; an observer adds lifecycle to an app-lifetime singleton for nothing).
`if running, !engine.isRunning { healLocked() }` at the top of `play()`: `player.stop()` (flushes
stale buffer completions) → prepare/start/play → volume reapplied → `queued` reset (mirrors
`start()`) → bounded `restartFailures < 5` else `running = false`. Reset `restartFailures` in
`start()`. Known limitation (document, don't fix): after `mediaServicesWereReset` the engine
object may be unrecoverable — heal fails 5×, monitor silent until the next Start (acceptable for
a convenience feature; rebuilding the engine risks the re-attach crash noted in the file).
**Test:** `AudioMonitorTests.testPlayHealsAfterEngineStops` via a `#if DEBUG` hook
(`_stopEngineForTests`), or device-verify if hooks are rejected.

### L2 — A wedged radio-stream decoder never reconnects
**Files:** `Audio/StreamAudioSource.swift` · **Status:** FIXED in f8af58e
**Fix (final):** funnel everything into the existing reconnect/give-up machinery.
(1) Extract the retry tail of `didCompleteWithError` into `scheduleRetry()` (rotation +
`connectAttempts` give-up + 2 s backoff, unchanged). (2) Check `AudioFileStreamOpen`'s OSStatus —
on failure call `scheduleRetry()` DIRECTLY (no task exists yet, so completion never fires).
(3) `AudioConverterNew` failure → `task?.cancel()` (forces `didCompleteWithError`).
(4) **No-decode watchdog** (primary): generation-countered, callbackQueue-confined — 10 s after
each `connect()` with no PCM emitted (`decodedThisConnection` false) → `task?.cancel()`.
Healthy-stream triple guard: `stopped` + generation match + `decodedThisConnection`. Lifetime-
decoded streams keep today's unbounded-reconnect design (live streams drop periodically).
**Test:** `StreamAudioSourceGiveUpTests.testUnreachableFeedGivesUpAndFinishesStream` —
`http://127.0.0.1:1/dead.mp3` (refused instantly, offline-safe) → the stream FINISHES with zero
chunks well inside a 30 s test timeout.

### L3 — Transcript append housekeeping at the 500 cap
**Files:** `Engine/TranscriptionSession.swift` (:239) · **Status:** FIXED in c567635
**Fix (final): do nothing — document.** `removeFirst` moves 1 element/append (~µs at 500); the
real cost is the `@Published` full-array republish, inherent to the contract. A ring buffer
changes `records`' semantics for every consumer (UI diffing, AppModel mirror, EFB sink,
`applyRefinement` firstIndex, per-row labeler writes) for no visible win. Change = a 3-line
comment above :239 recording the considered-and-rejected alternative. `refuseAll` left alone
(user-rare; per-row writes deliberate for single-row SwiftUI diffs).

### L4 — EFB grounding queries CIFP on the main thread per transmission
**Files:** `UI/AppModel.swift` (interpretForEFB :939-961 + helpers) · **Status:** FIXED in ea42e3c
**Fix (final):** `efbGroundingCache: (ident, plan, grounding)?` + `efbGroundingEpoch`;
`nonisolated static buildEFBGrounding(ident:routeIdents:endpointAirports:)` runs off-main
(Task.detached + epoch guard), fetches procedures ONCE and splits SID/STAR in one pass.
`interpretForEFB` fast-path: `guard let cache, cache.ident == ident, cache.plan == flightPlan
else { refreshEFBGrounding(); return }` (FlightPlan is Equatable — catches in-place edits).
Invalidation triggers (exact): the setupLive commit after `liveContext = context`; `airport`
didSet (didFinishInit-gated); `flightPlan` didSet (covers editPlan/directTo/loadProcedure/EFB
accepts). `syncGrounding` does NOT change the ident — no hook. DELETE the three now-dead helpers
(`efbKnownFixes`/`efbKnownAirports`/`efbProcedureIdents`) — unused privates warn. Semantics
identical (same caps/dedupe/uppercase); only freshness changes: the FIRST addressed transmission
after an airport/plan change may skip (miss-safe, documented).
**Tests:** `EFBGroundingCacheTests` — builder dedupe/uppercase/empty-ident (+ KBOS case if the
CIFP db is present).

### L5 — Session→UI bindings accumulate per model swap
**Files:** `UI/AppModel.swift` (:754-762) · **Status:** FIXED in 3c7a350
**Fix (final):** `sessionCancellables: Set<AnyCancellable>`, `.removeAll()` BEFORE rewiring; the
six `.assign(to: &$…)` become `.sink { [weak self] in self?.x = $0 }.store(in:)` (the session is
`@MainActor` → delivery identical incl. the initial replay; `.assign(to:on:)` rejected — retains
self). Deliberate behavior FIX to note in the commit: after a swap, `oldSession.stop()` no longer
clobbers the new session's status. Keep the subscriptions before `self.session = session`.
**Verify:** ConsoleUITests test4/test7 + a memory-graph check that swapped-out sessions now
deallocate (they currently don't).

### L6 — A hung LLM cleanup blocks all later cleanups with no timeout
**Files:** `Engine/LLMRefiner.swift` · **Status:** FIXED in 493eb4a
**Fix (final): a watchdog, NOT a `withTimeout` race.** Copying `CascadeCorrector.withTimeout` is
WRONG here: `withTaskGroup` awaits all children at scope exit, and a non-cancellable llama.cpp
generation would block it — silently defeating the timeout. Instead decouple REPORTING from
compute: an actor-isolated watchdog Task delivers `.skipped` at the deadline (default 20 s —
generous; a throttled iPad is legitimately slow), guarded by an `inflight: UUID?` exactly-once
token (both delivery sites are actor-isolated; the worker's cancel-then-deliver block has no
suspension point, so double-delivery is impossible; a stale watchdog fails the id guard). The
drain still fully awaits the corrector before dequeuing — the serial one-generation invariant
(llama.cpp KV-cache) is preserved by construction; worst case the queue stalls behind one hang
and the existing `maxQueue` backpressure sheds load, exactly today's bounded behavior. No new
`RefinementState` — `.skipped` reused; update its two doc comments to "dropped under load or
timed out".
**Tests:** `testRefinerTimeoutReportsSkippedExactlyOnce` (slow corrector, 0.15 s timeout — one
outcome, no double-delivery after the stale return); `testRefinerFastRequestIsNotTimedOut`;
`testRefinerNeverOverlapsGenerationsAfterTimeout` (a ConcurrencyProbeCorrector asserting
`maxActive == 1` — the test that actually matters).

### L7 — The optional cloud text-cleaner accepts an insecure address
**Files:** `Core/CascadeCorrector.swift` (:72-78), `UI/AppModel.swift` (remoteFixerURLValid),
`UI/SettingsSheet.swift` (hint) · **Status:** FIXED in 6511f35
**Fix (final):** `isEndpointAllowed(url)`: https anywhere; http ONLY for private/loopback hosts
via a pure bounded `isPrivateHost` (localhost, ::1, *.local, 10/8, 127/8, 172.16/12, 192.168/16 —
UInt8 quad parse, no DNS, no I/O). Rejects plain-http public hosts AND the old
`hasPrefix("http")` hole ("httpfoo://"). Rationale: the cockpit legitimately uses LAN http
(Stratux at `http://192.168.10.1`; a local LLM box on ship Wi-Fi is the use case) — transcripts
must simply never leave the aircraft unencrypted.
**Companion (load-bearing):** `AppModel.remoteFixerURLValid` claims to mirror this guard but
currently accepts any http — replace its body with `RemoteLLMCorrector.isEndpointAllowed(u)` and
update the SettingsSheet hint copy ("Needs https, or http on a private LAN host — ignored").
**Tests:** transport-policy matrix (https public ✓; http 192.168/10/172.16-31/127/localhost/
*.local ✓; http public ✗; 172.32 boundary ✗; httpfoo ✗; ftp ✗; not-a-quad ✗) +
`isPrivateHostClassification` unit (incl. "256.168.0.1" → false).

### L8 — Map re-runs the same procedure query many times a second
**Files:** `UI/MapHostView.swift` (:27-32), `UI/AppModel.swift` · **Status:** FIXED in ea42e3c
**Fix (final):** resolve ONCE in AppModel (centralizes all four setters): `previewedProcedure`
gains a `didSet → resolvePreviewedProcedure()` (off-main Task.detached + `previewEpoch` guard,
legs bounded `.prefix(256)`) → `@Published private(set) previewedProcedureLegs: [ResolvedLeg]`.
**Gotcha:** `didSet` is inert in `init` — the `--preview-proc` launch path needs one explicit
`resolvePreviewedProcedure()` call after the assignment. MapHostView deletes the computed prop
and reads the published value. The overlay appears one publish later (imperceptible; the map's
procKey reconcile + framing are unchanged). Manual: `--preview-proc KBOS`.

### L9 — Transcript list re-derives itself on every unrelated update
**Files:** `UI/TranscriptView.swift`, `Engine/LivePipeline.swift` (TranscriptRecord) · **Status:** FIXED in ea42e3c
**Fix (final):** extract `TranscriptListSection: View, Equatable` taking records/callsignFilter/
newestFirst/theme as plain values, with an explicit `==` that compares **the full records array**
— a count+last.id shortcut would freeze in-place refinements; Swift's `Array ==` fast-paths
identical storage so unrelated publishes cost O(1). PREREQ: `TranscriptRecord` gains `Equatable`
(all members already conform — verified). Boundary: the parent keeps the header/meter/empty
states (the storm reads); the child owns the filter banner + ScrollViewReader list + `atNewest`
`@State` + jump button; pure static `ordered(_:filter:newestFirst:)` for unit tests.
`TranscriptRow`'s own `@EnvironmentObject` is a noted follow-up (out of scope).
**Tests:** `TranscriptOrderingTests` (ordering matrix + an equality-semantics case: an in-place
`llmCorrected` mutation compares unequal — guards the refinement repaint).
**Guards:** ConsoleUITests test5/test6; scroll-follow behavior preserved via `onChange` keys.

### L10 — Traffic markers blink instead of gliding
**Files:** `UI/ChartMapView.swift` (syncDynamic :690-706) · **Status:** FIXED in ea42e3c
**Fix (final):** diff by **`Aircraft.hex`** (the stable id — labels collide and can be nil):
`trafficByKey: [String: TrafficAnnotation]` + a single `ownshipAnn`. Survivors get in-place KVO
`coordinate` writes (`@objc dynamic` — MapKit animates the move) + title refresh; a track change
updates the ON-SCREEN view's transform via `mv.view(for:)` (off-screen annotations get a fresh
transform from `viewFor`). Departed removed, new added; incoming bounded `.prefix(128)` with a
duplicate guard. `probeObjects`' traffic loop reads `trafficByKey.values`. Extract the pure
set-diff as `TrafficReconcile.plan(existing:incoming:)` for unit tests.
**Tests:** `TrafficReconcileTests` (disjoint/overlap/duplicates/empty). Manual: markers glide,
headings rotate.

### L11 — Chart tiles re-converted on every pan
**Files:** `UI/ChartMapView.swift` (MBTilesTileOverlay :74-91) · **Status:** FIXED in ea42e3c
**Fix (final):** KEEP the WEBP→PNG transcode (the "MapKit renders PNG/JPEG natively" comment is
load-bearing; native-WebP is a separate device-verified follow-up). Add an
`NSCache<NSString, NSData>` keyed `"z/x/y"` per overlay (one overlay per reader/pack → the cache
frees with the overlay on pack eviction), `totalCostLimit = 48 MB`, `cost = png.count`; NSCache is
thread-safe for MapKit's background tile queues and self-evicts under memory pressure.
Undecodable data → raw fallthrough (old behavior). Verify with Instruments: one transcode per
tile, zero on revisits.

### L12 — Tapping the map does its lookups on the drawing thread
**Files:** `UI/ChartMapView.swift` (handleTap/probeObjects :457-518) · **Status:** FIXED in ea42e3c
**Fix (final):** split `probeObjects` into `beginProbe` (main: `mv.convert` screen math, BBox,
`probeGen &+= 1`) → `Task.detached` (the `NavDatabase.nearby` full-table scan + `airspaces` +
`containsCoord` — value structs, safe to hop) → main-actor `rankProbe` (live-map screen
distances, routeLegs, trafficByKey, `MapProbe.rank`) with airspace-after-points and
userPoint-first ordering preserved VERBATIM. Stale-probe drop via generation mismatch doubles as
double-tap debounce (one sheet, the latest tap). Copies `refreshContext`'s `contextGen` idiom.
**Guards:** MapInteractionTests rank tests (pure). Manual: rapid double-tap → one sheet; taps
stay responsive during a fast pan.

### L13 — A malformed chart-catalog entry would crash the app
**Files:** `UI/ChartMapView.swift` (:118), `UI/ChartLibrary.swift` (:113),
`ATCTranscribeTests/ChartLibraryTests.swift` (:73) · **Status:** FIXED in ea42e3c
**Fix (final):** `remote: URL?` with an `addingPercentEncoding(.urlQueryAllowed)` fallback;
`ensureOnDisk` guards `let remote = e.remote else { return nil }` — verified nil routes through
the EXISTING pack-unavailable path (`ChartStore.load` anyFailed → `.failed`; `prefetch` skips) —
no new error plumbing. Update the test at :73 to `try XCTUnwrap(ny.remote)`.
**New test:** a fixture path with spaces → percent-encoded URL non-nil (the fallback path).

---

## Execution order & verification

Commit groups (one commit each, full unit suite after every group):
1. H2 → 2. M2+M3+M1 → 3. H1+L1+L2 → 4. M6+M5+L7 (+`parity_check.py`) →
5. H3 alone (full parity battery) → 6. L6 → 7. M4+L5+M7 → 8. perf batch
(L4→L8→L9→L10→L12→L11→L13→L3-comment).
Adversarial review over groups 1-6 before pushing; a lighter pass over 7-8.
Regenerate the Xcode project (`~/.xcodegen/xcodegen/bin/xcodegen generate`) whenever a group adds
new files. Zero app-source warnings throughout.

Manual QA checklist (device): §H1 (interruptions), §H2 (rapid swap), §M4 (permission timing),
§M7 (thermal dwell + camera), L10/L12 (map feel), plus one end-to-end LiveATC session.

## Outcome (2026-07-11)

All 23 findings implemented across 8 commits (`877a43a` … `ea42e3c`); full unit suite
**438/0** on iPad Pro 11" (M5) sim, zero app-source warnings, `SnapParityTests` +
`parity_check.py` byte-parity 29/29 after H3.

A 16-agent **adversarial review** (one skeptical reviewer per commit → each finding
independently refutation-tested) then ran over all 8 commits. It confirmed **3 defects, all in the
H1/L1/L2 audio-recovery commit** (a startEngine hot-mic race, a startup-watchdog false terminal
during an interruption, and a negative `queued` counter in the monitor) — fixed in `50294b0`; 2
further findings were refuted. The other 7 commits reviewed clean. Manual on-device QA of the
interruption/thermal/permission-timing items above remains the last gate before a build ships.
