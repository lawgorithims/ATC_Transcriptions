import Foundation

/// WHAT KIND of bad the GPS has gone, layered on top of `GPSIntegrityMonitor`'s "how bad".
///
/// The integrity monitor answers "can I trust this position?"; it deliberately stops there, because the
/// only things it can see are the receiver's own uncertainty estimates and the disagreement between
/// position and velocity. That is enough to SUPPRESS ownship, but it is not enough to tell the pilot
/// what to do, and the two failures demand opposite actions in the cockpit:
///
/// * JAMMING denies the signal. The receiver knows it has lost the solution — accuracy blows out, fixes
///   stop arriving — so the failure is LOUD and self-announcing. The action is "expect to lose GPS,
///   navigate by navaids, tell ATC" and, crucially, the position you still have is honest while it lasts.
/// * SPOOFING fakes the signal. The receiver believes a lie and reports it CONFIDENTLY — accuracy often
///   looks perfect, which is exactly why an accuracy-threshold check sails straight past it. The action
///   is "do not navigate by GPS at all", which is a much bigger hammer and must not be swung at an
///   ordinary accuracy dip.
///
/// The ordering is severity, and spoofing sits above jamming on purpose: a spoofer commonly jams first
/// to break the receiver's lock before capturing it, so when both signatures are present the spoofing
/// verdict is the one that survives. Being told to stop trusting GPS when it was only being denied is a
/// recoverable inconvenience; flying a confident false position is not.
enum GPSThreat: Int, Comparable, Sendable, CaseIterable {
    case none = 0       // nothing to report, or no fix yet this session
    case degraded = 1   // the fix is poor and the geometry (or nothing we can see) explains why
    case jamming = 2    // the signal is being DENIED: bad measurement under good predicted geometry
    case spoofing = 3   // the signal is being FAKED: the position contradicts itself

    static func < (a: GPSThreat, b: GPSThreat) -> Bool { a.rawValue < b.rawValue }

    /// Banner headline. Deliberately hedged for the interference cases — an app cannot PROVE jamming
    /// from a phone's location API, and a verdict stated as fact that turns out to be an urban canyon
    /// teaches the pilot to ignore the banner.
    var label: String {
        switch self {
        case .none:     return "GPS nominal"
        case .degraded: return "GPS degraded"
        case .jamming:  return "GPS interference suspected"
        case .spoofing: return "GPS spoofing suspected"
        }
    }

    /// True when the failure is being caused from OUTSIDE the aircraft rather than by geometry or
    /// terrain — the cases worth an ATC report and a note in the post-flight log.
    var isInterference: Bool { self >= .jamming }

    /// True when the pilot should be verifying position against something that is not GPS.
    var requiresCrossCheck: Bool { self >= .degraded }
}

/// How much the classifier believes its own verdict. This is confidence in the ATTRIBUTION, not in the
/// severity: `degraded` with `geometryUnknown` is low confidence precisely because we had no almanac to
/// rule interference in or out, while `degraded` under a PDOP of 14 is high confidence because the
/// geometry positively accounts for the error.
enum GPSThreatConfidence: Int, Comparable, Sendable {
    case low = 0, medium = 1, high = 2

    static func < (a: GPSThreatConfidence, b: GPSThreatConfidence) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .low: return "low"; case .medium: return "medium"; case .high: return "high"
        }
    }
}

/// How the predicted sky compares against what the receiver is actually delivering. Computed from the
/// almanac (`GPSAlmanac` → `PredictedDOP`, satellites above the mask), never from the fix itself — that is the
/// whole point: it is an INDEPENDENT prediction, so a disagreement between it and the measurement is
/// evidence about the signal rather than about the geometry.
enum GPSGeometryVerdict: String, Sendable, CaseIterable {
    case unknown   // no almanac loaded, or ownship is outside its validity window — no basis to attribute
    case poor      // high PDOP or too few satellites: bad geometry on its own explains a bad fix
    case fair      // neither clearly good nor clearly poor — not a strong enough basis to accuse anyone
    case good      // the sky is fine, so geometry cannot be what is wrong

    var label: String {
        switch self {
        case .unknown: return "geometry unknown"; case .poor: return "geometry poor"
        case .fair:    return "geometry fair";    case .good: return "geometry good"
        }
    }
}

