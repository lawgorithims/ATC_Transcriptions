# CommSight (ATCTranscribe) — Pipeline Walkthrough for New Engineers

This is the "how does data actually flow through the app" guide. If you're an intern trying to
understand where a transcript line comes from, start here. It complements
[`ios/README.md`](README.md) (which covers *what* the app is and the Swift↔Python mapping); this
doc covers the *runtime pipelines* subsystem by subsystem, in plain terms, and ends with a
**Fragile Regions** appendix — the spots a careful reviewer flagged, so you don't get surprised.

The app runs the entire ATC-transcription pipeline **on-device** on an iPad in a cockpit:
listen to a radio feed → detect speech → transcribe with Whisper → correct/ground it →
label the speaker → show it, and (optionally) turn a spoken clearance into a one-tap Electronic
Flight Bag (EFB) action. There is no server.

```
 Audio source ──► VAD segmenter ──► Whisper ──► correction (3 tiers) ──► speaker fusion ──► UI
 (mic/feed/USB)   (finds speech)   (on ANE)     (snap + optional LLM)     (who said it)      (transcript + map)
                                                                                              │
 ADS-B / GPS ─────────────────────────────────────────────────────────────► grounds the corrector + map
 Flight plan (filed) ──────────────────────────────────────────────────────► grounds the corrector + drives the EFB
```

---

## 1. Audio capture

**Entry point:** `AppModel.start()` picks an `AudioSource` by type:
- `DeviceAudioSource` — mic or USB, via an `AVAudioEngine` tap.
- `StreamAudioSource` — a LiveATC MP3 over HTTP (decoded with CoreAudio's `AudioFileStream` +
  `AudioConverter`, then resampled with `AVAudioConverter`).
- `StratuxAudioSource` — raw 16-bit PCM over HTTP from a Stratux receiver.
- `FileReplaySource` — a bundled clip, for the offline demo.

`AudioSessionManager.activate()` sets the iOS audio category (`.playAndRecord` when capturing,
`.playback` otherwise). Optionally the source is wrapped in a `MonitoredSource` so the feed is
also **audible** through the speakers.

**The universal contract:** every source exposes `makeStream()` → an
`AsyncStream<[Float]>` of **mono, 16 kHz, float** audio chunks. Everything downstream only sees
that stream, so the four sources are interchangeable.

**Key types:** `AudioSource` (protocol), `AudioSessionManager`, `MonitoredSource`, `AudioMonitor`.

---

## 2. Voice activity → speech segments

`LivePipeline.run()` consumes the audio stream `for await` and feeds each chunk to
`VADSegmenter.feed()`. The segmenter buffers audio into 30 ms frames and runs an
**energy-vs-noise-floor state machine**: it learns the ambient noise level, decides which frames
are speech, and cuts a `SpeechSegment` when it sees a silence gap, hits an 8-second cap, or (in
speaker-aware mode) detects a confirmed speaker change. Each finished segment is handed to the
transcription engine.

**Key types:** `VADSegmenter`, `SpeechSegment`.

---

## 3. Transcription engine + session lifecycle

**Entry point:** `TranscriptionSession.start(source:)` (on the main actor) spins up one long-lived
task that drives the `LivePipeline` **actor**. For every speech segment, `LivePipeline.emit()`:

1. (if diarization is on) splits the segment into per-speaker pieces via the `Diarizer`;
2. for each piece, `process()` builds a decoder prompt from `ATCContext`, preprocesses the audio,
   and calls the `ATCTranscriber` actor (WhisperKit / CoreML on the Neural Engine) to get raw text;
3. runs the correction tiers (§4) and extracts the callsign + speaker role;
4. optionally queues the segment to the background LLM refiner behind a confidence gate;
5. returns a `TranscriptRecord`.

Each record is delivered back through an `onRecord` closure, which hops to the **main actor** to
`append()` it into the `@Published records` array (capped at 500). `SpeakerLabeler` fuses the
final per-line speaker label there. Later LLM refinements arrive via `onRefined` and patch the
matching record **by id**.

**Model lifecycle** is separate and important: there is exactly one resident Whisper model.
When the user switches models, `AppModel.setupLive()` builds a **brand-new** pipeline + session
off to the side and only swaps it in once it's fully loaded, using a `modelSwapGeneration` counter
to discard a load that's been superseded. The old session stays live until the new one is ready,
so there's never a moment with no working model.

**Key types:** `TranscriptionSession`, `LivePipeline` (actor), `ATCTranscriber` (actor),
`TranscriptRecord`, `Diarizer`, `SpeakerLabeler`.

---

## 4. Correction — three tiers

Raw Whisper text is often close but imperfect ("niner tree" for "nine three", a slightly-wrong
runway). Correction has three tiers:

