import Foundation

/// A flight model that flies a published approach, so the vertical guidance can be exercised on the
/// ground instead of only in the air.
///
/// The vertical picture — `ApproachProfile.pathAltitudeFt`, `deviationFt`, `requiredVerticalSpeedFpm`
/// and the deviation colouring built on them — is the one part of the app whose correctness a pilot
/// cannot check by looking at it. It only ever draws something when a real aircraft is inside a real
/// final segment, which is exactly when nobody is in a position to be checking arithmetic. This flies
/// that segment on demand: down the published course, intercepting the glidepath from below at the FAF
/// and tracking it to the threshold, with deliberate offsets available so the deviation readout and the
/// required-rate advisory can be seen to respond the right way and by the right amount.
///
/// PURE BY CONSTRUCTION. No timers, no CoreLocation, no `Date()`, no actor isolation: `dt` is injected,
/// exactly as `GPSIntegrityMonitor` injects `now`. That is what lets the tests assert closed-loop
/// properties — "every on-path sample has deviation within 5 ft", "the realised rate equals the required
/// rate" — as arithmetic rather than as a timing race.
///
/// IT DOES NOT INVENT GUIDANCE. The aircraft is flown against whatever the procedure actually publishes.
/// On a non-precision approach with no coded angle there is no path to track, so it descends to the
/// published floors and levels — the same distinction `ApproachProfile` draws, tested from the other side.
struct ApproachSimulator: Equatable {

    /// What the aircraft is doing. `intercept` is the interesting one: level at the FAF crossing
    /// altitude, waiting for the descending path to come down to it — which is how the aeroplane meets
    /// the glidepath in reality and the only way the capture transition gets exercised.
    enum Phase: String, Equatable, CaseIterable {
        case descent, intercept, onPath, levelAtFloor, missed, finished
    }

    struct Config: Equatable {
        /// True airspeed over the ground, knots. Drives both the along-track rate and the required
        /// vertical rate, so it is never scaled by the wall-clock multiplier.
        var groundSpeedKt: Double = 120
        /// Deliberate height offset from the published path, feet. Positive is high.
        var verticalOffsetFt: Double = 0
        /// Deliberate displacement from the final approach course, NM. Above
        /// `ApproachProfile.maxCrossTrackNm` the profile correctly refuses to place the aircraft at all.
        var crossTrackNm: Double = 0
        /// Where to begin, NM from the threshold.
        var startAtNm: Double = 12
        /// Rate flown before the path is captured.
        var descentFpm: Double = 700
    }

    struct Sample: Equatable {
        let coord: Coord
        let altitudeFtMSL: Double
        let groundSpeedKt: Double
        let courseDegTrue: Double
        let distanceToThresholdNm: Double
        let phase: Phase
        /// The rate the model is flying, feet per minute (negative = descending). Reported so a test can
        /// check it against `requiredVerticalSpeedFpm`; NOT published as if it were measured.
        let verticalSpeedFpm: Double
    }

    // MARK: state

    private(set) var config: Config
    private(set) var phase: Phase = .descent
    private(set) var distanceNm: Double
    private(set) var altitudeFtMSL: Double
    private(set) var verticalSpeedFpm: Double = 0

    private let profile: ApproachProfile
    private let threshold: Coord
    /// Bearing FROM the threshold to the outermost station — the reciprocal of the inbound course.
    private let outboundBearingDeg: Double
    private let floorFloorFt: Double

    /// Feet of tolerance for calling the path captured. One second at 700 fpm is ~12 ft, so 20 keeps a
    /// 4 Hz model from stepping straight through the capture without ever reporting it.
    static let captureToleranceFt = 20.0
    /// Below this the approach is over and the model stops rather than flying through the runway.
    static let finishedAtNm = 0.0
    /// How much faster than the path itself the aircraft descends while intercepting it.
    static let interceptMarginFpm = 400.0