/// Why the classifier reached its verdict. Every case names a piece of EVIDENCE, including the cases
/// that argue AGAINST interference — an assessment that says "degraded" is much more useful when it
/// also says whether that was because the geometry explained it or because we were flying blind.
enum GPSThreatReason: String, Sendable, CaseIterable {
    // Spoofing evidence — the fix contradicts itself.
    case velocityDisagreesWithPosition  // position moved further than the receiver's own velocity allows
    case impossibleKinematics           // implied speed or acceleration outside any airframe's envelope
    case softwareGeneratedFix           // the OS flags the location as simulated — a hard, local tell
    case confidentButInconsistent       // tight accuracy WHILE self-inconsistent: the spoofer's signature
    case selfInconsistentFix            // integrity says suspect without an attributable tell (defensive)

    // Jamming evidence — the measurement is worse than the sky can account for.
    case accuracyUnexplainedByGeometry  // error far past HDOP × UERE with a good sky overhead
    case fixLostUnexplainedByGeometry   // the solution went stale while satellites were plentiful

    // Non-attribution — why we are NOT crying interference.
    case geometryExplainsError          // high PDOP / few satellites genuinely account for the error
    case geometryMarginal               // the sky is only fair; ordinary error cannot be ruled out
    case geometryUnknown                // no almanac — jamming and ordinary degradation are indistinguishable

    /// Short cockpit-readable phrase for the banner detail line and the log.
    var label: String {
        switch self {
        case .velocityDisagreesWithPosition: return "position contradicts velocity"
        case .impossibleKinematics:          return "impossible motion"
        case .softwareGeneratedFix:          return "software-generated fix"
        case .confidentButInconsistent:      return "confident but inconsistent"
        case .selfInconsistentFix:           return "fix self-inconsistent"
        case .accuracyUnexplainedByGeometry: return "accuracy worse than geometry allows"
        case .fixLostUnexplainedByGeometry:  return "fix lost with good geometry"
        case .geometryExplainsError:         return "poor satellite geometry"
        case .geometryMarginal:              return "marginal satellite geometry"
        case .geometryUnknown:               return "no almanac — cause unknown"
        }
    }
}

/// The classifier's output: the verdict, how much it is worth, the evidence, and the one line of copy
/// the pilot actually reads. Pure value type — snapshot it, publish it, log it, diff it.
struct GPSThreatAssessment: Equatable, Sendable {
    var threat: GPSThreat = .none
    var confidence: GPSThreatConfidence = .low
    var reasons: [GPSThreatReason] = []
    /// Cockpit copy: imperative, short enough for one banner line, and it always names an ACTION. An
    /// advisory that only describes the failure makes the pilot do the reasoning at the worst moment.
    var advisory: String = GPSThreatClassifier.nominalAdvisory
    var at: Date = .distantPast

    /// The geometry verdict the classification rested on, kept so the log can show the reasoning and so
    /// a diagnostics screen can say "we could not attribute this because there was no almanac".
    var geometry: GPSGeometryVerdict = .unknown
    /// PDOP as predicted at classification time. Stored as a plain Double rather than the whole `PredictedDOP`
    /// so this type stays independent of the almanac module's shape.
    var predictedPDOP: Double?

    /// One-line evidence phrase for the banner and the log ("position contradicts velocity · confident but inconsistent").
    var reasonText: String { reasons.map(\.label).joined(separator: " · ") }

    /// True when the pilot must be told, as opposed to merely logged. `degraded` is intentionally NOT
    /// included: an ordinary accuracy dip is already carried by the integrity banner, and raising a
    /// second alert for it is how a warning system trains itself to be ignored.
    var warrantsAlert: Bool { threat.isInterference }
}

/// Classify an integrity failure into a THREAT by cross-examining the measurement against the sky that
/// was predicted for the same moment.
///
/// The whole method rests on one asymmetry. The integrity monitor only sees what the receiver reports,
/// and a receiver reports the same "±200 m" whether it is sitting in a downtown canyon or being drowned
/// by a truck-mounted jammer. An almanac-derived PredictedDOP is computed from orbital elements and ownship's
/// position — it never touched the RF — so it says what the error SHOULD have been. When the predicted
/// error is 8 m and the receiver is delivering 200 m, geometry has been eliminated as the explanation
/// and something is denying the signal. When the almanac predicts 60 m, nothing has been learned.
///
/// NASA/JPL Power-of-10: pure, deterministic, `now` injected, no loops with unbounded trip counts, no
/// recursion, every function short enough to read in one screen. Nothing here does I/O or reads a clock,
/// so every rule below is exercisable from a table of inputs.
enum GPSThreatClassifier {

