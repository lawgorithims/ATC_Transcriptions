import Foundation

/// The fused, per-line speaker label shown in the transcript — the runtime equivalent of the offline
/// pipeline's `speaker_label` column (`python-legacy/dataset/atc_speaker_cluster.py`). One honest
/// label per transmission: the controller ("ATC"), the speaking aircraft's callsign, a generic
/// "Pilot" when the role is known but no callsign was recovered, or unknown.
enum SpeakerLabel: Sendable, Equatable {
    case atc
    case callsign(String)
    case pilot
    case unknown

    /// Offline-parity string form ("ATC" / <callsign> / "PILOT" / "UNKNOWN"). Matches the Python
    /// `speaker_label` values so `SpeakerFusionParityTests` can compare directly.
    var fixtureString: String {
        switch self {
        case .atc: return "ATC"
        case .callsign(let cs): return cs
        case .pilot: return "PILOT"
        case .unknown: return "UNKNOWN"
        }
    }
}

/// Where a line's fused role came from — mirror of the offline `fused_from` column. `content` = the
/// line's own confident text role; `acoustic` = filled from its voice cluster's affinity; `none` =
/// nothing to fill from (stayed unknown).
enum FusedProvenance: String, Sendable, Equatable { case content, acoustic, none }

/// Pure fusion mapping — a line-for-line port of the offline Rung-2 block
/// (`atc_speaker_cluster.py:170–203`). Stateless, so it is trivially parity-testable against the
/// Python reference (see `SpeakerFusionParityTests`). The *policy* of WHEN to trust the acoustic
/// affinity (the conservative fill guard) lives in `SpeakerLabeler`, not here — this mapping is the
/// faithful 1:1 core: given a role and an (already-approved) cluster affinity, it produces the label.
enum SpeakerFusion {

    /// A cluster's role affinity = the majority of its members' CONFIDENT content roles (unknown
    /// ignored). A count tie resolves to the FIRST confident role seen — matching Python's
    /// `Counter.most_common(1)`, which returns the first-inserted key among equal counts; since
    /// members arrive in time order, that is the first confident role in the session.
    static func affinity(controller: Int, pilot: Int, firstConfident: TurnRole?) -> TurnRole {
        assert(controller >= 0, "controller tally must be non-negative")
        assert(pilot >= 0, "pilot tally must be non-negative")
        if controller <= 0 && pilot <= 0 { return .unknown }
        if controller > pilot { return .controller }
        if pilot > controller { return .pilot }
        return firstConfident ?? .unknown
    }

    /// Fuse one line: keep a confident own role; otherwise fill from the cluster `affinity` (which
    /// the caller has already gated). A confident content role is NEVER overridden. Maps the fused
    /// role to the display label + provenance exactly as offline.
    static func fuse(ownRole: TurnRole, affinity: TurnRole, callsign: String?)
        -> (roleFused: TurnRole, label: SpeakerLabel, from: FusedProvenance) {
        let confidentOwn = (ownRole == .controller || ownRole == .pilot)
        let roleFused = confidentOwn ? ownRole : affinity
        let label: SpeakerLabel
        switch roleFused {
        case .controller: label = .atc
        case .pilot:      label = callsign.map(SpeakerLabel.callsign) ?? .pilot
        case .unknown:    label = .unknown
        }
        let from: FusedProvenance = confidentOwn ? .content
            : (roleFused != .unknown ? .acoustic : .none)
        // Invariants: a confident own role is never overridden, and provenance agrees with the fill.
        assert(!confidentOwn || roleFused == ownRole)
        assert(from != .content || confidentOwn)
        return (roleFused, label, from)
    }
}
