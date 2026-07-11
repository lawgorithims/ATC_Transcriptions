import Foundation

/// Streaming fusion of the three per-line signals (content role, acoustic voice-cluster id, callsign)
/// into one `speakerLabel` per transmission — the live runtime port of the offline Rung-2 pass
/// (`python-legacy/dataset/atc_speaker_cluster.py`). Owned by `TranscriptionSession`, only ever
/// touched on the main actor (one call per appended record), so it needs no locking.
///
/// The pure ATC/callsign mapping is `SpeakerFusion` (faithful, parity-tested). This type adds the two
/// runtime-only concerns the offline batch pass doesn't have: (1) incremental affinity that back-fills
/// a line once its cluster matures, and (2) a CONSERVATIVE fill guard — because the live acoustic
/// fingerprint is weaker than the offline ECAPA, we only fill an unknown line toward the recurring
/// CONTROLLER voice, and only from a mature, pure, tightly-matched cluster; otherwise it stays UNKNOWN.
///
/// CODING STANDARD (NASA/JPL "Power of Ten"): per-speaker state is a FIXED-SIZE array indexed by the
/// bounded speaker id (no dynamic dictionary); every loop has a fixed bound; every function validates
/// its inputs and asserts its invariants; no recursion, no function pointers.
final class SpeakerLabeler {

    /// Whether to fill an unknown line from its acoustic voice-cluster affinity. DEFAULT OFF: a
    /// large-scale study over the real corpus (`ATCKitProbe/SpeakerStudy`) showed the on-device
    /// mean-MFCC fingerprint CANNOT reliably separate a controller from pilots on the SAME feed
    /// (equal-error ~53% — same-channel audio shares timbre). So acoustic fill is not trustworthy
    /// until a stronger embedder lands (Stage 5b, ECAPA→Core ML). The reliable content-role fusion
    /// runs regardless; with fill off, an unknown-content line simply stays UNKNOWN (honest).
    var acousticFillEnabled = false

    // Conservative fill-guard thresholds (used only when `acousticFillEnabled`; see the shadow log).
    static let minConfidentMembers = 4      // a cluster needs ≥ this many confident roles before it fills
    static let minControllerPurity = 0.75   // ≥ this share of confident members must be controller
    static let maxFillDistance: Float = 0.03 // fill only from a tight (cosine) voice match

    /// Speaker ids come from `SpeakerModel`, which caps at 6. The +2 is headroom so an out-of-range id
    /// is contained rather than crashing (it is then ignored by the guard).
    private static let maxSpeakers = 8
    private static let maxRecordsScan = 512  // bound for the adopt/rebuild pass (records are capped at 500)

    // Fixed-size per-speaker state (index = speaker id).
    private var controllerCount = [Int](repeating: 0, count: SpeakerLabeler.maxSpeakers)
    private var pilotCount = [Int](repeating: 0, count: SpeakerLabeler.maxSpeakers)
    private var firstConfident = [TurnRole](repeating: .unknown, count: SpeakerLabeler.maxSpeakers)
    private var lastFill = [TurnRole](repeating: .unknown, count: SpeakerLabeler.maxSpeakers)

    func reset() {
        for i in 0..<SpeakerLabeler.maxSpeakers {
            controllerCount[i] = 0; pilotCount[i] = 0
            firstConfident[i] = .unknown; lastFill[i] = .unknown
        }
    }

    /// Rebuild the tallies from an adopted transcript (e.g. a model-swap resume) so later relabeling
    /// stays consistent. Bounded by `maxRecordsScan`.
    func rebuild(from records: [TranscriptRecord]) {
        reset()
        let n = min(records.count, SpeakerLabeler.maxRecordsScan)
        assert(n <= SpeakerLabeler.maxRecordsScan)
        for i in 0..<n { bump(records[i]) }
        for spk in 0..<SpeakerLabeler.maxSpeakers { lastFill[spk] = fillAffinity(for: spk) }
    }

    /// Fuse `record` in place. Returns the speaker id whose effective fill-affinity just changed (so the
    /// caller can retroactively re-fuse that speaker's still-unknown lines), or nil.
    func ingest(_ record: inout TranscriptRecord) -> Int? {
        guard let spk = record.speaker, valid(spk) else {   // diarization off / bad id → content-only
            apply(&record)
            return nil
        }
        bump(record)
        apply(&record)
        let newFill = fillAffinity(for: spk)
        let changed = lastFill[spk] != newFill
        lastFill[spk] = newFill
        return changed ? spk : nil
    }

    /// Re-fuse a single already-appended record in place (the retroactive relabel).
    func refuse(_ record: inout TranscriptRecord) { apply(&record) }

    // MARK: - internals

    private func valid(_ speaker: Int) -> Bool { speaker >= 0 && speaker < SpeakerLabeler.maxSpeakers }

    private func bump(_ r: TranscriptRecord) {
        guard let spk = r.speaker, valid(spk) else { return }
        assert(spk >= 0 && spk < SpeakerLabeler.maxSpeakers)
        if r.role == .controller {
            controllerCount[spk] += 1
            if firstConfident[spk] == .unknown { firstConfident[spk] = .controller }
        } else if r.role == .pilot {
            pilotCount[spk] += 1
            if firstConfident[spk] == .unknown { firstConfident[spk] = .pilot }
        }
    }

    /// Guard-approved fill affinity: `.controller` only when the cluster is mature, controller-dominant,
    /// and pure enough; otherwise `.unknown` (never fill toward pilot — one-shot pilots don't form
    /// trustworthy clusters on the weak live fingerprint).
    private func fillAffinity(for speaker: Int) -> TurnRole {
        guard valid(speaker) else { return .unknown }
        let c = controllerCount[speaker], p = pilotCount[speaker]
        assert(c >= 0 && p >= 0)
        let confident = c + p
        guard confident >= SpeakerLabeler.minConfidentMembers, c > p else { return .unknown }
        let purity = Double(c) / Double(confident)
        return purity >= SpeakerLabeler.minControllerPurity ? .controller : .unknown
    }

    /// Apply the fusion mapping to one record: a confident own role always wins; an unknown line is
    /// filled from the guard-approved cluster affinity, but only if THIS line's voice matched tightly.
    private func apply(_ record: inout TranscriptRecord) {
        var affinity: TurnRole = .unknown
        let ownConfident = record.role == .controller || record.role == .pilot
        if acousticFillEnabled, !ownConfident, let spk = record.speaker, valid(spk),
           fillAffinity(for: spk) == .controller,
           let d = record.speakerDistance, d < SpeakerLabeler.maxFillDistance {
            affinity = .controller
        }
        let fused = SpeakerFusion.fuse(ownRole: record.role, affinity: affinity, callsign: record.callsign)
        assert(ownConfident ? fused.from == .content : fused.from != .content)
        record.roleFused = fused.roleFused
        record.speakerLabel = fused.label
        record.fusedFrom = fused.from
    }
}