    /// A sensible place to begin: just OUTSIDE the point where the descending path crosses the floor the
    /// aircraft would be holding. Start inside that and the aeroplane is already above the path and
    /// descends onto it from above, which happens but is not the picture the approach is flown to.
    static func defaultStartNm(profile: ApproachProfile) -> Double {
        let outer = profile.stations.first?.distanceToThresholdNm ?? 10
        guard let floor = profile.stations.first?.floorFt,
              let crossing = profile.distanceNm(forAltitudeFt: floor) else { return outer }
        return min(outer, crossing + 1.0)
    }

    /// nil when the procedure cannot support a simulation — no threshold anchor, or no along-track axis
    /// to fly down. Refusing here beats flying an aircraft along an invented course.
    init?(profile: ApproachProfile, threshold: Coord?, config: Config = Config()) {
        guard let threshold, let outer = profile.outerCoordinate,
              let first = profile.stations.first, first.distanceToThresholdNm > 0.5 else { return nil }
        assert(config.groundSpeedKt > 0, "ApproachSimulator: non-positive ground speed")
        assert(config.startAtNm >= 0, "ApproachSimulator: negative start distance")
        self.profile = profile
        self.threshold = threshold
        self.config = config
        self.outboundBearingDeg = Geo.bearing(threshold, outer)
        self.floorFloorFt = profile.thresholdElevFt ?? 0
        let start = min(max(config.startAtNm, 0.2), first.distanceToThresholdNm)
        self.distanceNm = start
        // Start LEVEL at the altitude the procedure would have you at here, so the aircraft arrives at
        // the glidepath from underneath rather than materialising on it.
        self.altitudeFtMSL = Self.initialAltitude(profile: profile, atNm: start)
    }

    /// The altitude to begin at: the published floor at or outside this point, which is what an aircraft
    /// established on the segment would be holding.
    static func initialAltitude(profile: ApproachProfile, atNm d: Double) -> Double {
        var best: Double?
        for s in profile.stations.prefix(32) where s.distanceToThresholdNm >= d {   // bounded (rule 2)
            if let f = s.floorFt { best = min(best ?? f, f) }
        }
        if let best { return best }
        return profile.pathAltitudeFt(atNm: d).map { $0 + 400 } ?? 3_000
    }

    // MARK: the model

    /// Advance by `dt` seconds of FLIGHT time and return where the aircraft now is.
    mutating func step(dt: TimeInterval) -> Sample {
        assert(dt > 0 && dt < 60, "ApproachSimulator.step: implausible dt")
        assert(config.groundSpeedKt > 0, "ApproachSimulator.step: non-positive ground speed")
        if phase != .missed && phase != .finished {
            distanceNm = max(0, distanceNm - config.groundSpeedKt * dt / 3_600)
        }
        advanceVertically(dt: dt)
        if phase != .missed, distanceNm <= Self.finishedAtNm { phase = .finished }
        return sample()
    }

    /// Put the aircraft at a chosen point on the approach without flying there — the jump control.
    mutating func place(atNm d: Double) {
        assert(d >= 0, "ApproachSimulator.place: negative distance")
        let outer = profile.stations.first?.distanceToThresholdNm ?? d
        distanceNm = min(max(d, 0), outer)
        altitudeFtMSL = Self.initialAltitude(profile: profile, atNm: distanceNm)
        phase = .descent
        verticalSpeedFpm = 0
    }

    mutating func update(config newConfig: Config) {
        assert(newConfig.groundSpeedKt > 0, "ApproachSimulator.update: non-positive ground speed")
        config = newConfig
    }

    mutating func flyMissed() {
        phase = .missed
    }

