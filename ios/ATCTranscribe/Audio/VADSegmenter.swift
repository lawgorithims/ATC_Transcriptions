import Foundation

/// Tunables for `VADSegmenter`. Mirrors the constructor args of
/// `atc_stream.VADSegmenter` (and the `live_pipeline` block of `config.yaml`).
struct VADConfig {
    var aggressiveness = 2
    // Finalize a transmission after this much quiet. Tuned DOWN from 700 ms so back-to-back
    // transmissions from a fast-talking controller split on their short push-to-talk gaps instead of
    // merging into one long, late "batch". ATC intra-transmission pauses are shorter than this, so a
    // single transmission stays intact; separate transmissions (a PTT release ≈ 0.5 s+) split apart.
    var silenceDurationMs = 400
    var minSpeechMs = 500
    // Hard cap on one segment = the worst-case latency for truly continuous speech (no gaps at all).
    // Tuned DOWN from 12 s so even a gapless burst surfaces within a few seconds instead of ~15.
    var maxSegmentS = 8.0
    var preRollMs = 200
    /// Speech must exceed `noiseMargin ×` the tracked background-noise floor (on top of the
    /// absolute energy threshold). This keeps a noisy/static live feed — whose "silence" still
    /// carries hiss/squelch above the fixed threshold — from being treated as speech, so Whisper
    /// is NOT run on a quiet-but-noisy channel (the main idle-battery drain). 1.0 disables it.
    var noiseMargin: Float = 1.8
    /// Squelch mode. **Auto** (default) learns the noise floor from the gaps between transmissions
    /// (ATC is bursty: talk → silence → talk; the silence frames reveal the channel noise) and
    /// gates on `noiseMargin ×` it. **Manual** uses a fixed user threshold (`squelchLevel`) instead.
    var squelchAuto = true
    /// Manual squelch threshold, normalized 0…1 (mapped to an RMS gate). Used only when `!squelchAuto`.
    var squelchLevel: Float = 0.2
    /// An ABSOLUTE manual gate (RMS) from mic calibration, used verbatim (uncapped) when `!squelchAuto`
    /// instead of `squelchLevel`. nil = use the slider. Set precisely from a measured ambient/voice pair
    /// so a loud room gets its true gate (which can exceed the slider ceiling) — see `SquelchCalibration`.
    var calibratedGateRMS: Float?

    // MARK: streaming speaker-change segmentation (only used when `speakerAware`)
    /// A silence run this short is a candidate push-to-talk break (a turn boundary), NOT an
    /// end-of-transmission — arms a tentative boundary without emitting.
    var pttBreakMs = 160
    /// How much of the NEXT speaker to buffer before fingerprinting them to decide a turn change.
    /// ≥ ~300 ms so the pitch estimate is trustworthy on clipped VHF audio.
    var onsetConfirmMs = 280
    /// A confirmed change must survive a second fingerprint this much later (hysteresis vs. a single
    /// noisy verdict).
    var reConfirmMs = 60
}

/// Accumulates mono 16 kHz float32 PCM and emits contiguous speech segments via a
/// frame-based voice-activity state machine. Faithful port of `atc_stream.VADSegmenter`.
///
/// With `speakerAware` (wired to diarization), it also runs a **streaming speaker-change** phase
/// machine over the same frame loop: at a short push-to-talk gap it snapshots the current turn, and
/// as soon as the next speaker is confirmed acoustically different it EMITS the snapshot immediately —
/// surfacing each turn ~as it ends instead of waiting for the whole exchange. Every ambiguous verdict
/// biases toward MERGE (fall back to the 400 ms silence path), so an error is late-but-correct, never
/// a wrong split. `speakerAware == false` runs the plain VAD path byte-for-byte.
final class VADSegmenter {
    static let sampleRate = 16_000
    static let frameMs = 30
    static let frameSamples = sampleRate * frameMs / 1000   // 480

