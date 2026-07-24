import Foundation

/// How much the position solution can be trusted right now, worst-first when several apply.
///
/// This is a KINEMATIC integrity check, not a signal-level one. iOS exposes no DOP, no satellite count,
/// no per-satellite SNR and no raw GNSS measurements (that is Android's `GnssMeasurement` API), so a
/// receiver-autonomous check on pseudoranges is impossible here. What CoreLocation *does* give is an
/// accuracy estimate plus an independently-computed velocity, and a spoofed or degraded solution shows
/// up in the disagreement between them — a position that teleports while ground speed stays smooth, an
/// implied speed no aircraft can fly, an accuracy that explodes. Those are the tells we can actually see.
enum GPSIntegrityState: Int, Comparable, Sendable {
    case unknown = 0      // no fix yet this session — show nothing
    case nominal = 1      // accuracy fine, kinematics self-consistent
    case degraded = 2     // usable but coarse / slightly stale — advise a navaid cross-check
    case unreliable = 3   // unusable: accuracy blown out or the fix has gone stale — suppress ownship
    case suspect = 4      // self-inconsistent or software-generated — possible spoofing

    static func < (a: GPSIntegrityState, b: GPSIntegrityState) -> Bool { a.rawValue < b.rawValue }
}

/// Why the monitor is in its current state. Several can hold at once; the state is the worst of them.
enum GPSIntegrityReason: String, Sendable, CaseIterable {
    case accuracyDegraded        // horizontal accuracy past the caution threshold
    case accuracyUnusable        // horizontal accuracy past the usable threshold
    case fixStale                // no fresh fix — the observable consequence of jamming or a lost lock
    case positionJump            // position moved much further than the reported velocity allows
    case impossibleSpeed         // implied ground speed beyond the aircraft envelope
    case impossibleAcceleration  // reported speed changed faster than an airframe can
    case simulatedSource         // the OS flags this location as software-generated

    /// Short cockpit-readable phrase for the banner / log.
    var label: String {
        switch self {
        case .accuracyDegraded:       return "accuracy degraded"
        case .accuracyUnusable:       return "accuracy unusable"
        case .fixStale:               return "fix stale"
        case .positionJump:           return "position jump"
        case .impossibleSpeed:        return "impossible speed"
        case .impossibleAcceleration: return "impossible acceleration"
        case .simulatedSource:        return "simulated location"
        }
    }
}

/// The monitor's output: the state, why, and the derived quantities consumers need to decide what to
/// draw and what to suppress. Pure value type — snapshot it, publish it, log it.
struct GPSIntegrityAssessment: Equatable, Sendable {
    var state: GPSIntegrityState = .unknown
    var reasons: [GPSIntegrityReason] = []
    var at: Date = .distantPast

    /// 1-sigma horizontal radius of the last fix, in metres — the accuracy ring's radius.
    var horizontalAccuracyM: Double?
    /// True when the reported course is trustworthy: computed, inside its 1-sigma limit, and the
    /// aircraft is moving fast enough that GPS course isn't just noise. Gate wind-correction and any
    /// track-up rotation on this.
    var courseUsable = false
    /// True when the reported ground speed is trustworthy (inside its 1-sigma limit).
    var speedUsable = false
    /// Derived vertical speed in feet per minute over the smoothing baseline — a GPS VSI for a device
    /// with no baro. nil until two fixes span the baseline with usable altitudes.
    var verticalSpeedFpm: Double?

    /// Ownship should not be drawn at all in these states — a position we don't believe is worse than
    /// no position, because the pilot will fly it.
    var shouldSuppressOwnship: Bool { state >= .unreliable }

    /// One-line reason phrase, worst-first, for the banner and the log ("position jump · accuracy degraded").
    var reasonText: String { reasons.map(\.label).joined(separator: " · ") }
}

/// One state TRANSITION, kept so a post-flight review can find the unreliable segments of a track.
struct GPSIntegrityEvent: Equatable, Sendable {
    var at: Date
    var from: GPSIntegrityState
    var to: GPSIntegrityState
    var reasons: [GPSIntegrityReason]
}