- **Tier 1 — fast inline (optional, off by default).** A `ChainCorrector`: hallucination filter,
  repetition collapse, phraseology fixes, then a deterministic number-word→digit + vocabulary
  near-miss pass. Only runs if the user turns correction on.
- **Tier 2 — deterministic "snap" (ALWAYS ON).** `CallsignSnap` then `SlotSnap` canonicalize the
  text and *ground* it against real-world data: runway/frequency/fix tokens are checked against
  the airport's **actual** runways and published frequencies, and rewritten only on a confident,
  unique, one-edit match. This is what `record.display` shows the pilot. *(Note: because this runs
  unconditionally, it's the tier that can silently change a heard value — see Fragile Regions.)*
- **Tier 3 — slow LLM (optional).** A `ConfidenceGate` decides if a transmission looks suspicious;
  if so, it's queued to the `LLMRefiner` actor (local llama.cpp or Apple Foundation Models) which
  runs **off the hot path**. Crucially the LLM's free-form output is **not trusted**:
  `CorrectionValidator` re-applies only edits that survive digit / direction / clearance-verb
  preservation, anti-hallucination, and grounding checks.

**Key types:** `SlotSnap`, `CallsignSnap`, `ATCCorrector`, `ConfidenceGate`, `LLMRefiner`,
`CorrectionValidator`, `ATCContext`.

---

## 5. Grounding data — where "the real world" comes from

The corrector and the EFB need to know *which airport, which runways, which traffic, whose
callsign*. That context flows from a provider chain, resolved off the main thread:
**filed flight plan → curated/offline map data → live GPS vicinity → OurAirports internet
fallback** (the last is used only in the internet-feed/demo mode). Coded procedures (SIDs/STARs/
approaches) come from a bundled read-only SQLite database (`cifp.sqlite`) via `CIFP`. Live aircraft
come from `ADSBService`; GPS from `StratuxService`. Stale data on the safety-critical paths is
defended by a **read-time expiry** so it can't linger.

**Key types:** `AirportContextStore`, `CIFP`, `NavDatabase`, `ADSBService`, `StratuxService`,
`FlightPlan`.

---

## 6. The EFB command interpreter (spoken clearance → one-tap action)

When a **controller** transmission is addressed to the pilot's **own** aircraft, `OwnshipIdentity`
+ `ATCCommandParser` turn a recognized clearance ("cleared direct BOSOX", "climb via the BLAZZER
SIX departure") into a **suggestion** — nothing changes until the pilot taps Accept. Enormous care
goes into *only* firing for ownship and *never* for another aircraft or a mention; see the
`OwnshipIdentity` header comment and its tests for the full rule set. This is the most
heavily-reviewed subsystem in the app.

**Key types:** `OwnshipIdentity`, `ATCCommandParser`, `EFBSuggestion`.

---

## 7. AppModel — the hub (and the god-object)

`AppModel` is one big `@MainActor` object (≈2,000 lines, ~91 `@Published` fields) that the SwiftUI
console binds to. Data flows **in** from three actor-backed producers (the transcription session,
`ADSBService`, `StratuxService`) whose updates hop to the main actor. Control flows **out** through
~78 `Task { }` blocks and imperative "sync" reconcilers (`syncTraffic`, `syncGrounding`,
`setupLive`, …). Three ideas keep it correct, and mostly hold:
1. everything that mutates a `@Published` field does so on the main actor;
2. heavy work (model compile, database scans, LLM load) is pushed onto actors or detached tasks;
3. stale data is defended by time-expiry + generation/epoch guards.

It is unusually careful for its size — but it's also where most of the app's complexity and most
of the Fragile Regions live. If you touch it, understand the `modelSwapGeneration` guard and the
main-actor rule before you start.

---

## 8. UI + moving map

The console (`ConsoleView`) is a SwiftUI `ZStack`: an always-on `MKMapView` chart
(`MapHostView` / `ChartMapView`) behind floating, draggable widget cards. The transcript lives in
`TranscriptCard`. A separate `WidgetStore` owns the widget layout **on purpose**, so the
several-times-per-second live-data storm (audio level, traffic, GPS) doesn't force the widget
chrome to redraw. `ChartMapView` (a `UIViewRepresentable`) reconciles map overlays each update:
the filed route, a previewed procedure, raster chart tiles (from local SQLite MBTiles packs),
airspace, navaids, and live traffic. The map is torn down entirely when the app is backgrounded or
the iPad overheats, so MapKit never starves on-device Whisper.

**Key types:** `ConsoleView`, `MapHostView`, `ChartMapView`, `MBTilesReader`, `WidgetStore`,
`FloatingWidgetContainer`, `TranscriptCard`.

---

## Appendix — Fragile Regions (where the bodies are buried)

A skeptical review (2026-07) flagged these. **All 23 audit findings were remediated in 2026-07** —
see `ios/REMEDIATION.md` for the per-issue spec and the SHA each landed in. This table is kept as
history + the guard-rail each fix now relies on; **read it before changing the relevant file.**

| File | What it was → how it's now guarded |
| --- | --- |
| `Audio/AudioSource.swift` | ~~No audio-interruption recovery~~ → **FIXED (H1, f8af58e).** `AudioSessionEvent` classifier + observers in DeviceAudioSource + bounded single-flight restart + repeating liveness watchdog. |
| `UI/AppModel.swift` (switchModel) | ~~Model-switch load not truly cancellable~~ → **FIXED (H2, 877a43a).** Task-chaining serializes compiles; `cancelModelLoad` keeps the chain anchor; whole picker locks during a load. Don't nil `loadTask`. |
| `Core/SlotSnap.swift:196` | ~~Frequency snap runs unconditionally~~ → **FIXED (H3, 055bf89).** `conservativeFrequencies` gate (defaulted false for parity) never rewrites a valid airband channel; `onRaster` restored the .xx5 arm. Byte-parity locked — change only via the defaulted flag. |
| `Audio/VADSegmenter.swift` | ~~Loud cockpit transcribes noise forever~~ → **FIXED (M1, c567635).** Runaway detector SURFACES a squelch nudge (3 gapless caps); the floor clamp is deliberately untouched (a loud voice must still transcribe). |
| `Engine/LivePipeline.swift` (process) | ~~Decode error swallowed silently~~ → **FIXED (M3, c567635).** do/catch surfaces `onTrouble` + a `decodeFailures` diag counter; CancellationError stays silent. |
| `Engine/TranscriptionSession.swift` | ~~Per-record Task hops → no ordering, last line droppable~~ → **FIXED (M2, c567635).** `onRecord` is async + awaited: FIFO, and run() can't flip status before the final drain lands. Explicit stop still drops in-flight (documented). |
| `Core/CorrectionValidator.swift` | ~~Digit guard omits teens/tens~~ → **FIXED (M5, 6511f35).** Lookup consults `ATCNormalize.teens`/`tens`; `fifteen`→`fifty` now rejected. |
| `Core/ATCCorrector.swift` | ~~Phonetic stage-3 nondeterministic on a tie~~ → **FIXED (M6, 6511f35).** difflib-style tie-break (lexicographically-larger wins), no force-unwrap. |
| `UI/AppModel.swift` (thermal) + map | ~~No thermal hysteresis; pan lost on rebuild~~ → **FIXED (M7, 3c7a350).** `applyThermal` 60 s exit dwell; `SavedMapCamera` restored first in the map framing chain (30 min freshness). |
| `UI/AppModel.swift` (permission cb) | ~~Stale-state capture after a grant~~ → **FIXED (M4, 3c7a350).** `.starting` currency token + pure `captureRequestStillCurrent`; stop() aborts during the prompt. |
| `Core/CascadeCorrector.swift` | ~~Remote fixer accepted plaintext-public http~~ → **FIXED (L7, 6511f35).** `isEndpointAllowed`: https anywhere, http only to private/LAN hosts. |
| `Engine/LLMRefiner.swift` | ~~A hung generation blocked all cleanups~~ → **FIXED (L6, 493eb4a).** Watchdog reports `.skipped` at 20 s via an exactly-once `inflight` token; serial invariant preserved. |
| `Audio/AudioMonitor.swift` / `StreamAudioSource.swift` | ~~Monitor silent / stream wedged after a drop~~ → **FIXED (L1/L2, f8af58e).** play() self-heal; stream no-decode watchdog + bounded give-up. |
| `UI/ChartMapView.swift` | ~~Tiles re-transcoded per pan; traffic blinks; catalog `URL!` crash~~ → **FIXED (L10/L11/L12/L13, ea42e3c).** NSCache PNG cache; in-place hex-keyed traffic diff; off-main tap probe; optional `remote` URL. |
| `UI/AppModel.swift` / `TranscriptView.swift` | ~~EFB/proc CIFP on main; transcript re-derives on every tick~~ → **FIXED (L4/L8/L9, ea42e3c).** Off-main grounding + legs caches; Equatable `TranscriptListSection`. |

**The systemic theme** the audit named (silent failures) is now addressed: interruption recovery,
the decode-failure counter, the runaway-noise nudge, and the transient `onNotice`/`onTrouble` detail
messages all surface a problem that used to look normal. A dedicated always-on health indicator
(mic live / feed live / last-update time) remains a worthwhile future consolidation.
