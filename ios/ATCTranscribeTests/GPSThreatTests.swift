import XCTest
@testable import ATCTranscribe

/// GPS threat classification: telling JAMMING (the signal is being denied) apart from SPOOFING (the
/// signal is being faked) on top of `GPSIntegrityMonitor`'s "the fix is bad" verdict.
///
/// The cases that matter most here are the ones an accuracy threshold cannot reach: a position jump
/// reported with a TIGHT accuracy (spoofing, invisible to every accuracy check in the app), and a blown
/// accuracy under a sky the almanac says is excellent (jamming, indistinguishable from an urban canyon
/// without that independent prediction). Equally important are the refusals — poor predicted geometry
/// and a missing almanac must both come back "degraded", never a guess at interference.
///
/// The classifier is pure and `now` is injected, so every case below is a table lookup: no receiver, no
/// almanac file, no clock. Expected errors are computed by hand from HDOP × UERE × sigma rather than
/// from the implementation.
final class GPSThreatTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = Coord(lat: 33.0, lon: -97.0)
    private let cfg = GPSThreatClassifier.Config()

    // MARK: - Builders

    /// A predicted sky. Filled in through `GPSAlmanac`'s shared `PredictedDOP` so there is exactly one place to
    /// follow if that type moves; the unused components are made physically consistent
    /// (GDOP² = PDOP² + TDOP², VDOP² = PDOP² − HDOP²) rather than arbitrary.
    private func sky(pdop: Double, hdop: Double) -> PredictedDOP {
        PredictedDOP(gdop: (pdop * pdop + 1.0).squareRoot(), pdop: pdop, hdop: hdop,
            vdop: max(pdop * pdop - hdop * hdop, 0).squareRoot(), tdop: 1.0)
    }

    /// An integrity verdict as the monitor would have published it.
    private func integrity(_ state: GPSIntegrityState, _ reasons: [GPSIntegrityReason],
                           accuracy: Double?) -> GPSIntegrityAssessment {
        GPSIntegrityAssessment(state: state, reasons: reasons, at: t0, horizontalAccuracyM: accuracy)
    }

    /// A device fix, for the end-to-end cases that drive a real `GPSIntegrityMonitor`.
    private func fix(dt: TimeInterval, metresNorth: Double = 0, accuracy: Double = 5,
                     speedMps: Double? = 30) -> DeviceFix {
        var f = DeviceFix(coord: Coord(lat: home.lat + metresNorth / 111_320.0, lon: home.lon),
                          altitudeMSLm: nil, groundSpeedMps: speedMps, courseDeg: 0,
                          horizontalAccuracyM: accuracy)
        f.timestamp = t0.addingTimeInterval(dt)
        return f
    }

    private func classify(_ integrity: GPSIntegrityAssessment, pdop: Double? = nil,
                          hdop: Double? = nil, sats: Int? = nil) -> GPSThreatAssessment {
        let dop = pdop.map { sky(pdop: $0, hdop: hdop ?? $0 / 1.6) }
        return GPSThreatClassifier.classify(integrity: integrity, predictedDOP: dop,
                                            satellitesAboveMask: sats, now: t0)
    }

    // MARK: - The threat ladder

    func testSeverityOrderingPutsSpoofingAboveJamming() {
        XCTAssertLessThan(GPSThreat.none, .degraded)
        XCTAssertLessThan(GPSThreat.degraded, .jamming)
        XCTAssertLessThan(GPSThreat.jamming, .spoofing,
                          "a spoofer commonly jams first — when both fit, spoofing is the verdict that survives")
        XCTAssertEqual(GPSThreat.allCases.max(), .spoofing)
        XCTAssertTrue(GPSThreat.spoofing.isInterference && GPSThreat.jamming.isInterference)
        XCTAssertFalse(GPSThreat.degraded.isInterference, "a coarse fix is not an attack")
        XCTAssertTrue(GPSThreat.degraded.requiresCrossCheck)
        XCTAssertFalse(GPSThreat.none.requiresCrossCheck)
    }

    func testConfidenceIsOrdered() {
        XCTAssertLessThan(GPSThreatConfidence.low, .medium)
        XCTAssertLessThan(GPSThreatConfidence.medium, .high)
    }

    // MARK: - Jamming: bad measurement under a good sky

    /// The canonical denial signature: the almanac says PDOP 1.8 with eleven satellites up, and
    /// CoreLocation is reporting ±200 m. Predicted 1-sigma error is 1.0 HDOP × 8 m = 8 m, so 200 m is
    /// twenty-five sigma out — geometry has been eliminated, something is denying the signal.
    func testGoodGeometryWithBlownAccuracyIsJamming() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200),
                         pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .jamming)
        XCTAssertEqual(a.reasons, [.accuracyUnexplainedByGeometry])
        XCTAssertEqual(a.geometry, .good)
        XCTAssertEqual(a.confidence, .high,
                       "two denial signals plus an excellent sky is three independent agreements")
        XCTAssertEqual(a.predictedPDOP, 1.8)
        XCTAssertEqual(a.at, t0, "the classifier must stamp the injected time, not the clock")
    }

    /// Jamming does not have to blow the accuracy out — the commonest presentation on iOS is that the
    /// receiver simply stops delivering. A lost lock under a clean constellation is the same accusation.
    func testGoodGeometryWithStaleFixIsJamming() {
        let a = classify(integrity(.degraded, [.fixStale], accuracy: 6), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .jamming)
        XCTAssertEqual(a.reasons, [.fixLostUnexplainedByGeometry])
        XCTAssertFalse(a.advisory.isEmpty)
    }

    /// A satellite count with no PredictedDOP is weaker evidence — the satellites could be clustered — so the
    /// bar is higher (eight, not five), but eleven satellites overhead still rules geometry out.
    func testSatelliteCountAloneCanEstablishGoodGeometry() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200), sats: 11)
        XCTAssertEqual(a.threat, .jamming)
        XCTAssertEqual(a.geometry, .good)
        XCTAssertNil(a.predictedPDOP)
        XCTAssertEqual(a.confidence, .medium,
                       "without a PredictedDOP the sky cannot be called excellent, so this stops short of high")
    }

    func testSixSatellitesWithoutDOPIsNotEnoughToAccuse() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200), sats: 6)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.geometry, .fair)
        XCTAssertEqual(a.reasons, [.geometryMarginal])
    }

    // MARK: - Spoofing: a confident lie

    /// THE case an accuracy-only check misses. The position teleported while the receiver's own velocity
    /// stayed smooth, and it reported ±5 m doing it — a spoofer transmits a strong, clean signal, so the
    /// fix looks better than usual at the exact moment it becomes worthless.
    func testPositionJumpWithGoodAccuracyIsSpoofing() {
        let a = classify(integrity(.suspect, [.positionJump], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .spoofing)
        XCTAssertEqual(a.reasons, [.velocityDisagreesWithPosition, .confidentButInconsistent])
        XCTAssertEqual(a.confidence, .medium, "one kinematic tell is a strong hint, not a proof")
        XCTAssertTrue(a.warrantsAlert)
    }

    func testSimulatedSourceIsSpoofingAtHighConfidence() {
        let a = classify(integrity(.suspect, [.simulatedSource], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .spoofing)
        XCTAssertTrue(a.reasons.contains(.softwareGeneratedFix))
        XCTAssertEqual(a.confidence, .high,
                       "the OS stating the fix is software-generated is not circumstantial evidence")
    }

    func testImpossibleKinematicsIsSpoofing() {
        let speed = classify(integrity(.suspect, [.impossibleSpeed], accuracy: 8), pdop: 2.0, sats: 9)
        XCTAssertEqual(speed.threat, .spoofing)
        XCTAssertTrue(speed.reasons.contains(.impossibleKinematics))
        let accel = classify(integrity(.suspect, [.impossibleAcceleration], accuracy: 8), pdop: 2.0, sats: 9)
        XCTAssertEqual(accel.threat, .spoofing)
        XCTAssertTrue(accel.reasons.contains(.impossibleKinematics))
    }

    /// A spoofer that also jams — the normal attack sequence, since the lock has to be broken before it
    /// can be captured. The fix is both self-inconsistent AND blown out under a good sky; the verdict
    /// must be the one with the bigger cockpit action attached.
    func testSpoofingOutranksJammingWhenBothFit() {
        let a = classify(integrity(.suspect, [.positionJump, .accuracyUnusable], accuracy: 250),
                         pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .spoofing)
        XCTAssertTrue(a.reasons.contains(.velocityDisagreesWithPosition))
        XCTAssertFalse(a.reasons.contains(.accuracyUnexplainedByGeometry),
                       "the spoofing verdict owns the reason list — a mixed banner would read as two faults")
        XCTAssertFalse(a.reasons.contains(.confidentButInconsistent),
                       "250 m is not a confident fix, so that corroborator must not be claimed")
    }

    /// Defensive: a `suspect` state that arrives without one of its four tells must still come back
    /// spoofing. Silently downgrading a spoof because the upstream reason list changed shape is the one
    /// failure mode this classifier cannot have — so it degrades to low confidence, not to `degraded`.
    func testSuspectWithoutAnAttributableTellStillReportsSpoofing() {
        let a = classify(integrity(.suspect, [], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .spoofing)
        XCTAssertTrue(a.reasons.contains(.selfInconsistentFix))
        XCTAssertEqual(a.confidence, .low)
    }

    // MARK: - Refusals: when interference must NOT be claimed

    /// An urban canyon or a high-PDOP window. The sky itself accounts for the error, so this is ordinary
    /// degradation and saying otherwise would train the pilot to ignore the banner.
    func testPoorGeometryWithPoorAccuracyIsDegradedNotJamming() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 120),
                         pdop: 12.0, hdop: 8.0, sats: 6)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.geometry, .poor)
        XCTAssertEqual(a.reasons, [.geometryExplainsError])
        XCTAssertEqual(a.confidence, .high, "a PDOP of 12 is a positive explanation, not a shrug")
    }

    /// A PDOP above the poor band can never be called jamming however far the measurement has blown
    /// out — the hard gate that keeps a parking garage from being reported as an attack.
    func testPoorGeometryNeverYieldsJammingEvenAtAbsurdError() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 3000),
                         pdop: 9.0, hdop: 7.0, sats: 5)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertNotEqual(a.threat, .jamming)
    }

    /// Fewer than five satellites is a solution with no redundancy at all — poor geometry regardless of
    /// how flattering the reported PredictedDOP is.
    func testTooFewSatellitesIsPoorGeometryDespiteAGoodDOP() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200),
                         pdop: 1.2, hdop: 0.9, sats: 4)
        XCTAssertEqual(a.geometry, .poor)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.confidence, .medium, "a bad count explains it, but not as loudly as a PDOP of 12")
    }

    /// The honest fallback. With no almanac there is no independent prediction, so jamming and an
    /// ordinary dip produce identical evidence — the classifier says so instead of guessing.
    func testNilGeometryWithBlownAccuracyIsDegradedNotJamming() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200))
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.geometry, .unknown)
        XCTAssertEqual(a.reasons, [.geometryUnknown])
        XCTAssertEqual(a.confidence, .low, "no basis to attribute must never read as an all-clear")
    }

    func testNilGeometryWithAStaleFixIsAlsoDegraded() {
        let a = classify(integrity(.unreliable, [.fixStale], accuracy: 6))
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.reasons, [.geometryUnknown])
    }

    /// A merely-fair sky (PDOP between the good and poor bands) is not a strong enough control to accuse
    /// anyone, so the verdict stops at degraded and says the geometry was marginal.
    func testMarginalGeometryIsDegradedAtLowConfidence() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200),
                         pdop: 4.5, hdop: 3.0, sats: 7)
        XCTAssertEqual(a.geometry, .fair)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.reasons, [.geometryMarginal])
        XCTAssertEqual(a.confidence, .low)
    }

    /// Good sky, but the error is still inside what that sky predicts: HDOP 2.9 × 8 m UERE × 3 sigma =
    /// 69.6 m, and the receiver is reporting 45 m. Geometry explains it after all — no accusation.
    func testGoodSkyStillDeclinesWhenTheErrorFitsThePrediction() {
        let a = classify(integrity(.degraded, [.accuracyDegraded], accuracy: 45),
                         pdop: 2.9, hdop: 2.9, sats: 9)
        XCTAssertEqual(a.geometry, .good)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertEqual(a.reasons, [.geometryExplainsError])
    }

    // MARK: - The predicted-error math

    /// The ratio test against a hand-computed value: HDOP 1.0 × 8 m UERE × 3 sigma = 24 m exactly.
    /// Below that, geometry accounts for the error; above it, it does not.
    func testGeometryExplainsAtThreeSigmaOfHdopTimesUere() {
        let clean = sky(pdop: 1.5, hdop: 1.0)
        XCTAssertTrue(GPSThreatClassifier.geometryExplains(accuracyM: 23.9, dop: clean, config: cfg))
        XCTAssertFalse(GPSThreatClassifier.geometryExplains(accuracyM: 24.1, dop: clean, config: cfg))
        // HDOP 5 predicts 40 m 1-sigma, so 3 sigma is 120 m.
        let poor = sky(pdop: 6.0, hdop: 5.0)
        XCTAssertTrue(GPSThreatClassifier.geometryExplains(accuracyM: 119.0, dop: poor, config: cfg))
        XCTAssertFalse(GPSThreatClassifier.geometryExplains(accuracyM: 121.0, dop: poor, config: cfg))
    }

    /// Absence of a prediction is never an answer to "did geometry cause this", so the test refuses
    /// rather than defaulting either way.
    func testGeometryExplainsIsFalseWithoutSomethingToCompare() {
        XCTAssertFalse(GPSThreatClassifier.geometryExplains(accuracyM: 200, dop: nil, config: cfg))
        XCTAssertFalse(GPSThreatClassifier.geometryExplains(accuracyM: nil,
                                                            dop: sky(pdop: 1.5, hdop: 1.0), config: cfg))
    }

    func testGeometryVerdictBands() {
        XCTAssertEqual(GPSThreatClassifier.geometryVerdict(dop: nil, satellitesAboveMask: nil, config: cfg),
                       .unknown)
        XCTAssertEqual(GPSThreatClassifier.geometryVerdict(dop: sky(pdop: 3.0, hdop: 2.0),
                                                           satellitesAboveMask: 9, config: cfg), .good)
        XCTAssertEqual(GPSThreatClassifier.geometryVerdict(dop: sky(pdop: 3.1, hdop: 2.0),
                                                           satellitesAboveMask: 9, config: cfg), .fair)
        XCTAssertEqual(GPSThreatClassifier.geometryVerdict(dop: sky(pdop: 6.1, hdop: 4.0),
                                                           satellitesAboveMask: 9, config: cfg), .poor)
    }

    /// A singular constellation makes the PredictedDOP math blow up. The safe reading of "the geometry solver
    /// fell over" is "do not accuse anyone", not a crash and not a jamming call.
    func testDegenerateDOPIsTreatedAsPoorGeometry() {
        let broken = sky(pdop: .infinity, hdop: .infinity)
        XCTAssertEqual(GPSThreatClassifier.geometryVerdict(dop: broken, satellitesAboveMask: 11,
                                                           config: cfg), .poor)
        let a = GPSThreatClassifier.classify(integrity: integrity(.unreliable, [.accuracyUnusable],
                                                                  accuracy: 200),
                                             predictedDOP: broken, satellitesAboveMask: 11, now: t0)
        XCTAssertEqual(a.threat, .degraded)
    }

    // MARK: - Nothing wrong

    func testNominalIntegrityIsNoThreat() {
        let a = classify(integrity(.nominal, [], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(a.threat, .none)
        XCTAssertTrue(a.reasons.isEmpty)
        XCTAssertEqual(a.confidence, .high)
        XCTAssertEqual(a.advisory, GPSThreatClassifier.nominalAdvisory)
        XCTAssertFalse(a.warrantsAlert)
    }

    /// Never having had a fix is not the same as having lost one — and silence is not evidence of health,
    /// so the confidence is low even though the verdict is `none`.
    func testUnknownIntegrityIsNoThreatAtLowConfidence() {
        let a = classify(integrity(.unknown, [], accuracy: nil))
        XCTAssertEqual(a.threat, .none)
        XCTAssertEqual(a.confidence, .low)
        XCTAssertTrue(a.advisory.contains("No GPS fix"))
    }

    // MARK: - Confidence escalation

    func testSpoofingConfidenceEscalatesWithTheNumberOfTells() {
        let one = classify(integrity(.suspect, [.positionJump], accuracy: 60), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(one.confidence, .medium)
        let two = classify(integrity(.suspect, [.positionJump, .impossibleSpeed], accuracy: 60),
                           pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(two.confidence, .high, "two independent tells agreeing is no longer a hint")
        XCTAssertGreaterThan(two.confidence, one.confidence)
    }

    func testJammingConfidenceEscalatesWithTheEvidence() {
        // 45 m is ordinary fused-location noise on an iPhone, not interference. This case used to be
        // asserted AS jamming, which pinned the false positive in place; the absolute floor
        // (`Config.jammingFloorM`) is what stops the app shouting at a normal ramp.
        let soft = classify(integrity(.degraded, [.accuracyDegraded], accuracy: 45),
                            pdop: 2.8, hdop: 1.0, sats: 6)
        XCTAssertEqual(soft.threat, .degraded, "45 m is receiver noise, not an attack")
        XCTAssertLessThan(soft.confidence, .high, "a single soft signal must never reach high")
        // Same sky, but the fix is now unusable rather than merely coarse.
        let harder = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200),
                              pdop: 2.8, hdop: 1.0, sats: 6)
        XCTAssertEqual(harder.confidence, .medium)
        // Both denial channels at once, under an excellent sky.
        let loudest = classify(integrity(.unreliable, [.accuracyUnusable, .fixStale], accuracy: 200),
                               pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertEqual(loudest.reasons,
                       [.accuracyUnexplainedByGeometry, .fixLostUnexplainedByGeometry])
        XCTAssertEqual(loudest.confidence, .high)
        XCTAssertGreaterThan(loudest.confidence, soft.confidence)
    }

    // MARK: - Cockpit copy

    /// Every verdict has to hand the pilot an action. A banner that only describes the failure makes the
    /// pilot do the reasoning at the worst possible moment.
    func testEveryThreatProducesANonEmptyImperativeAdvisory() {
        let cases: [GPSThreatAssessment] = [
            classify(integrity(.nominal, [], accuracy: 5)),
            classify(integrity(.unknown, [], accuracy: nil)),
            classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200)),
            classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200), pdop: 1.8, hdop: 1.0, sats: 11),
            classify(integrity(.degraded, [.accuracyDegraded], accuracy: 45), pdop: 2.8, hdop: 1.0, sats: 6),
            classify(integrity(.suspect, [.positionJump], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        ]
        XCTAssertEqual(cases.count, 6)
        for a in cases {                                  // bounded by the literal above (rule 2)
            XCTAssertFalse(a.advisory.isEmpty, "\(a.threat) produced no advisory")
            XCTAssertFalse(a.threat.label.isEmpty)
        }
        XCTAssertEqual(Set(GPSThreat.allCases.map(\.label)).count, GPSThreat.allCases.count,
                       "each verdict needs its own headline")
    }

    func testSpoofingAdvisoryForbidsNavigatingByGPS() {
        let a = classify(integrity(.suspect, [.positionJump], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertTrue(a.advisory.contains("Do not navigate by GPS"))
        XCTAssertTrue(a.advisory.contains("ATC"), "a spoof is worth a report")
    }

    func testJammingAdvisoryTellsThePilotToUseNavaidsAndTellATC() {
        let a = classify(integrity(.unreliable, [.accuracyUnusable], accuracy: 200),
                         pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertTrue(a.advisory.lowercased().contains("navaid"))
        XCTAssertTrue(a.advisory.contains("ATC"))
    }

    /// An accuracy dip is routine. The degraded copy must stay flat — no interference language, no
    /// prohibition — or the banner becomes noise the pilot learns to swipe away.
    func testDegradedAdvisoryIsNotAlarmist() {
        let a = classify(integrity(.degraded, [.accuracyDegraded], accuracy: 45),
                         pdop: 12.0, hdop: 8.0, sats: 6)
        XCTAssertEqual(a.threat, .degraded)
        XCTAssertFalse(a.advisory.lowercased().contains("interference"))
        XCTAssertFalse(a.advisory.lowercased().contains("spoof"))
        XCTAssertFalse(a.advisory.contains("Do not"))
        XCTAssertTrue(a.advisory.lowercased().contains("cross-check"))
    }

    func testReasonTextJoinsTheEvidence() {
        let a = classify(integrity(.suspect, [.positionJump], accuracy: 5), pdop: 1.8, hdop: 1.0, sats: 11)
        XCTAssertTrue(a.reasonText.hasPrefix("position contradicts velocity"))
        XCTAssertTrue(a.reasonText.contains("·"))
    }

    // MARK: - End to end through the real monitor

    /// Guards the coupling: the classifier reads `GPSIntegrityReason` values the monitor actually emits,
    /// not values a test invented. A blown-accuracy fix under a clean sky must come out as jamming.
    func testBlownAccuracyFromTheRealMonitorClassifiesAsJamming() {
        let m = GPSIntegrityMonitor()
        let integrity = m.ingest(fix(dt: 0, accuracy: 250, speedMps: 60))
        XCTAssertEqual(integrity.state, .unreliable)
        let a = GPSThreatClassifier.classify(integrity: integrity, predictedDOP: sky(pdop: 1.8, hdop: 1.0),
                                             satellitesAboveMask: 11, now: t0)
        XCTAssertEqual(a.threat, .jamming)
        XCTAssertEqual(a.confidence, .high)
    }

    /// The same coupling for the spoofing path: a real position jump against a smooth velocity, reported
    /// with a 5 m accuracy, must come out as spoofing rather than sailing through as a healthy fix.
    func testPositionJumpFromTheRealMonitorClassifiesAsSpoofing() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 30))
        let jumped = m.ingest(fix(dt: 1, metresNorth: 300, speedMps: 30))
        XCTAssertEqual(jumped.state, .suspect)
        let a = GPSThreatClassifier.classify(integrity: jumped, predictedDOP: sky(pdop: 1.8, hdop: 1.0),
                                             satellitesAboveMask: 11, now: t0.addingTimeInterval(1))
        XCTAssertEqual(a.threat, .spoofing)
        XCTAssertTrue(a.reasons.contains(.velocityDisagreesWithPosition))
        XCTAssertTrue(a.reasons.contains(.confidentButInconsistent),
                      "the tight accuracy alongside the inconsistency IS the spoofing signature")
    }

    /// A healthy fix under a good sky must stay silent all the way through both layers — the false
    /// positive that would cost the feature its credibility.
    func testHealthyFixFromTheRealMonitorRaisesNothing() {
        let m = GPSIntegrityMonitor()
        m.ingest(fix(dt: 0, metresNorth: 0, speedMps: 100))
        let ok = m.ingest(fix(dt: 1, metresNorth: 100, speedMps: 100))
        let a = GPSThreatClassifier.classify(integrity: ok, predictedDOP: sky(pdop: 1.8, hdop: 1.0),
                                             satellitesAboveMask: 11, now: t0.addingTimeInterval(1))
        XCTAssertEqual(a.threat, .none)
        XCTAssertFalse(a.warrantsAlert)
    }
}