    /// Thresholds. Tuned to fail toward UNDER-calling interference: a false "spoofing" verdict in a
    /// parking garage costs the pilot's trust in the whole feature, and trust is the only thing that
    /// makes the true positive useful six months later.
    struct Config: Equatable, Sendable {
        /// PDOP at or below which the predicted sky is GOOD — geometry cannot be blamed for a bad fix.
        /// 3.0 is comfortably inside the "good" band of the conventional PredictedDOP rating (2–5), and at a
        /// phone's ~8 m UERE it predicts a ~24 m 1-sigma error, i.e. still a usable fix.
        var goodPDOP = 3.0
        /// PDOP above which the sky is POOR and on its own accounts for a bad fix. Nothing above this
        /// may ever be called jamming, however far the measurement has blown out — the honest verdict
        /// under a bad constellation is "degraded", full stop.
        var poorPDOP = 6.0
        /// Below this many satellites above the mask the geometry is poor no matter what the PredictedDOP says;
        /// four satellites is the bare minimum for a 3D solution and leaves no redundancy at all.
        var minSatellites = 5
        /// Satellites needed to call the sky good when NO PredictedDOP is available. Higher than the PredictedDOP path
        /// demands, because a raw count says nothing about how the satellites are distributed — eleven
        /// of them clustered in one quadrant is a terrible fix with a reassuring number attached.
        var strongSatellites = 8
        /// A sky this good turns a jamming verdict from plausible into corroborated (confidence bump).
        var excellentPDOP = 2.0
        var excellentSatellites = 8
        /// A geometry this bad is a positive, high-confidence explanation for the error rather than a
        /// mere failure to rule interference out.
        var severeGeometryPDOP = 10.0
        /// 1-sigma user-equivalent range error for a phone-class single-frequency L1 receiver, metres.
        /// Predicted horizontal 1-sigma error is HDOP × UERE; 8 m is deliberately generous (typical
        /// quoted figures are 4–7 m) so the predicted error is an over-estimate and the "unexplained"
        /// test is correspondingly harder to trip.
        var uereM = 8.0
        /// Measured accuracy counts as unexplained past this multiple of the predicted 1-sigma error.
        /// 3-sigma: honest receiver noise essentially never lands out here, so what does is not noise.
        var unexplainedFactor = 3.0
        /// Accuracy at or below which the receiver is reporting CONFIDENCE. Matched to the integrity
        /// monitor's caution threshold so the two never disagree about what "fine" means.
        var confidentAccuracyM = 30.0

        /// ABSOLUTE floor under any interference claim, in metres. Nothing below this is ever called
        /// jamming, whatever the ratio test says.
        ///
        /// This exists because HDOP x UERE and `CLLocation.horizontalAccuracy` are not the same
        /// quantity. UERE models a bare-GNSS 1-sigma pseudorange error; CoreLocation reports a FUSED
        /// Wi-Fi/cell/GNSS confidence radius that an iPhone routinely quotes as 30 m or a quantised
        /// 65 m outdoors under a completely open sky. Comparing them made the ratio ceiling (HDOP 1.0
        /// x 8 x 3 = 24 m) sit BELOW the integrity monitor's own 30 m caution line, so every fix the
        /// monitor merely called degraded was escalated to "GPS interference" — a false alarm on
        /// ordinary urban ramp noise, in the app's loudest voice. Tying the floor to the monitor's
        /// UNUSABLE threshold makes the two layers agree: caution is caution, and only an accuracy bad
        /// enough that the monitor stops trusting the fix at all can be attributed to interference.
        var jammingFloorM = 100.0
    }

    // MARK: - Cockpit copy

    static let nominalAdvisory = "GPS nominal. No action required."

    // MARK: - Entry point