    private let silenceFrames: Int
    private let minSpeechFrames: Int
    private let maxSegmentSamples: Int
    private let preRollFrames: Int
    private let energyThreshold: Float
    private let noiseMargin: Float
    private var noiseFloor: Float = 0
    /// Whether `noiseFloor` has been seeded from a real frame yet (distinguishes the initial 0 from a
    /// floor that has legitimately decayed to ~0 on a truly-silent channel, so it isn't re-seeded from a
    /// following quiet signal).
    private var floorSeeded = false
    /// A steady level above this is a real signal, not room ambient — so a loud frame is clamped to it
    /// before it can train the floor. Keeps the auto floor in the ambient range (a continuously LOUD
    /// signal still reads as speech), while letting a live mic's quiet ambient be learned + gated.
    private static let maxNoiseFloor: Float = 0.08
    private var squelchAuto: Bool
    private var manualGate: Float

    // Streaming config (frames).
    private let pttBreakFrames: Int
    private let onsetConfirmFrames: Int
    private let reConfirmFrames: Int
    private var minTurnSpeechFrames: Int { minSpeechFrames }

    /// Streaming speaker-change segmentation on/off. A `var` so the Settings diarization toggle can
    /// flip it at runtime (see `setSpeakerAware`). When false, `feed()` is the plain VAD verbatim.
    private var speakerAware: Bool
    /// Shared session speaker clustering (fingerprint + centroids), also used by the post-hoc Diarizer.
    private let speaker: SpeakerModel

    /// The RMS gate at the top of the 0…1 manual-squelch slider range.
    static let manualGateMaxRMS: Float = 0.10
    private static func manualRMS(_ level: Float) -> Float { max(0, min(1, level)) * manualGateMaxRMS }

    // Accumulation state (shared by both paths).
    private var pending: [Float] = []
    private var segmentFrames: [[Float]] = []
    private var preRoll: [[Float]] = []
    private var speechActive = false
    private var silenceCount = 0
    private var speechFrames = 0
    private var segmentStartS = 0.0
    private var streamCursorS = 0.0

    // Streaming-only state.
    private enum Phase { case idle, speaking, tentativeGap, confirmingOnset }
    private var phase: Phase = .idle
    private var gapSilenceCount = 0
    private var turnSnapshotFrames: [[Float]] = []
    private var turnFp: [Float]?
    private var turnStartSnapshot = 0.0
    private var turnEndSnapshot = 0.0
    private var turnSpeechSnapshot = 0
    private var onsetFrames: [[Float]] = []
    private var onsetSpeechCount = 0
    private var onsetStartS = 0.0
    private var onsetPreRoll: [[Float]] = []
    private var changeVerdictStreak = 0

    // Runaway-noise detector (M1 remediation). Consecutive 8 s max-cap emissions with ZERO
    // intervening sub-gate frames are the signature of a channel whose RMS sits above the
    // auto-gate ceiling (maxNoiseFloor × noiseMargin ≈ 0.144): every frame reads as speech and
    // the cap re-opens forever. Real speech always breaks on a PTT gap. Detection only SURFACES
    // (one-shot latch the pipeline polls) — it never gates audio: silently discarding what might
    // be a long readback storm would be worse than transcribing noise.
    private var consecutiveCapEmits = 0
    private static let runawayCapEmits = 3          // ~24 s of gapless "speech" before we say anything
    private var runawayLatched = false
    private var runawaySurfaced = false             // one nag per squelch configuration

    private let now: () -> Double

    init(config: VADConfig = VADConfig(),
         speakerAware: Bool = false,
         speaker: SpeakerModel = SpeakerModel(),
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        silenceFrames = max(1, config.silenceDurationMs / Self.frameMs)
        minSpeechFrames = max(1, config.minSpeechMs / Self.frameMs)
        maxSegmentSamples = Int(config.maxSegmentS * Double(Self.sampleRate))
        preRollFrames = max(0, config.preRollMs / Self.frameMs)
        energyThreshold = Float(0.012 - Double(config.aggressiveness) * 0.002)
        noiseMargin = max(1.0, config.noiseMargin)
        squelchAuto = config.squelchAuto
        manualGate = config.calibratedGateRMS ?? Self.manualRMS(config.squelchLevel)
        pttBreakFrames = max(1, config.pttBreakMs / Self.frameMs)
        onsetConfirmFrames = max(1, (config.onsetConfirmMs + Self.frameMs - 1) / Self.frameMs)
        reConfirmFrames = max(1, (config.reConfirmMs + Self.frameMs - 1) / Self.frameMs)
        self.speakerAware = speakerAware
        self.speaker = speaker
        self.now = now
    }