/// Regression tests for two false-positive defects in the interference classifier.
///
/// Both were cases where the app shouted "GPS interference" at ordinary receiver behaviour. A safety
/// warning that fires on a normal urban ramp is not a conservative warning — it is one the pilot learns
/// to ignore, which is strictly worse than not having it.
final class GPSThreatFalsePositiveTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func integrity(accuracy: Double?, reasons: [GPSIntegrityReason],
                           state: GPSIntegrityState = .degraded) -> GPSIntegrityAssessment {
        var a = GPSIntegrityAssessment()
        a.state = state
        a.reasons = reasons
        a.horizontalAccuracyM = accuracy
        a.at = now
        return a
    }

    private func goodSky() -> PredictedDOP {
        PredictedDOP(gdop: 2.1, pdop: 1.8, hdop: 1.0, vdop: 1.5, tdop: 1.0)
    }

    /// A 31 m fix under a clean sky is an iPhone reporting a fused Wi-Fi/cell/GNSS radius outdoors. It
    /// is not an attack. Previously this produced "jamming, medium confidence" because the ratio
    /// ceiling (HDOP 1.0 x 8 x 3 = 24 m) sat below the monitor's own 30 m caution line.
    func testOrdinaryThirtyMetreAccuracyIsNotJamming() {
        let a = GPSThreatClassifier.classify(integrity: integrity(accuracy: 31, reasons: [.accuracyDegraded]),
                                             predictedDOP: goodSky(), satellitesAboveMask: 11, now: now)
        XCTAssertNotEqual(a.threat, .jamming, "31 m under an open sky is ordinary, not interference")
        XCTAssertFalse(a.warrantsAlert)
    }

    /// The quantised 65 m an iPhone commonly reports outdoors — same story, louder.
    func testQuantisedSixtyFiveMetreAccuracyIsNotJamming() {
        let a = GPSThreatClassifier.classify(integrity: integrity(accuracy: 65, reasons: [.accuracyDegraded]),
                                             predictedDOP: goodSky(), satellitesAboveMask: 10, now: now)
        XCTAssertNotEqual(a.threat, .jamming)
    }

    /// Past the point the integrity monitor itself stops trusting the fix, with a sky that cannot
    /// explain it, interference IS the honest reading. This is the other side of the floor: the fix
    /// must not silence real detection.
    func testTrulyBlownAccuracyUnderGoodSkyStillReadsAsJamming() {
        let a = GPSThreatClassifier.classify(integrity: integrity(accuracy: 250,
                                                                  reasons: [.accuracyUnusable],
                                                                  state: .unreliable),
                                             predictedDOP: goodSky(), satellitesAboveMask: 11, now: now)
        XCTAssertEqual(a.threat, .jamming, "250 m under an 11-satellite PDOP-1.8 sky is not geometry")
        XCTAssertFalse(a.advisory.isEmpty)
    }

    /// A MISSING accuracy is missing evidence, not evidence of denial. Previously nil accuracy fell
    /// through the "geometry does not explain it" branch and produced a jamming verdict out of nothing.
    func testMissingAccuracyIsNotEvidenceOfJamming() {
        let a = GPSThreatClassifier.classify(integrity: integrity(accuracy: nil, reasons: [.accuracyDegraded]),
                                             predictedDOP: goodSky(), satellitesAboveMask: 11, now: now)
        XCTAssertNotEqual(a.threat, .jamming, "absent data cannot be an accusation")
    }

    /// Spoofing evidence must still outrank everything, and must not be gated on the accuracy floor —
    /// a spoofer characteristically reports a CONFIDENT, wrong position.
    func testSpoofingStillWinsAtGoodAccuracy() {
        let a = GPSThreatClassifier.classify(integrity: integrity(accuracy: 4, reasons: [.positionJump],
                                                                  state: .suspect),
                                             predictedDOP: goodSky(), satellitesAboveMask: 11, now: now)
        XCTAssertEqual(a.threat, .spoofing, "a confident wrong position is the spoofing signature")
    }
}