    /// Classify one integrity assessment against the predicted sky.
    ///
    /// `predictedDOP` and `satellitesAboveMask` are BOTH optional and both may be absent — no almanac
    /// downloaded, an expired one, or ownship outside its validity window. That case is not an error and
    /// must not be papered over: without an independent prediction, jamming and an ordinary urban-canyon
    /// dip produce byte-identical evidence, so the verdict falls back to `degraded` and says why.
    static func classify(integrity: GPSIntegrityAssessment,
                         predictedDOP: PredictedDOP?,
                         satellitesAboveMask: Int?,
                         now: Date,
                         config: Config = Config()) -> GPSThreatAssessment {
        assert(config.goodPDOP > 0 && config.goodPDOP < config.poorPDOP,
               "the good/poor PDOP bands must be positive and ordered")
        assert(config.unexplainedFactor >= 1 && config.uereM > 0,
               "the unexplained-error test must not be looser than the prediction itself")

        let geometry = geometryVerdict(dop: predictedDOP, satellitesAboveMask: satellitesAboveMask,
                                       config: config)
        let spoof = spoofReasons(integrity: integrity, config: config)
        let accuracyDenied = integrity.reasons.contains(.accuracyDegraded)
            || integrity.reasons.contains(.accuracyUnusable)
        let fixLost = integrity.reasons.contains(.fixStale)

        var threat = GPSThreat.none
        var reasons: [GPSThreatReason] = []
        // With no failure at all, the confidence is confidence that nothing is wrong: high once the
        // monitor has actually seen a fix, low before it has (silence is not evidence of health).
        var confidence: GPSThreatConfidence = integrity.state == .unknown ? .low : .high

        if !spoof.isEmpty {
            threat = .spoofing                       // outranks jamming: a spoofer usually jams first
            reasons = spoof
            confidence = spoofConfidence(spoof)
        } else if accuracyDenied || fixLost {
            reasons = jammingReasons(geometry: geometry, accuracyDenied: accuracyDenied, fixLost: fixLost,
                                     integrity: integrity, dop: predictedDOP, config: config)
            threat = reasons.isEmpty ? .degraded : .jamming
            if reasons.isEmpty {
                let why = nonAttribution(geometry)
                reasons = [why]
                confidence = degradedConfidence(why, dop: predictedDOP, config: config)
            } else {
                confidence = jammingConfidence(reasons: reasons, integrity: integrity, dop: predictedDOP,
                                               satellites: satellitesAboveMask, config: config)
            }
        }

        return GPSThreatAssessment(threat: threat, confidence: confidence, reasons: reasons,
                                   advisory: advisory(for: threat, integrity: integrity), at: now,
                                   geometry: geometry, predictedPDOP: predictedDOP.map(\.pdop))
    }

    // MARK: - Geometry

    /// Rate the predicted sky on PredictedDOP and satellite count alone — nothing measured enters here, which is
    /// what makes it usable as an independent control.
    ///
    /// A degenerate solution (a singular geometry matrix yields an infinite or NaN PredictedDOP) is classed POOR
    /// rather than asserted away: an almanac evaluated at the edge of its validity can legitimately
    /// produce one, and the safe reading of "the geometry math fell over" is "do not accuse anyone".
    static func geometryVerdict(dop: PredictedDOP?, satellitesAboveMask: Int?,
                                config: Config) -> GPSGeometryVerdict {
        assert(config.minSatellites >= 0 && config.strongSatellites >= config.minSatellites,
               "the satellite gates must be ordered")
        assert(satellitesAboveMask == nil || satellitesAboveMask! >= 0,
               "a satellite count cannot be negative")
        guard dop != nil || satellitesAboveMask != nil else { return .unknown }
        if let sats = satellitesAboveMask, sats < config.minSatellites { return .poor }
        if let d = dop {
            guard d.pdop.isFinite, d.pdop > 0 else { return .poor }
            if d.pdop > config.poorPDOP { return .poor }
            return d.pdop <= config.goodPDOP ? .good : .fair
        }
        return satellitesAboveMask! >= config.strongSatellites ? .good : .fair
    }

    /// Does the predicted geometry account for the accuracy CoreLocation is actually reporting?
    ///
    /// Predicted 1-sigma horizontal error is HDOP × UERE; anything within `unexplainedFactor` sigma of
    /// that is ordinary receiver behaviour. Returns FALSE when there is nothing to compare against —
    /// this function answers "has geometry been ruled IN as the cause", and the absence of a prediction
    /// is never an answer to that. The caller pairs it with a `.good` geometry verdict, so a missing
    /// HDOP can never by itself promote anything to jamming.
    static func geometryExplains(accuracyM: Double?, dop: PredictedDOP?, config: Config) -> Bool {
        assert(config.uereM > 0, "UERE must be positive to predict an error at all")
        assert(config.unexplainedFactor >= 1, "the sigma multiple must not shrink the prediction")
        guard let acc = accuracyM, let d = dop, acc.isFinite, d.hdop.isFinite, d.hdop > 0 else {
            return false
        }
        return acc <= d.hdop * config.uereM * config.unexplainedFactor
    }

