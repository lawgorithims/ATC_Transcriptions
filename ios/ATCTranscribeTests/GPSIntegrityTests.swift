import XCTest
@testable import ATCTranscribe

/// GPS integrity detectors: accuracy thresholds, staleness escalation, the spoofing tells (position
/// jump against a smooth velocity, impossible speed / acceleration, a software-generated fix), the
/// suspect latch, course/speed usability gating, the derived VSI, and the bounded history / event log.
///
/// Every fix is synthesized with an explicit timestamp and the monitor's `now` is injected, so these
/// are deterministic — no receiver, no clock, no waiting.
final class GPSIntegrityTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = Coord(lat: 33.0, lon: -97.0)

    /// A fix `dt` seconds after t0, `metresNorth` north of `home`, with the given reported ground speed.
    private func fix(dt: TimeInterval, metresNorth: Double = 0, accuracy: Double = 5,
                     speedMps: Double? = nil, speedAccuracyMps: Double? = 0.5,
                     courseDeg: Double? = 0, courseAccuracyDeg: Double? = 5,
                     altitudeM: Double? = nil, simulated: Bool = false) -> DeviceFix {
        let lat = home.lat + metresNorth / 111_320.0
        var f = DeviceFix(coord: Coord(lat: lat, lon: home.lon), altitudeMSLm: altitudeM,
                          groundSpeedMps: speedMps, courseDeg: courseDeg,
                          horizontalAccuracyM: accuracy)
        f.timestamp = t0.addingTimeInterval(dt)
        f.verticalAccuracyM = 5
        f.speedAccuracyMps = speedAccuracyMps
        f.courseAccuracyDeg = courseAccuracyDeg
        f.isSimulated = simulated
        return f
    }

    // MARK: - Baseline

    func testFirstGoodFixIsNominal() {
        let m = GPSIntegrityMonitor()
        XCTAssertEqual(m.assessment.state, .unknown, "no fix yet must not claim a state")
        let a = m.ingest(fix(dt: 0, speedMps: 60))
        XCTAssertEqual(a.state, .nominal)
        XCTAssertTrue(a.reasons.isEmpty)
        XCTAssertEqual(a.horizontalAccuracyM, 5)
        XCTAssertTrue(a.isTrustedForGuidance)
        XCTAssertTrue(a.isPositionProbablyReal)
    }

    // MARK: - Accuracy

    func testAccuracyThresholds() {
        let m = GPSIntegrityMonitor()
        XCTAssertEqual(m.ingest(fix(dt: 0, accuracy: 29)).state, .nominal)
        XCTAssertEqual(m.ingest(fix(dt: 1, accuracy: 45)).state, .degraded)
        XCTAssertEqual(m.assessment.reasons, [.accuracyDegraded])
        // Three agreeing readings before the worst verdict — see `confirmUnreliableCount`.
        XCTAssertEqual(m.ingest(fix(dt: 2, accuracy: 250)).state, .degraded)
        XCTAssertEqual(m.ingest(fix(dt: 3, accuracy: 250)).state, .degraded)
        let blown = m.ingest(fix(dt: 4, accuracy: 250))
        XCTAssertEqual(blown.state, .unreliable)
        XCTAssertEqual(blown.reasons, [.accuracyUnusable])
        XCTAssertFalse(blown.isTrustedForGuidance, "a 250 m fix cannot fly a glidepath")
        XCTAssertTrue(blown.isPositionProbablyReal, "coarse is not fabricated — it still gets drawn")
    }

    /// The reported in-flight fault, as a test. A single blown accuracy estimate is what CoreLocation
    /// emits while re-acquiring — under a wing in a turn, on a constellation handover — and it used to
    /// reach `.unreliable` on its own, which deleted the aeroplane, the track, the glide ring, terrain
    /// AGL and the storm alert until the next good fix.
    func testOneBadReadingDoesNotCondemnTheFix() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, accuracy: 5))
        let dip = m.ingest(fix(dt: 1, accuracy: 250))
        XCTAssertEqual(dip.state, .degraded, "one sample is a caution, not a verdict")
        XCTAssertTrue(dip.isPositionProbablyReal)
        XCTAssertEqual(m.ingest(fix(dt: 2, accuracy: 4)).state, .nominal, "and it clears at once")
    }

    /// Escalation needs three in a row; recovery needs one. Asymmetric on purpose: making a recovered
    /// receiver prove itself three times would leave a red banner up over a good fix.
    func testTheConfirmationRunResetsOnAnyGoodFix() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, accuracy: 250))
        m.ingest(fix(dt: 1, accuracy: 250))
        XCTAssertEqual(m.ingest(fix(dt: 2, accuracy: 4)).state, .nominal)
        XCTAssertEqual(m.ingest(fix(dt: 3, accuracy: 250)).state, .degraded,
                       "the run restarted — two before the gap do not count toward the next three")
        XCTAssertEqual(m.ingest(fix(dt: 4, accuracy: 250)).state, .degraded)
        XCTAssertEqual(m.ingest(fix(dt: 5, accuracy: 250)).state, .unreliable)
    }

    func testAccuracyRecoversToNominal() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, accuracy: 250))
        let back = m.ingest(fix(dt: 1, accuracy: 4))
        XCTAssertEqual(back.state, .nominal, "a recovered fix must clear — only suspect is latched")
    }

    // MARK: - Staleness

    func testStalenessEscalatesWithAge() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, speedMps: 60))
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(5)).state, .nominal)
        let warn = m.tick(now: t0.addingTimeInterval(12))
        XCTAssertEqual(warn.state, .degraded)
        XCTAssertEqual(warn.reasons, [.fixStale])
        // Each tick is one observation, so staleness confirms the same way accuracy does.
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(40)).state, .degraded)
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(41)).state, .degraded)
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(42)).state, .unreliable,
                       "a long-gone fix is unusable, not merely coarse")
    }

    func testTickBeforeAnyFixStaysUnknown() {
        let m = GPSIntegrityMonitor()
        XCTAssertEqual(m.tick(now: t0.addingTimeInterval(600)).state, .unknown,
                       "never having had a fix is not the same as having lost one")
    }

    // MARK: - The forced verdict (DEBUG affordance)

    /// `--force-gps-integrity` has to reproduce the real consequences of a state, or demonstrating the
    /// fix with it would prove nothing about the fix.
    func testAForcedVerdictCarriesTheRealConsequencesAndSaysItIsForced() {
        let m = GPSIntegrityMonitor()
        let live = m.ingest(fix(dt: 0, speedMps: 60))
        XCTAssertFalse(live.isSimulatedVerdict)

        let coarse = GPSIntegrityMonitor.forcing(live, to: .unreliable)
        XCTAssertTrue(coarse.isSimulatedVerdict, "a pinned verdict must announce itself")
        XCTAssertEqual(coarse.state, .unreliable)
        XCTAssertFalse(coarse.isTrustedForGuidance)
        XCTAssertTrue(coarse.isPositionProbablyReal, "coarse is still drawn — that is the whole point")
        XCTAssertFalse(coarse.courseUsable)
        XCTAssertNil(coarse.verticalSpeedFpm)
        // Widened so the 1-sigma ring is bigger than the symbol sitting on it.
        XCTAssertEqual(coarse.horizontalAccuracyM ?? 0, 250, accuracy: 0.001)

        let spoof = GPSIntegrityMonitor.forcing(live, to: .suspect)
        XCTAssertFalse(spoof.isPositionProbablyReal, "a disowned position cannot anchor a clearance")
        XCTAssertEqual(spoof.horizontalAccuracyM, live.horizontalAccuracyM,
                       "a spoof reports excellent accuracy — that is part of what it looks like")
    }

    // MARK: - The dismissal rule

    /// "I should be able to dismiss any warning" — but an X that muted the whole category would switch
    /// a safety advisory off for the flight, which is never what the tap means.
    func testDismissingOneStateStillLetsAWorseOneThrough() {
        let shows = AppModel.showsIntegrityBanner
        XCTAssertFalse(shows(.nominal, false, nil), "silent while the fix is good")
        XCTAssertTrue(shows(.degraded, false, nil))
        XCTAssertFalse(shows(.degraded, false, .degraded), "acknowledged — stays down")
        XCTAssertTrue(shows(.unreliable, false, .degraded), "worse than acknowledged — comes back")
        XCTAssertTrue(shows(.suspect, false, .unreliable), "and worse again")
        XCTAssertFalse(shows(.degraded, false, .suspect), "improved below what was acknowledged")
        // Interference is its own verdict and dismissible in one go; the model clears the
        // acknowledgement as soon as the state falls back under `.degraded`.
        XCTAssertTrue(shows(.nominal, true, nil))
        XCTAssertFalse(shows(.nominal, true, .degraded))
    }

    // MARK: - Spoofing tells

    /// The classic tell: the position teleports while the velocity solution stays smooth and slow.
    func testPositionJumpWithSmoothVelocityIsSuspect() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 30))
        // 30 m/s allows ~90 m + slack; 300 m in 1 s is still under the envelope ceiling, so this
        // isolates the jump detector from the impossible-speed one.
        let jumped = m.ingest(fix(dt: 1, metresNorth: 300, speedMps: 30))
        XCTAssertEqual(jumped.state, .suspect)
        XCTAssertEqual(jumped.reasons, [.positionJump])
        XCTAssertTrue(jumped.reasons.contains(.positionJump))
        // A suspect fix is the one case that may not anchor a clearance — but it is STILL DRAWN, in
        // red, inside its accuracy ring. The pilot needs to see where the receiver claims to be.
        XCTAssertFalse(jumped.isPositionProbablyReal)
        XCTAssertFalse(jumped.isTrustedForGuidance)
    }

    func testHonestMotionAtSpeedIsNotAJump() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 100))
        let moved = m.ingest(fix(dt: 1, metresNorth: 100, speedMps: 100))   // exactly the reported travel
        XCTAssertEqual(moved.state, .nominal, "real motion matching the reported speed must not trip")
    }

    func testNoisyPositionAtPoorAccuracyIsNotAJump() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, accuracy: 80, speedMps: 0))
        let noisy = m.ingest(fix(dt: 1, metresNorth: 150, accuracy: 80, speedMps: 0))
        XCTAssertFalse(noisy.reasons.contains(.positionJump),
                       "both accuracy radii are subtracted out — edge-of-fix noise is not a spoof")
    }

    func testImpossibleSpeedIsSuspect() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 400))
        let warped = m.ingest(fix(dt: 1, metresNorth: 900, speedMps: 400))  // ~1750 kt implied
        XCTAssertTrue(warped.reasons.contains(.impossibleSpeed))
        XCTAssertEqual(warped.state, .suspect)
    }

    func testImpossibleAccelerationIsSuspect() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, speedMps: 10))
        let slammed = m.ingest(fix(dt: 1, metresNorth: 10, speedMps: 90))   // 80 m/s² ≈ 8 g
        XCTAssertTrue(slammed.reasons.contains(.impossibleAcceleration))
    }

    func testSimulatedSourceIsSuspect() {
        let m = GPSIntegrityMonitor()
        let sim = m.ingest(fix(dt: 0, speedMps: 50, simulated: true))
        XCTAssertEqual(sim.state, .suspect)
        XCTAssertEqual(sim.reasons, [.simulatedSource])
    }

    /// A backgrounded app resuming produces a big position delta over a big time gap. That is a gap,
    /// not a teleport, and reporting it would cry wolf on every return to the app.
    func testLongGapIsNotAJump() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 60))
        let resumed = m.ingest(fix(dt: 600, metresNorth: 300_000, speedMps: 60))
        XCTAssertFalse(resumed.reasons.contains(.positionJump))
        XCTAssertFalse(resumed.reasons.contains(.impossibleSpeed))
    }

    func testOutOfOrderFixIsDropped() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 10, metresNorth: 0, speedMps: 50))
        let stale = m.ingest(fix(dt: 2, metresNorth: 5000, speedMps: 50))   // a replayed cached location
        XCTAssertEqual(stale.state, .nominal, "a cached out-of-order fix must not be diffed as motion")
    }

    // MARK: - Suspect latch

    func testSuspectIsLatchedThenClears() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 30))
        XCTAssertEqual(m.ingest(fix(dt: 1, metresNorth: 400, speedMps: 30)).state, .suspect)
        // A spoof that settles into a smooth false track would otherwise clear itself one fix later.
        XCTAssertEqual(m.ingest(fix(dt: 2, metresNorth: 430, speedMps: 30)).state, .suspect,
                       "suspect must hold, not blink off on the next consistent fix")
        XCTAssertEqual(m.ingest(fix(dt: 120, metresNorth: 430, speedMps: 0)).state, .nominal,
                       "the latch must expire so it can't stick for the rest of the flight")
    }

    // MARK: - Course / speed usability

    func testCourseUnusableBelowTaxiSpeed() {
        let m = GPSIntegrityMonitor()
        let slow = m.ingest(fix(dt: 0, speedMps: 0.4))
        XCTAssertFalse(slow.courseUsable, "GPS course at a crawl is noise")
        XCTAssertTrue(slow.speedUsable)
        // Separate monitor: 0.4 → 30 m/s in one second is ~3 g and would (correctly) trip the
        // acceleration detector, which is a different test's subject.
        let moving = GPSIntegrityMonitor()
        XCTAssertTrue(moving.ingest(fix(dt: 0, speedMps: 30)).courseUsable)
    }

    func testWideCourseAndSpeedSigmaAreUnusable() {
        let m = GPSIntegrityMonitor()
        let a = m.ingest(fix(dt: 0, speedMps: 50, speedAccuracyMps: 9, courseAccuracyDeg: 40))
        XCTAssertFalse(a.courseUsable)
        XCTAssertFalse(a.speedUsable)
    }

    func testUnreliableStateMakesCourseAndSpeedUnusable() {
        let m = GPSIntegrityMonitor()
        // Three to reach `.unreliable` — and the first two are the point of the confirmation run:
        // course and speed stay usable through a momentary dip, so track-up and the wind correction
        // do not drop out every time the receiver blinks.
        let dip = m.ingest(fix(dt: 0, accuracy: 400, speedMps: 50))
        XCTAssertTrue(dip.courseUsable, "a single bad reading must not disable track-up")
        XCTAssertTrue(dip.speedUsable)
        m.ingest(fix(dt: 1, accuracy: 400, speedMps: 50))
        let blown = m.ingest(fix(dt: 2, accuracy: 400, speedMps: 50))
        XCTAssertEqual(blown.state, .unreliable)
        XCTAssertFalse(blown.courseUsable)
        XCTAssertFalse(blown.speedUsable)
        XCTAssertNil(blown.verticalSpeedFpm)
    }

    // MARK: - Derived VSI

    func testVerticalSpeedNeedsTheBaseline() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, speedMps: 50, altitudeM: 300))
        XCTAssertNil(m.ingest(fix(dt: 1, metresNorth: 50, speedMps: 50, altitudeM: 300)).verticalSpeedFpm,
                     "differencing adjacent 1 Hz fixes would be pure noise")
        // The baseline is the NEAREST fix at least 3 s old — the dt=1 one, not dt=0.
        // +30.48 m (100 ft) over that 5 s span = 1200 fpm.
        let vs = m.ingest(fix(dt: 6, metresNorth: 300, speedMps: 50, altitudeM: 330.48)).verticalSpeedFpm
        XCTAssertEqual(try XCTUnwrap(vs), 1200, accuracy: 1)
    }

    func testVerticalSpeedIsNilWithoutAltitude() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, speedMps: 50))
        XCTAssertNil(m.ingest(fix(dt: 6, metresNorth: 300, speedMps: 50)).verticalSpeedFpm)
    }

    // MARK: - Bounds and events

    func testHistoryAndEventLogStayBounded() {
        let m = GPSIntegrityMonitor()
        for i in 0..<400 {                                   // bounded loop (rule 2)
            let bad = i % 2 == 0
            m.ingest(fix(dt: Double(i), metresNorth: Double(i) * 50,
                         accuracy: bad ? 300 : 4, speedMps: 50))
        }
        XCTAssertLessThanOrEqual(m.events.count, GPSIntegrityMonitor.maxEvents)
        XCTAssertGreaterThan(m.events.count, 0, "state changes must be recorded")
    }

    func testEventsRecordTransitionsOnly() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, accuracy: 4, speedMps: 50))
        m.ingest(fix(dt: 1, accuracy: 4, speedMps: 50))
        XCTAssertEqual(m.events.count, 1, "unknown → nominal only; a steady state logs nothing further")
        m.ingest(fix(dt: 2, accuracy: 60, speedMps: 50))
        XCTAssertEqual(m.events.count, 2)
        XCTAssertEqual(m.events.last?.from, .nominal)
        XCTAssertEqual(m.events.last?.to, .degraded)
        XCTAssertEqual(m.events.last?.reasons, [.accuracyDegraded])
    }

    func testResetClearsEverything() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, accuracy: 300, speedMps: 50))
        m.reset()
        XCTAssertEqual(m.assessment.state, .unknown)
        XCTAssertTrue(m.events.isEmpty)
        XCTAssertNil(m.lastFix)
    }

    // MARK: - Fix widening

    func testGeoidUndulationAndUnitConversions() {
        var f = DeviceFix(coord: home, altitudeMSLm: 300, groundSpeedMps: 51.44,
                          courseDeg: nil, horizontalAccuracyM: 5)
        f.timestamp = t0
        f.altitudeEllipsoidalM = 292.5
        XCTAssertEqual(try XCTUnwrap(f.altitudeMSLft), 984.25, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(f.groundSpeedKt), 100, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(f.geoidUndulationFt), -24.6, accuracy: 0.2,
                       "ellipsoidal − MSL is why GPS and baro altitude disagree")
    }

    func testReasonTextIsWorstFirst() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, accuracy: 45, speedMps: 30))
        let both = m.ingest(fix(dt: 1, metresNorth: 300, accuracy: 45, speedMps: 30))
        XCTAssertEqual(both.reasons, [.positionJump, .accuracyDegraded])
        XCTAssertEqual(both.reasons.first, .positionJump, "the worst reason leads the banner")
        XCTAssertTrue(both.reasonText.hasPrefix("position jump"))
    }
}