/// Regression tests for red-hat audit findings: the Stratux Int() crash, the terrain header trap, and
/// the almanac-staleness gate that the classifier documented but never actually enforced.
final class GPSAuditRegressionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Stratux value sanitizing (a crash fix)

    /// A finite-but-absurd altitude from /getSituation (1e19 decodes cleanly, then traps Int(1e19)) must
    /// be dropped at the model boundary, not carried through to crash the app-wide GPS bar.
    func testStratuxAbsurdAltitudeIsDroppedNotCrashed() {
        let s = StratuxSituation(lat: 40, lon: -74, fixQuality: 1, satellites: 9,
                                 altMSLft: 1e19, groundSpeedKt: 1e19, trueCourse: 1e30).gps
        XCTAssertNil(s.altMSLft, "an out-of-range altitude must sanitize to nil, never reach Int()")
        XCTAssertNil(s.groundSpeedKt)
        XCTAssertNil(s.trackDeg)
        XCTAssertTrue(s.hasFix, "a bad altitude must not invalidate a real position fix")
    }

    func testStratuxSaneValuesSurvive() {
        let s = StratuxSituation(lat: 40, lon: -74, fixQuality: 2, satellites: 11,
                                 altMSLft: 5500, groundSpeedKt: 120, trueCourse: 270).gps
        XCTAssertEqual(s.altMSLft, 5500)
        XCTAssertEqual(s.groundSpeedKt, 120)
        XCTAssertEqual(s.trackDeg, 270)
    }

    /// The display helper itself must never trap, whatever reaches it.
    func testGPSBarIntTextNeverTraps() {
        XCTAssertEqual(GPSBottomBar.intText(1e19, "ft"), "—")
        XCTAssertEqual(GPSBottomBar.intText(.nan, "ft"), "—")
        XCTAssertEqual(GPSBottomBar.intText(.infinity, "kt"), "—")
        XCTAssertEqual(GPSBottomBar.intText(nil, "ft"), "—")
        XCTAssertEqual(GPSBottomBar.intText(5500.4, "ft"), "5500 ft")
    }

    // MARK: - Terrain header overflow (a crash fix)

    /// A corrupt header with a huge cellsPerDegree must be refused, not trap in Int((span)*cpd).
    func testTerrainHeaderHugeCellsPerDegreeIsRejectedNotCrashed() {
        let h = TerrainGridHeader(version: 1, latMax: 50, latMin: 24, lonMin: -125, lonMax: -66,
                                  rows: 1560, cols: 3540, cellsPerDegree: 1e300, noData: -32768)
        XCTAssertFalse(h.isSelfConsistent, "an overflowing cellsPerDegree must be refused before Int()")
    }

    func testTerrainRealHeaderStillValid() {
        let h = TerrainGridHeader(version: 1, latMax: 50, latMin: 24, lonMin: -125, lonMax: -66,
                                  rows: 1560, cols: 3540, cellsPerDegree: 60, noData: -32768)
        XCTAssertTrue(h.isSelfConsistent)
    }
}