    // MARK: - Evidence

    /// The spoofing tells, read straight off the integrity monitor's own reasons.
    ///
    /// `confidentButInconsistent` is appended last and only as corroboration: it is the reason the whole
    /// classifier exists — a spoofer transmits a strong, clean signal, so the receiver reports a tight
    /// accuracy for a position that is a lie, and every accuracy-threshold check in the app waves it
    /// through. It documents the signature; it does not raise the confidence on its own.
    ///
    /// The `selfInconsistentFix` fallback covers a `suspect` state that arrives without one of the four
    /// suspect-severity reasons. `GPSIntegrityMonitor` cannot currently produce that (its latch re-inserts
    /// the reasons that tripped it), but silently DOWNGRADING a spoof verdict because the reason list
    /// changed shape upstream is the one failure mode this file must not have.
    static func spoofReasons(integrity: GPSIntegrityAssessment, config: Config) -> [GPSThreatReason] {
        assert(config.confidentAccuracyM > 0, "the confident-accuracy gate must be positive")
        assert(integrity.reasons.count <= GPSIntegrityReason.allCases.count,
               "the integrity monitor emits each reason at most once")
        var out: [GPSThreatReason] = []
        if integrity.reasons.contains(.positionJump) { out.append(.velocityDisagreesWithPosition) }
        if integrity.reasons.contains(.impossibleSpeed)
            || integrity.reasons.contains(.impossibleAcceleration) { out.append(.impossibleKinematics) }
        if integrity.reasons.contains(.simulatedSource) { out.append(.softwareGeneratedFix) }
        if out.isEmpty, integrity.state >= .suspect { out.append(.selfInconsistentFix) }
        guard !out.isEmpty else { return [] }
        if let acc = integrity.horizontalAccuracyM, acc <= config.confidentAccuracyM {
            out.append(.confidentButInconsistent)
        }
        return out
    }

    /// The jamming tells — empty unless the sky was GOOD, which is the gate that keeps an urban canyon
    /// from being reported as an attack.
    ///
    /// A lost fix gets no ratio test: there is no accuracy number to compare once the solution has
    /// stopped arriving, and a receiver that cannot hold a lock while a clean constellation sits
    /// overhead has already said everything the test would have.
    static func jammingReasons(geometry: GPSGeometryVerdict, accuracyDenied: Bool, fixLost: Bool,
                               integrity: GPSIntegrityAssessment, dop: PredictedDOP?,
                               config: Config) -> [GPSThreatReason] {
        assert(accuracyDenied || fixLost, "called only when the monitor reported a denial symptom")
        assert(config.poorPDOP > config.goodPDOP, "the PDOP bands must be ordered")
        guard geometry == .good else { return [] }
        var out: [GPSThreatReason] = []
        // Three conditions, all required. The accuracy must actually be BAD (`jammingFloorM`, not just
        // past the caution line); it must be a real measurement — a MISSING accuracy is not evidence of
        // anything and must never be read as denial; and geometry must fail to explain it.
        if accuracyDenied, let acc = integrity.horizontalAccuracyM, acc.isFinite,
           acc > config.jammingFloorM,
           !geometryExplains(accuracyM: acc, dop: dop, config: config) {
            out.append(.accuracyUnexplainedByGeometry)
        }
        if fixLost { out.append(.fixLostUnexplainedByGeometry) }
        return out
    }

    /// Why we declined to call it interference, phrased as evidence rather than as an absence.
    static func nonAttribution(_ geometry: GPSGeometryVerdict) -> GPSThreatReason {
        switch geometry {
        case .unknown: return .geometryUnknown
        case .poor:    return .geometryExplainsError
        case .fair:    return .geometryMarginal
        // Good sky, denial symptom, yet no jamming reason survived: the ratio test found the error
        // inside what this geometry predicts, so the geometry does explain it after all.
        case .good:    return .geometryExplainsError
        }
    }