extension GPSLogStamp {
    /// Project an assessment (+ the fix it came from) into the JSONL log column. Returns nil in the
    /// `unknown` state so a run with no GPS feed logs no GPS field at all rather than a row of nils.
    /// Position is written only when the monitor trusts it — the log must not record a coordinate the
    /// app refused to plot.
    init?(assessment a: GPSIntegrityAssessment, fix: DeviceFix?) {
        guard a.state != .unknown else { return nil }
        let trusted = !a.shouldSuppressOwnship ? fix : nil
        self.init(state: String(describing: a.state),
                  reasons: a.reasons.isEmpty ? nil : a.reasons.map(\.rawValue),
                  accuracyM: a.horizontalAccuracyM,
                  lat: trusted?.coord.lat, lon: trusted?.coord.lon,
                  altFt: trusted?.altitudeMSLft, vsFpm: a.verticalSpeedFpm,
                  courseUsable: a.courseUsable, speedUsable: a.speedUsable)
    }
}

/// Rolling GPS integrity check over a bounded window of recent fixes.
///
/// NASA/JPL Power-of-10: the fix history and the event log are fixed-capacity ring buffers (no unbounded
/// growth), every loop is bounded by those caps, there is no recursion, and `now` is injected rather
/// than read from the clock so every detector is deterministic under test.
///
/// Not thread-safe by design — `AppModel` owns one on the main actor and feeds it from the location
/// delegate, which already delivers on the main thread.
final class GPSIntegrityMonitor {

    /// Thresholds. Defaults are tuned for GA IFR: 30 m caution is roughly where a GPS position stops
    /// being good enough to fly an approach off, 100 m is unusable at any phase of flight.
    struct Config: Equatable, Sendable {
        var degradedAccuracyM = 30.0
        var unusableAccuracyM = 100.0
        var staleWarnS = 10.0
        var staleUnusableS = 30.0
        /// Staleness is only meaningful while MOVING. `DeviceLocation` runs a 15 m `distanceFilter` for
        /// battery, so a parked or slow-taxiing aircraft legitimately produces no deliveries for minutes —
        /// flagging that as a lost fix would cry wolf on every ramp. Below this ground speed the staleness
        /// detector stays silent (the tradeoff: a jam is not detected while stopped, when it matters least).
        var staleMotionMps = 2.5
        /// Envelope ceiling for the implied-speed check — generous so a fast turbine never trips it.
        var maxGroundSpeedKt = 700.0
        var maxAccelG = 0.6
        /// A jump must exceed reported-velocity travel × this, plus both accuracy radii, plus slack.
        var jumpSpeedFactor = 3.0
        var jumpToleranceM = 75.0
        var courseAccuracyLimitDeg = 20.0
        var speedAccuracyLimitMps = 2.5
        /// Below this ground speed GPS course is noise (taxi, run-up) — course is reported unusable.
        var courseValidSpeedMps = 1.5
        /// A suspect verdict is LATCHED this long: a spoof that settles into a smooth false track would
        /// otherwise clear itself one fix later, and the pilot needs to keep seeing it.
        var suspectHoldS = 60.0
        /// Pairwise checks are skipped across gaps longer than this — a backgrounded app resuming is a
        /// gap, not a teleport, and must never be reported as one.
        var maxPairGapS = 30.0
        /// Minimum span between the two fixes used for the derived VSI.
        var vsBaselineS = 3.0
    }

    static let maxHistory = 32
    static let maxEvents = 64

    let config: Config
    private(set) var assessment = GPSIntegrityAssessment()
    private(set) var events: [GPSIntegrityEvent] = []
    private var history: [DeviceFix] = []
    private var suspectUntil: Date?
    /// What tripped the latch, so the held warning keeps naming the real cause.
    private var suspectReasons: [GPSIntegrityReason] = []

    init(config: Config = .init()) {
        self.config = config
        history.reserveCapacity(Self.maxHistory)
    }

    var lastFix: DeviceFix? { history.last }

    /// Fold one fix in and return the new assessment. Out-of-order fixes (CoreLocation can replay a
    /// cached location) are dropped rather than treated as a jump.
    @discardableResult
    func ingest(_ fix: DeviceFix) -> GPSIntegrityAssessment {
        assert(fix.horizontalAccuracyM >= 0, "an invalid fix must not reach the monitor")
        assert(history.count <= Self.maxHistory, "history exceeded its cap")
        if let prev = history.last, fix.timestamp <= prev.timestamp { return assessment }

        var reasons = accuracyReasons(fix)
        if fix.isSimulated { reasons.append(.simulatedSource) }
        if let prev = history.last { reasons.append(contentsOf: pairReasons(prev: prev, fix: fix)) }

        history.append(fix)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }

        return apply(reasons: reasons, now: fix.timestamp, accuracy: fix.horizontalAccuracyM, fix: fix)
    }

    /// Re-evaluate WITHOUT a new fix — this is what catches a fix that simply stops arriving, which is
    /// how jamming and a lost lock actually present to an iOS app. Call it on a timer.
    ///
    /// Staleness is gated on MOTION: with the 15 m `distanceFilter` `DeviceLocation` runs for battery, a
    /// stationary aircraft produces no deliveries at all, and reporting that as a lost fix would fire on
    /// every ramp. Only a fix that was MOVING and then went quiet is evidence of anything.
    @discardableResult
    func tick(now: Date) -> GPSIntegrityAssessment {
        guard let last = history.last else { return assessment }
        let age = now.timeIntervalSince(last.timestamp)
        assert(age.isFinite, "fix age must be finite")
        assert(config.staleMotionMps >= 0, "motion gate must be non-negative")
        var reasons = accuracyReasons(last)
        if last.isSimulated { reasons.append(.simulatedSource) }
        let wasMoving = (last.groundSpeedMps ?? 0) >= config.staleMotionMps
        if wasMoving, age >= config.staleWarnS { reasons.append(.fixStale) }
        return apply(reasons: reasons, now: now, accuracy: last.horizontalAccuracyM, fix: last,
                     staleAge: age)
    }

    /// Forget everything (source change, session restart). Events are cleared too.
    func reset() {
        history.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        suspectUntil = nil
        suspectReasons = []
        assessment = GPSIntegrityAssessment()
    }

    // MARK: - Detectors

    /// Accuracy thresholds — the cheapest and most reliable signal iOS gives us.
    private func accuracyReasons(_ fix: DeviceFix) -> [GPSIntegrityReason] {
        if fix.horizontalAccuracyM > config.unusableAccuracyM { return [.accuracyUnusable] }
        if fix.horizontalAccuracyM > config.degradedAccuracyM { return [.accuracyDegraded] }
        return []
    }

    /// Consistency between two consecutive fixes: does the distance travelled agree with the velocity
    /// the receiver independently reported, and is the motion physically possible?
    private func pairReasons(prev: DeviceFix, fix: DeviceFix) -> [GPSIntegrityReason] {
        let dt = fix.timestamp.timeIntervalSince(prev.timestamp)
        guard dt > 0, dt <= config.maxPairGapS else { return [] }   // a resume gap is not a teleport
        let metres = Geo.nmBetween(prev.coord, fix.coord) * 1852.0
        assert(metres >= 0, "distance must be non-negative")
        var out: [GPSIntegrityReason] = []

        if (metres / dt) * 1.943844492 > config.maxGroundSpeedKt { out.append(.impossibleSpeed) }

        // The spoofing tell: position discontinuity while the velocity solution stays smooth. Both
        // accuracy radii are subtracted out so ordinary noise at the edge of a poor fix never trips it.
        if let reported = fix.groundSpeedMps ?? prev.groundSpeedMps {
            let allowed = reported * dt * config.jumpSpeedFactor
                + prev.horizontalAccuracyM + fix.horizontalAccuracyM + config.jumpToleranceM
            if metres > allowed { out.append(.positionJump) }
        }

        if let a = prev.groundSpeedMps, let b = fix.groundSpeedMps,
           abs(b - a) / dt > config.maxAccelG * 9.80665 {
            out.append(.impossibleAcceleration)
        }
        return out
    }

    /// Vertical speed in fpm from the newest fix back to the most recent one at least `vsBaselineS`
    /// older — differencing adjacent 1 Hz fixes would be pure noise. Bounded reverse scan (rule 2).
    private func verticalSpeedFpm() -> Double? {
        guard let newest = history.last, let newAlt = newest.altitudeMSLm else { return nil }
        assert(history.count <= Self.maxHistory, "history exceeded its cap")
        for i in stride(from: history.count - 2, through: 0, by: -1) {
            let older = history[i]
            guard let oldAlt = older.altitudeMSLm else { continue }
            let dt = newest.timestamp.timeIntervalSince(older.timestamp)
            if dt >= config.vsBaselineS {
                return (newAlt - oldAlt) * 3.280839895 / (dt / 60.0)
            }
        }
        return nil
    }

    // MARK: - State

    /// Map reasons to a state, apply the suspect latch, publish, and record a transition event.
    private func apply(reasons: [GPSIntegrityReason], now: Date, accuracy: Double,
                       fix: DeviceFix, staleAge: TimeInterval = 0) -> GPSIntegrityAssessment {
        var state = reasons.reduce(GPSIntegrityState.nominal) { max($0, Self.severity(of: $1, staleAge: staleAge, config: config)) }
        var reasons = reasons

        if state == .suspect {
            suspectUntil = now.addingTimeInterval(config.suspectHoldS)
            suspectReasons = reasons.filter { Self.severity(of: $0, staleAge: staleAge, config: config) == .suspect }
        } else if let until = suspectUntil, now < until {         // latched — keep showing the warning
            state = .suspect
            reasons.insert(contentsOf: suspectReasons.filter { !reasons.contains($0) }, at: 0)
        } else {
            suspectUntil = nil
            suspectReasons = []
        }

        let ordered = Self.ordered(reasons, staleAge: staleAge, config: config)
        var next = GPSIntegrityAssessment(state: state, reasons: ordered, at: now,
                                          horizontalAccuracyM: accuracy)
        next.courseUsable = courseUsable(fix, state: state)
        next.speedUsable = speedUsable(fix, state: state)
        next.verticalSpeedFpm = state >= .unreliable ? nil : verticalSpeedFpm()

        if next.state != assessment.state {
            events.append(GPSIntegrityEvent(at: now, from: assessment.state, to: next.state,
                                            reasons: ordered))
            if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        }
        assessment = next
        return next
    }

    /// Worst reason first, ties broken by declaration order. `sorted(by:)` is NOT stable, so without an
    /// explicit tiebreak two equally-severe reasons (a jump that is also an impossible speed) could swap
    /// places between runs and the banner's headline would flicker.
    private static func ordered(_ reasons: [GPSIntegrityReason], staleAge: TimeInterval,
                                config: Config) -> [GPSIntegrityReason] {
        let rank = { (r: GPSIntegrityReason) -> Int in
            GPSIntegrityReason.allCases.firstIndex(of: r) ?? GPSIntegrityReason.allCases.count
        }
        return reasons.sorted {
            let a = severity(of: $0, staleAge: staleAge, config: config)
            let b = severity(of: $1, staleAge: staleAge, config: config)
            return a == b ? rank($0) < rank($1) : a > b
        }
    }

    /// Severity of one reason. Staleness escalates with age: briefly late is a caution, long gone is
    /// unusable. Everything self-inconsistent is `suspect` — that is the spoofing bucket.
    private static func severity(of reason: GPSIntegrityReason, staleAge: TimeInterval,
                                 config: Config) -> GPSIntegrityState {
        switch reason {
        case .accuracyDegraded:  return .degraded
        case .accuracyUnusable:  return .unreliable
        case .fixStale:          return staleAge >= config.staleUnusableS ? .unreliable : .degraded
        case .positionJump, .impossibleSpeed, .impossibleAcceleration, .simulatedSource:
            return .suspect
        }
    }

    private func courseUsable(_ fix: DeviceFix, state: GPSIntegrityState) -> Bool {
        guard state < .unreliable, fix.courseDeg != nil else { return false }
        if let acc = fix.courseAccuracyDeg, acc > config.courseAccuracyLimitDeg { return false }
        guard let speed = fix.groundSpeedMps else { return false }
        return speed >= config.courseValidSpeedMps
    }

    private func speedUsable(_ fix: DeviceFix, state: GPSIntegrityState) -> Bool {
        guard state < .unreliable, fix.groundSpeedMps != nil else { return false }
        if let acc = fix.speedAccuracyMps, acc > config.speedAccuracyLimitMps { return false }
        return true
    }
}