/// The almanac-staleness gate lives in AppModel (it needs the model's almanac + fix), but its LOGIC —
/// "a stale almanac must hand the classifier nil geometry so it cannot claim jamming" — is verifiable
/// directly against the classifier, which is what actually enforces the safeguard.
final class GPSThreatStaleGeometryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func blownAccuracyGoodSky(dop: PredictedDOP?, sats: Int?) -> GPSThreatAssessment {
        let integ = GPSIntegrityAssessment(state: .unreliable, reasons: [.accuracyUnusable],
                                           at: now, horizontalAccuracyM: 200)
        return GPSThreatClassifier.classify(integrity: integ, predictedDOP: dop,
                                            satellitesAboveMask: sats, now: now)
    }

    /// With FRESH geometry, blown accuracy under a good sky is jamming (the safeguard's "on" state).
    func testFreshGeometryStillEnablesJamming() {
        let dop = PredictedDOP(gdop: 2.1, pdop: 1.8, hdop: 1.0, vdop: 1.5, tdop: 1.0)
        XCTAssertEqual(blownAccuracyGoodSky(dop: dop, sats: 11).threat, .jamming)
    }

    /// When AppModel gates a stale almanac to nil geometry, the SAME blown accuracy must fall back to
    /// degraded — geometry the app no longer trusts cannot be used to accuse anything of jamming.
    func testStaleGeometryGatedToNilCannotClaimJamming() {
        let a = blownAccuracyGoodSky(dop: nil, sats: nil)
        XCTAssertEqual(a.threat, .degraded, "nil geometry (stale almanac) must not manufacture jamming")
        XCTAssertNotEqual(a.threat, .jamming)
    }

    /// The age arithmetic the gate depends on: a real almanac read months after its epoch is flagged
    /// past the 90-day line.
    func testAlmanacAgeCrossesTheGateThreshold() {
        let entries = GPSAlmanac.parseYUMA(GPSAlmanacPropagationPeriodTests.fixture)
        guard let e = entries.first else { return XCTFail("fixture must parse") }
        // The fixture is week 381; ~100 days after its reference epoch it must read as stale.
        let ref = GPSAlmanac.referenceDate(e, resolvedAt: now)
        let old = ref.addingTimeInterval(100 * 86_400)
        XCTAssertGreaterThan(abs(GPSAlmanac.ageDays(e, at: old)), AppModel.almanacThreatMaxAgeDays)
    }
}