    // MARK: - Confidence

    /// Spoofing confidence counts INDEPENDENT tells. A software-generated fix is not circumstantial —
    /// the OS is stating it — so it stands alone at high. One kinematic tell is medium: a single jump
    /// can also be a receiver re-converging after a tunnel, and the rule that a lone soft signal never
    /// reaches high exists to keep the "do not navigate by GPS" advisory meaning something.
    static func spoofConfidence(_ reasons: [GPSThreatReason]) -> GPSThreatConfidence {
        assert(!reasons.isEmpty, "spoofing confidence needs at least one reason")
        assert(reasons.count <= GPSThreatReason.allCases.count, "reasons are appended once each")
        if reasons.contains(.softwareGeneratedFix) { return .high }
        let tells = reasons.filter {
            $0 == .velocityDisagreesWithPosition || $0 == .impossibleKinematics
        }.count
        if tells >= 2 { return .high }
        return tells == 1 ? .medium : .low
    }

    /// Jamming confidence adds up how much of the picture points the same way: how many denial channels
    /// tripped, whether the denial is total rather than marginal, and whether the sky is merely good or
    /// unambiguously excellent. One coarse-accuracy channel under a merely-good sky is a whisper (low);
    /// a blown-out unusable fix under eleven satellites at PDOP 1.8 is three independent agreements.
    static func jammingConfidence(reasons: [GPSThreatReason], integrity: GPSIntegrityAssessment,
                                  dop: PredictedDOP?, satellites: Int?, config: Config) -> GPSThreatConfidence {
        assert(!reasons.isEmpty, "jamming confidence needs at least one reason")
        assert(config.excellentPDOP <= config.goodPDOP, "excellent must be a subset of good")
        var score = reasons.count
        if integrity.state >= .unreliable { score += 1 }
        if let d = dop, d.pdop <= config.excellentPDOP,
           let sats = satellites, sats >= config.excellentSatellites { score += 1 }
        if score >= 3 { return .high }
        return score == 2 ? .medium : .low
    }

    /// Confidence in the DEGRADED attribution, i.e. how sure we are that this is ordinary and not an
    /// attack. A genuinely awful sky is a positive explanation; "no almanac" and "merely fair sky" are
    /// admissions that we could not tell, and they must read as low so nobody mistakes silence for an
    /// all-clear.
    static func degradedConfidence(_ reason: GPSThreatReason, dop: PredictedDOP?,
                                   config: Config) -> GPSThreatConfidence {
        assert(config.severeGeometryPDOP > config.poorPDOP, "severe must be worse than poor")
        assert(reason == .geometryExplainsError || reason == .geometryMarginal
               || reason == .geometryUnknown, "not a non-attribution reason")
        guard reason == .geometryExplainsError else { return .low }
        if let d = dop, d.pdop.isFinite, d.pdop > config.severeGeometryPDOP { return .high }
        return .medium
    }

    // MARK: - Advisory

    /// The cockpit line. Short, imperative, and it names the action — the pilot is task-saturated and
    /// reading this on a knee-mounted iPad in turbulence.
    ///
    /// Severity is deliberately graded WITHIN a verdict by the integrity state, because "possible
    /// interference, keep an eye on it" and "the position is gone, fly the navaids" are different flights.
    /// The degraded copy stays flat and unalarming on purpose: an accuracy dip is routine, and a banner
    /// that shouts at routine events is a banner the pilot stops reading.
    static func advisory(for threat: GPSThreat, integrity: GPSIntegrityAssessment) -> String {
        let severe = integrity.state >= .unreliable
        switch threat {
        case .spoofing:
            return "GPS position may be false. Do not navigate by GPS — cross-check VOR/DME and advise ATC."
        case .jamming:
            return severe ? "GPS interference likely. Navigate by navaids, expect GPS loss, advise ATC."
                          : "Possible GPS interference. Cross-check navaids and advise ATC if it worsens."
        case .degraded:
            return severe ? "GPS position unusable. Navigate by navaids until it recovers."
                          : "Expect degraded GPS position. Cross-check navaids before relying on it."
        case .none:
            return integrity.state == .unknown
                ? "No GPS fix yet. Expect no ownship position until it acquires."
                : nominalAdvisory
        }
    }
}