    /// The vertical half of the model, split out to keep `step` short and the phase rules legible.
    private mutating func advanceVertically(dt: TimeInterval) {
        let minutes = dt / 60
        switch phase {
        case .finished:
            verticalSpeedFpm = 0
        case .missed:
            verticalSpeedFpm = 1_000
            altitudeFtMSL += verticalSpeedFpm * minutes
        case .descent, .intercept:
            // Three cases, and the middle one is the whole point. HIGH: descend faster than the path so
            // there is real closure. LOW: hold LEVEL and let the descending path come down to meet you —
            // that is what intercepting from below means, and climbing onto the path or snapping to it
            // would skip the transition the guidance most needs to be watched through. WITHIN
            // TOLERANCE: captured.
            let target = commandedAltitude()
            let error = altitudeFtMSL - target
            if abs(error) <= Self.captureToleranceFt {
                phase = profile.hasVerticalGuidance ? .onPath : .levelAtFloor
                altitudeFtMSL = target
                verticalSpeedFpm = trackingRate()
            } else if error > 0 {
                verticalSpeedFpm = -interceptRate()
                altitudeFtMSL = max(target, altitudeFtMSL + verticalSpeedFpm * minutes)
                phase = .intercept
            } else {
                verticalSpeedFpm = 0                                // level, waiting for the path
                phase = .intercept
            }
        case .onPath:
            altitudeFtMSL = commandedAltitude()
            verticalSpeedFpm = trackingRate()
        case .levelAtFloor:
            // No published angle: hold the floor, and step down as the floors do.
            let target = commandedAltitude()
            if target < altitudeFtMSL - 1 {
                verticalSpeedFpm = -config.descentFpm
                altitudeFtMSL = max(target, altitudeFtMSL + verticalSpeedFpm * minutes)
            } else {
                verticalSpeedFpm = 0
                altitudeFtMSL = max(altitudeFtMSL, target)
            }
        }
    }

    /// The altitude the model is aiming for at the current distance: the published path where there is
    /// one, otherwise the lowest floor still in force — plus the pilot's deliberate offset.
    private func commandedAltitude() -> Double {
        if profile.hasVerticalGuidance, let path = profile.pathAltitudeFt(atNm: distanceNm) {
            return path + config.verticalOffsetFt
        }
        // No published angle: the floor in force is the one at the NEAREST station still ahead of us,
        // which is what steps the aircraft down the staircase as each fix goes by.
        var floor = floorFloorFt
        var nearestAhead = Double.greatestFiniteMagnitude
        for s in profile.stations.prefix(32) {                                    // bounded (rule 2)
            guard let f = s.floorFt, s.distanceToThresholdNm >= distanceNm else { continue }
            if s.distanceToThresholdNm < nearestAhead { nearestAhead = s.distanceToThresholdNm; floor = f }
        }
        return floor + config.verticalOffsetFt
    }

    /// The rate that holds the published path at the current ground speed — the same quantity the
    /// profile's advisory shows, so a test can assert the two agree.
    private func trackingRate() -> Double {
        guard let fpm = profile.requiredVerticalSpeedFpm(groundSpeedKt: config.groundSpeedKt) else { return 0 }
        return -fpm
    }

    /// The rate flown while chasing the path. It must EXCEED the path's own rate of descent or there is
    /// no closure at all: at 120 kt a 3-degree path descends at 637 fpm, so a nominal 700 fpm closes at
    /// only 63 fpm and an aircraft a few hundred feet high reaches the runway before it reaches the
    /// glidepath. The margin is what makes the intercept finite for every offset the panel can dial in.
    private func interceptRate() -> Double {
        assert(config.descentFpm > 0, "ApproachSimulator: non-positive descent rate")
        return max(config.descentFpm, abs(trackingRate()) + Self.interceptMarginFpm)
    }

    private func sample() -> Sample {
        // Recompute the coordinate from the distance every step rather than integrating it, so rounding
        // cannot walk the aircraft off the course over a long run.
        let onCourse = Geo.destination(from: threshold, bearingDeg: outboundBearingDeg, distanceNm: distanceNm)
        let coord = config.crossTrackNm == 0
            ? onCourse
            : Geo.destination(from: onCourse, bearingDeg: outboundBearingDeg + 90, distanceNm: config.crossTrackNm)
        var course = outboundBearingDeg + 180
        if course >= 360 { course -= 360 }
        return Sample(coord: coord,
                      altitudeFtMSL: altitudeFtMSL,
                      groundSpeedKt: config.groundSpeedKt,
                      courseDegTrue: course,
                      distanceToThresholdNm: distanceNm,
                      phase: phase,
                      verticalSpeedFpm: verticalSpeedFpm)
    }
}