    /// Flip streaming speaker-change segmentation at runtime (Settings diarization toggle) — reachable
    /// mid-transmission. Reconcile BOTH directions so the shared accumulators stay coherent and no
    /// audio is dropped across the switch.
    func setSpeakerAware(_ on: Bool) {
        if on {
            // ON: align the phase with the current speech state so an in-flight turn continues cleanly,
            // and clear any streaming-only residue.
            phase = speechActive ? .speaking : .idle
            gapSilenceCount = 0; changeVerdictStreak = 0
            turnFp = nil; turnSnapshotFrames = []; onsetFrames = []; onsetSpeechCount = 0
        } else if speakerAware {
            // OFF mid-turn: fold any parked next-speaker onset back into the open segment so the plain
            // VAD finishes the whole thing as ONE merged transmission — nothing is lost and nothing
            // wrong-splits (the user just asked to STOP separating speakers). segmentFrames already
            // holds the prior turn + PTT gap; appending the onset makes one continuous segment that the
            // 400 ms / 8 s fallback finalizes. Reset the streaming buffers + silence so the plain path
            // resumes from a coherent state.
            if !onsetFrames.isEmpty {
                segmentFrames.append(contentsOf: onsetFrames)
                speechFrames += onsetSpeechCount
            }
            silenceCount = 0; gapSilenceCount = 0; changeVerdictStreak = 0
            turnFp = nil; turnSnapshotFrames = []; onsetFrames = []; onsetSpeechCount = 0
            phase = .idle
        }
        speakerAware = on
    }

    /// Change the squelch at runtime (Settings). Auto re-learns the noise floor; manual uses a
    /// fixed normalized 0…1 threshold. Takes effect on the next frame.
    func setSquelch(auto: Bool, level: Float, calibratedGateRMS: Float? = nil) {
        squelchAuto = auto
        manualGate = calibratedGateRMS ?? Self.manualRMS(level)   // absolute calibrated gate wins over the slider
        if auto { noiseFloor = 0; floorSeeded = false }   // re-seed from the live channel on the next frame
        // The user acted on the squelch — reset the runaway detector AND re-arm its one-shot, so
        // if the new setting still can't gate the channel they get told once more.
        consecutiveCapEmits = 0
        runawayLatched = false
        runawaySurfaced = false
    }

    /// Poll-and-clear the runaway-noise latch (LivePipeline calls this after each feed()). True at
    /// most ONCE per squelch configuration — re-armed only by `setSquelch`.
    func consumeRunawayNoise() -> Bool {
        let hit = runawayLatched
        runawayLatched = false
        return hit
    }

    /// Count a max-cap segment emission toward the runaway signature; latch at the bound.
    private func noteCapEmit() {
        consecutiveCapEmits += 1
        assert(consecutiveCapEmits <= Self.runawayCapEmits, "cap-emit counter must reset at its bound")
        if consecutiveCapEmits >= Self.runawayCapEmits {
            consecutiveCapEmits = 0
            if !runawaySurfaced { runawaySurfaced = true; runawayLatched = true }
        }
    }

    private func currentGate() -> Float {
        squelchAuto ? max(energyThreshold, noiseFloor * noiseMargin)
                    : max(energyThreshold * 0.25, manualGate)
    }

    /// Energy (RMS) voice-activity test with an adaptive noise floor. Port of the energy branch of
    /// `_is_speech_frame`, hardened against noisy channels — and, critically, against a CONTINUOUS one.
    private func isSpeechFrame(_ frame: [Float]) -> Bool {
        guard !frame.isEmpty else { return false }
        var sumSquares: Float = 0
        for s in frame { sumSquares += s * s }
        let rms = (sumSquares / Float(frame.count)).squareRoot()
        // Decide against the floor as it stands BEFORE this frame's update, so a stream that OPENS on a
        // quiet transmission (no leading silence) still passes at the absolute threshold — the seed
        // then calibrates from the next frame on — rather than being gated by a floor derived from itself.
        let speech = rms >= currentGate()
        if squelchAuto { updateNoiseFloor(rms, isSpeech: speech) }
        return speech
    }

