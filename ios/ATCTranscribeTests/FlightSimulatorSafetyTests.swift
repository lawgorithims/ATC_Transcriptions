import XCTest
@testable import ATCTranscribe

/// The safety envelope around the flight simulator.
///
/// This feature publishes a position that is not real, into the same publishers the ownship symbol, the
/// AGL readout, the approach profile and the constraint checks all read. The whole reason it is
/// acceptable to ship is that it cannot arm when a real aeroplane could be involved and cannot survive
/// anything that would let it come back unannounced. Those are the properties tested here — the ones
/// that would otherwise only be discovered in an aircraft.
@MainActor
final class FlightSimulatorSafetyTests: XCTestCase {

    /// Locked developer diagnostics is the outermost gate, and it is checked before anything else so a
    /// normal install can never reach the rest of the machinery.
    func testItRefusesWithDiagnosticsLocked() {
        let model = AppModel()
        model.diagnosticsEnabled = false
        XCTAssertEqual(model.simulatorRefusal(), .diagnosticsOff)
        XCTAssertEqual(model.armSimulator(), .diagnosticsOff)
        XCTAssertFalse(model.deviceLocation.isSimulating, "a refused arm must not start anything")
    }

    /// With diagnostics unlocked but nothing to fly, it still refuses — and names the reason rather
    /// than failing silently.
    func testItRefusesWithNoActiveApproach() {
        let model = AppModel()
        model.diagnosticsEnabled = true
        XCTAssertEqual(model.simulatorRefusal(), .noApproach)
        XCTAssertFalse(model.deviceLocation.isSimulating)
    }

    /// Stopping the GPS session disarms. This is the property that matters most: `stop()` runs on
    /// backgrounding, so without it an armed simulation would come back with the app and greet the
    /// pilot as a real position.
    func testStoppingTheLocationSessionDisarms() {
        let loc = DeviceLocation()
        guard let sim = Self.simulator() else { return XCTFail("fixture profile must be flyable") }
        loc.startSimulation(sim)
        XCTAssertTrue(loc.isSimulating)
        loc.stop()
        XCTAssertFalse(loc.isSimulating, "a simulation must not survive the session that hosted it")
        XCTAssertNil(loc.coord, "and it must not leave its last fake position behind")
    }

    /// Disarming is idempotent and always lands back in the honest unknown state rather than leaving a
    /// stale simulated fix on screen.
    func testDisarmingClearsThePublishedPosition() {
        let loc = DeviceLocation()
        guard let sim = Self.simulator() else { return XCTFail("fixture profile must be flyable") }
        loc.startSimulation(sim)
        XCTAssertNotNil(loc.coord, "arming publishes immediately, not after the first tick")
        loc.stopSimulation()
        loc.stopSimulation()                              // idempotent
        XCTAssertFalse(loc.isSimulating)
        XCTAssertNil(loc.fix)
        XCTAssertEqual(loc.integrity.state, .unknown)
    }

    /// The simulated stream must read as NOMINAL rather than being flagged and suppressed. Feeding it
    /// to the integrity monitor would latch `.suspect` at any speed multiplier, and `.suspect` hides
    /// ownship — the very aircraft under test.
    func testTheSimulatedStreamIsNotSuppressed() {
        let loc = DeviceLocation()
        guard let sim = Self.simulator() else { return XCTFail("fixture profile must be flyable") }
        loc.startSimulation(sim, speedMultiplier: 10)
        XCTAssertEqual(loc.integrity.state, .nominal)
        XCTAssertFalse(loc.integrity.shouldSuppressOwnship,
                       "the aircraft under test must remain visible")
        XCTAssertNotNil(loc.trustedCoord)
        loc.stopSimulation()
    }

    /// The on-screen vertical speed is documented as MEASURED. Publishing the model's commanded rate
    /// would make the VSI identically equal to the advisory it exists to be checked against, so the one
    /// instrument that could disagree never would.
    func testTheCommandedRateIsNotPublishedAsAMeasurement() {
        let loc = DeviceLocation()
        guard let sim = Self.simulator() else { return XCTFail("fixture profile must be flyable") }
        loc.startSimulation(sim)
        XCTAssertNil(loc.integrity.verticalSpeedFpm,
                     "a commanded rate is not a measurement and must not masquerade as one")
        loc.stopSimulation()
    }

    /// Ground speed is never scaled by the wall-clock multiplier — it is what the required-rate advisory
    /// consumes, and inflating it would make the advisory describe an aeroplane nobody is flying.
    func testTheSpeedMultiplierDoesNotInflateGroundSpeed() {
        let loc = DeviceLocation()
        guard let sim = Self.simulator(groundSpeedKt: 120) else { return XCTFail("fixture must be flyable") }
        loc.startSimulation(sim, speedMultiplier: 10)
        let published = loc.fix?.groundSpeedMps ?? 0
        XCTAssertEqual(published, 120 * 0.514444, accuracy: 0.5,
                       "the clock may run fast; the aeroplane may not")
        loc.stopSimulation()
    }

    // MARK: fixture

    private static func simulator(groundSpeedKt: Double = 120) -> ApproachSimulator? {
        let threshold = Coord(lat: 42.3656, lon: -71.0096)
        let outer = Geo.destination(from: threshold, bearingDeg: 215, distanceNm: 10)
        let profile = ApproachProfile(
            stations: [
                .init(fix: "MILTT", distanceToThresholdNm: 5.1,
                      constraint: LegConstraint(altDesc: "+", alt: "01700", alt2: "", speedLimitKt: nil,
                                                verticalAngleDeg: nil, rnpNm: nil),
                      role: .finalApproachFix),
                .init(fix: "RW04R", distanceToThresholdNm: 0, constraint: nil, role: .missedApproachPoint),
            ],
            descentAngleDeg: 3.0, thresholdCrossingAltFt: 69, thresholdElevFt: 18,
            airport: "KBOS", approachName: "ILS or LOC RWY 4R",
            hasVerticalGuidance: true, outerCoord: outer)
        return ApproachSimulator(profile: profile, threshold: threshold,
                                 config: .init(groundSpeedKt: groundSpeedKt, startAtNm: 8))
    }
}