    /// Track the channel noise floor for auto squelch. The OLD code only learned the floor from frames
    /// BELOW the gate — fine for a bursty radio (its silence between transmissions trains the floor), but
    /// on a CONTINUOUS feed (a live iPad mic, whose ambient never drops to true silence and sits above
    /// the absolute 0.008 gate) NO frame was ever sub-gate, so the floor never learned, the gate stayed
    /// pinned at 0.008, every frame read as speech, and the segmenter looped forever on the max-segment
    /// cap transcribing room noise (the "stuck transcribing, no output" mic bug).
    ///
    /// Now it learns from every frame: seed from the first frame (so a hot continuous mic calibrates at
    /// once), fast-attack DOWN to any quieter level (so it tracks the true quiet floor and, on a radio,
    /// snaps back to silence between transmissions), and a slow creep UP toward a rising ambient — but
    /// the creep-up runs ONLY on frames the gate just classified as NON-speech. That last part is
    /// essential: a real transmission (even a sustained quiet one) must never train the floor toward
    /// itself, or its own energy would raise the gate above it and gate it off mid-transmission. A loud
    /// frame is also CLAMPED to `maxNoiseFloor` before it can train the floor, so a genuinely loud steady
    /// signal can never be learned as "ambient". `currentGate()` (= max(energyThreshold, floor*margin))
    /// is unchanged.
    private func updateNoiseFloor(_ rms: Float, isSpeech: Bool) {
        let sample = Swift.min(rms, Self.maxNoiseFloor)
        if !floorSeeded {
            noiseFloor = sample; floorSeeded = true      // seed from the first frame so a hot channel calibrates at once
        } else if sample < noiseFloor {
            noiseFloor = sample                          // fast-attack down to a quieter floor (incl. true silence → ~0)
        } else if !isSpeech {
            noiseFloor = noiseFloor * 0.985 + sample * 0.015   // creep up toward a rising ambient — NON-speech frames only
        }
    }

    /// Emit the buffered segment if it has enough speech, else drop it. Port of `_finalize`. Used by
    /// the PLAIN path.
    private func finalize(endS: Double) -> SpeechSegment? {
        if speechFrames < minSpeechFrames || segmentFrames.isEmpty {
            segmentFrames = []
            speechFrames = 0
            return nil
        }
        let audio = segmentFrames.flatMap { $0 }
        let seg = SpeechSegment(audio: audio, streamStartS: segmentStartS,
                                streamEndS: endS, finalizedWallTime: now())
        segmentFrames = []
        speechFrames = 0
        return seg
    }

    /// Feed PCM and return any completed speech segments. Port of `feed`, plus the streaming path.
    @discardableResult
    func feed(_ chunk: [Float]) -> [SpeechSegment] {
        pending.append(contentsOf: chunk)
        var completed: [SpeechSegment] = []

        while pending.count >= Self.frameSamples {
            let frame = Array(pending[0..<Self.frameSamples])
            pending.removeFirst(Self.frameSamples)
            let frameStartS = streamCursorS
            streamCursorS += Double(Self.frameSamples) / Double(Self.sampleRate)
            let sp = isSpeechFrame(frame)                    // side effect: updates the noise floor
            if !sp { consecutiveCapEmits = 0 }               // ONE sub-gate frame proves the gate works

            if speakerAware {
                streamingFrame(frame, sp: sp, frameStartS: frameStartS, into: &completed)
                continue
            }

            // ----- PLAIN VAD PATH (unchanged) -----
            if sp {
                if !speechActive {
                    speechActive = true
                    segmentStartS = max(0.0, frameStartS - Double(preRollFrames) * Double(Self.frameMs) / 1000.0)
                    segmentFrames = preRoll
                }
                segmentFrames.append(frame)
                speechFrames += 1
                silenceCount = 0

                if segmentFrames.reduce(0, { $0 + $1.count }) >= maxSegmentSamples {
                    let endS = streamCursorS
                    if let seg = finalize(endS: endS) { completed.append(seg) }
                    noteCapEmit()                            // runaway signature: gapless cap emits
                    speechActive = true
                    segmentStartS = endS
                }
            } else {
                preRoll.append(frame)
                if preRoll.count > preRollFrames {
                    preRoll.removeFirst(preRoll.count - preRollFrames)
                }
                if speechActive {
                    segmentFrames.append(frame)
                    silenceCount += 1
                    if silenceCount >= silenceFrames {
                        let endS = streamCursorS
                        if let seg = finalize(endS: endS) { completed.append(seg) }
                        speechActive = false
                        silenceCount = 0
                    }
                }
            }
        }
        return completed
    }

    /// Drain a parked turn on stream-end / stop() so it's never lost (the streaming path defers the
    /// last turn until the next speaker, which never comes at end-of-stream). Also flushes any open
    /// PLAIN segment (a strict improvement that can't change mid-stream behavior).
    @discardableResult
    func flush() -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        if speakerAware {
            if (phase == .tentativeGap || phase == .confirmingOnset), !turnSnapshotFrames.isEmpty {
                emitStreaming(turnSnapshotFrames, startS: turnStartSnapshot, endS: turnEndSnapshot,
                              fp: turnFp, speechCount: turnSpeechSnapshot, into: &out)
            } else if speechActive, speechFrames >= minTurnSpeechFrames {
                emitStreaming(segmentFrames, startS: segmentStartS, endS: streamCursorS,
                              fp: nil, speechCount: speechFrames, into: &out)
            }
        } else if let seg = finalize(endS: streamCursorS) {
            out.append(seg)
        }
        resetToIdle()
        return out
    }

    // MARK: streaming phase machine

    private func streamingFrame(_ frame: [Float], sp: Bool, frameStartS: Double, into completed: inout [SpeechSegment]) {
        switch phase {
        case .idle:
            if sp {
                speechActive = true
                segmentStartS = max(0.0, frameStartS - Double(preRollFrames) * Double(Self.frameMs) / 1000.0)
                segmentFrames = preRoll
                segmentFrames.append(frame)
                speechFrames = 1
                silenceCount = 0
                gapSilenceCount = 0
                phase = .speaking
            } else {
                preRoll.append(frame)
                if preRoll.count > preRollFrames { preRoll.removeFirst(preRoll.count - preRollFrames) }
            }

        case .speaking:
            if sp {
                segmentFrames.append(frame); speechFrames += 1; silenceCount = 0; gapSilenceCount = 0
                if sampleCount(segmentFrames) >= maxSegmentSamples {   // 8s cap
                    emitStreaming(segmentFrames, startS: segmentStartS, endS: streamCursorS,
                                  fp: nil, speechCount: speechFrames, into: &completed)
                    noteCapEmit()                                      // runaway signature (see detector)
                    // CAP RESET — clear any stale fingerprint so the next boundary decision is fresh.
                    segmentFrames = []; speechFrames = 0; silenceCount = 0; gapSilenceCount = 0
                    speechActive = true; segmentStartS = streamCursorS
                    turnFp = nil; turnSnapshotFrames = []; changeVerdictStreak = 0
                    phase = .speaking
                }
            } else {
                segmentFrames.append(frame); silenceCount += 1; gapSilenceCount += 1
                if silenceCount >= silenceFrames {                     // long-silence fallback
                    emitStreaming(segmentFrames, startS: segmentStartS, endS: streamCursorS,
                                  fp: nil, speechCount: speechFrames, into: &completed)
                    resetToIdle()
                } else if gapSilenceCount == pttBreakFrames && speechFrames >= minTurnSpeechFrames {
                    // ARM a tentative boundary: snapshot the turn minus the trailing PTT-break silence.
                    let trimmed = Array(segmentFrames.dropLast(min(pttBreakFrames, segmentFrames.count)))
                    turnSnapshotFrames = trimmed
                    turnStartSnapshot = segmentStartS
                    turnEndSnapshot = streamCursorS - Double(pttBreakFrames) * Double(Self.frameMs) / 1000.0
                    turnSpeechSnapshot = speechFrames
                    turnFp = speaker.fingerprint(trimmed.flatMap { $0 })
                    phase = .tentativeGap
                }
            }

        case .tentativeGap:
            if !sp {
                silenceCount += 1; gapSilenceCount += 1; segmentFrames.append(frame)
                if silenceCount >= silenceFrames {   // the gap was a real end-of-turn, not a turn change
                    emitStreaming(turnSnapshotFrames, startS: turnStartSnapshot, endS: turnEndSnapshot,
                                  fp: turnFp, speechCount: turnSpeechSnapshot, into: &completed)
                    resetToIdle()
                }
            } else {
                // A talker keyed up inside the PTT window — start confirming who.
                phase = .confirmingOnset
                onsetFrames = [frame]
                onsetSpeechCount = 1
                onsetStartS = frameStartS
                // The new turn's lead-in = the tail of the PTT gap right before it (NOT the stale
                // pre-roll from before the previous turn), so its onset isn't clipped. Clamp to the
                // gap length so the suffix can never reach past the gap into the prior turn's last
                // SPEECH frame (which would overlap/duplicate turn N into turn N+1).
                onsetPreRoll = Array(segmentFrames.suffix(min(preRollFrames, gapSilenceCount)))
                // The PTT-gap silence is intentional and must NOT count against the onset's own
                // end-of-turn budget — reset so the "onset died" fallback measures silence WITHIN the
                // onset, not the gap that preceded it.
                silenceCount = 0
                changeVerdictStreak = 0
            }

        case .confirmingOnset:
            if sp {
                onsetFrames.append(frame); onsetSpeechCount += 1; silenceCount = 0
                // Never let a merged (turn + onset) run exceed the 8s cap.
                if sampleCount(turnSnapshotFrames) + sampleCount(onsetFrames) >= maxSegmentSamples {
                    emitStreaming(turnSnapshotFrames, startS: turnStartSnapshot, endS: turnEndSnapshot,
                                  fp: turnFp, speechCount: turnSpeechSnapshot, into: &completed)
                    reseedFromOnset(); return
                }
                let firstEval = onsetSpeechCount == onsetConfirmFrames
                let secondEval = changeVerdictStreak >= 1 && onsetSpeechCount == onsetConfirmFrames + reConfirmFrames
                if firstEval || secondEval {
                    let onsetFp = speaker.fingerprint(onsetFrames.flatMap { $0 })
                    let turnFingerprint = turnFp ?? onsetFp
                    let dSame = speaker.dist(turnFingerprint, onsetFp)       // onset vs the prior turn (full)
                    let dTimbre = speaker.timbreDist(turnFingerprint, onsetFp)   // …level-independent part
                    let (sNew, dNew) = speaker.nearestSpeaker(onsetFp)       // onset's nearest KNOWN speaker
                    let (sCur, _) = speaker.nearestSpeaker(turnFingerprint)  // prior turn's nearest KNOWN speaker
                    // A genuine turn change moves TIMBRE (pitch/brightness), not loudness alone: the same
                    // controller keying up louder differs from itself ONLY in the `level` dim, and a ~15 dB
                    // swing there is already worth a full newSpeakerDist — so the overall distance can't be
                    // trusted by itself. A change therefore requires the two turns to be far apart overall
                    // AND for that separation to be carried by timbre (a loudness-only jump has dTimbre≈0 →
                    // MERGE, the false-split guard). `sameKnownSpeaker` additionally short-circuits an onset
                    // that lands back on the prior turn's own cluster. Every ambiguous verdict biases MERGE.
                    let sameKnownSpeaker = sNew >= 0 && sNew == sCur && dNew < speaker.newSpeakerDist
                    let isChange = !sameKnownSpeaker
                        && dSame >= speaker.newSpeakerDist
                        && dTimbre >= speaker.turnChangeTimbreMin
                    if isChange {
                        changeVerdictStreak += 1
                        if changeVerdictStreak >= 2 {   // survived two evals ~reConfirm apart
                            emitStreaming(turnSnapshotFrames, startS: turnStartSnapshot, endS: turnEndSnapshot,
                                          fp: turnFp, speechCount: turnSpeechSnapshot, into: &completed)
                            reseedFromOnset()
                        }
                        // else: keep buffering for the 2nd eval
                    } else {
                        // MERGE-BACK (false-split guard): same speaker / ambiguous → one continuous turn.
                        segmentFrames.append(contentsOf: onsetFrames)
                        speechFrames += onsetSpeechCount
                        silenceCount = 0; gapSilenceCount = 0
                        turnFp = nil; turnSnapshotFrames = []; changeVerdictStreak = 0
                        onsetFrames = []; onsetSpeechCount = 0
                        phase = .speaking
                    }
                }
            } else {
                // The onset died before confirming (a blip in the gap). Buffer the silence in onsetFrames
                // ONLY — NOT segmentFrames too — so the later merge-back / OFF-fold (which append onsetFrames
                // wholesale) can't double-count and reorder it. segmentFrames' copy was never consumed on
                // this path anyway: the fallback emits the turn snapshot, then resetToIdle clears it.
                onsetFrames.append(frame); silenceCount += 1; gapSilenceCount += 1
                if silenceCount >= silenceFrames {
                    emitStreaming(turnSnapshotFrames, startS: turnStartSnapshot, endS: turnEndSnapshot,
                                  fp: turnFp, speechCount: turnSpeechSnapshot, into: &completed)
                    resetToIdle()
                }
            }
        }
    }

    /// Emit a streaming turn: apply the min-speech drop rule, fingerprint (or reuse), tag a best-guess
    /// speaker id, and append the segment. The tag is a NON-mutating peek (`nearestSpeaker`), NOT
    /// `assign` — the post-hoc Diarizer in `LivePipeline.emit` is the single centroid mutator + labeling
    /// authority (it re-splits and re-labels this audio), so assigning here too would double-update the
    /// shared EMA. The tag is a hint (non-nil on the ON path); the id the user sees is the diarizer's.
    private func emitStreaming(_ frames: [[Float]], startS: Double, endS: Double, fp: [Float]?,
                               speechCount: Int, into completed: inout [SpeechSegment]) {
        guard speechCount >= minTurnSpeechFrames, !frames.isEmpty else { return }
        let audio = frames.flatMap { $0 }
        guard !audio.isEmpty else { return }
        let f = fp ?? speaker.fingerprint(audio)
        let spk = max(0, speaker.nearestSpeaker(f).id)   // peek only — first turn (no centroids) → 0
        completed.append(SpeechSegment(audio: audio, streamStartS: startS, streamEndS: endS,
                                       finalizedWallTime: now(), speaker: spk))
    }

    /// After a confirmed speaker change (or cap), re-seed the resumed onset as the new turn N+1.
    private func reseedFromOnset() {
        segmentFrames = onsetPreRoll + onsetFrames
        segmentStartS = max(0.0, onsetStartS - Double(onsetPreRoll.count) * Double(Self.frameMs) / 1000.0)
        speechFrames = onsetSpeechCount
        silenceCount = 0; gapSilenceCount = 0
        turnFp = nil; turnSnapshotFrames = []; changeVerdictStreak = 0
        onsetFrames = []; onsetSpeechCount = 0; onsetPreRoll = []
        speechActive = true
        phase = .speaking
    }

    private func resetToIdle() {
        segmentFrames = []; speechFrames = 0; silenceCount = 0; gapSilenceCount = 0
        speechActive = false; phase = .idle
        turnFp = nil; turnSnapshotFrames = []; changeVerdictStreak = 0
        onsetFrames = []; onsetSpeechCount = 0
        consecutiveCapEmits = 0   // an idle reset means the channel went quiet — not a runaway
    }

    private func sampleCount(_ frames: [[Float]]) -> Int { frames.reduce(0) { $0 + $1.count } }
}
