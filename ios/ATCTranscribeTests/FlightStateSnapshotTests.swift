import XCTest
@testable import ATCTranscribe

/// The failsafe behind the test bench: capture → restore must be byte-identical, and an interrupted
/// bench must be recoverable at launch. Uses an isolated UserDefaults suite so it never touches the
/// app's real `atc.*` keys.
final class FlightStateSnapshotTests: XCTestCase {

    private var d: UserDefaults!
    private let suite = "test.flightstatesnapshot"

    override func setUp() {
        super.setUp()
        d = UserDefaults(suiteName: suite)
        d.removePersistentDomain(forName: suite)
    }
    override func tearDown() {
        d.removePersistentDomain(forName: suite)
        d = nil
        super.tearDown()
    }

    private func seedRealFlight() {
        d.set(Data("PLAN".utf8), forKey: FlightStateSnapshot.Key.flightPlan)
        d.set(Data("HANGAR".utf8), forKey: FlightStateSnapshot.Key.aircraftProfiles)
        d.set("KAUS", forKey: FlightStateSnapshot.Key.airport)
        d.set(true, forKey: FlightStateSnapshot.Key.efbSuggestions)
        d.set(false, forKey: FlightStateSnapshot.Key.foreflight)
    }

    func testCaptureRestoreRoundTripsVerbatim() {
        seedRealFlight()
        let snap = FlightStateSnapshot.capture(from: d)
        // Simulate the bench trashing the live state with a sandbox plan.
        d.set(Data("SANDBOX".utf8), forKey: FlightStateSnapshot.Key.flightPlan)
        d.set("KBOS", forKey: FlightStateSnapshot.Key.airport)
        d.set(false, forKey: FlightStateSnapshot.Key.efbSuggestions)
        // Restore.
        snap.restoreBlobs(to: d)
        XCTAssertEqual(d.data(forKey: FlightStateSnapshot.Key.flightPlan), Data("PLAN".utf8))
        XCTAssertEqual(d.data(forKey: FlightStateSnapshot.Key.aircraftProfiles), Data("HANGAR".utf8))
        XCTAssertEqual(d.string(forKey: FlightStateSnapshot.Key.airport), "KAUS")
        XCTAssertEqual(d.bool(forKey: FlightStateSnapshot.Key.efbSuggestions), true)
        XCTAssertEqual(d.bool(forKey: FlightStateSnapshot.Key.foreflight), false)
    }

    func testRestoreOfNoPlanRemovesTheKey() {
        // A user with NO filed plan enters the bench; restore must leave NO plan (not an empty blob).
        d.set("KAUS", forKey: FlightStateSnapshot.Key.airport)
        let snap = FlightStateSnapshot.capture(from: d)
        XCTAssertNil(snap.flightPlan)
        d.set(Data("SANDBOX".utf8), forKey: FlightStateSnapshot.Key.flightPlan)   // bench fills it
        snap.restoreBlobs(to: d)
        XCTAssertNil(d.data(forKey: FlightStateSnapshot.Key.flightPlan), "no-plan must restore as no-plan")
    }

    func testUnsetTogglesCaptureAsTrue() {
        // Matches the app's own `?? true` default so a first-run user's switches restore faithfully.
        let snap = FlightStateSnapshot.capture(from: d)
        XCTAssertTrue(snap.efbSuggestionsEnabled)
        XCTAssertTrue(snap.foreflightEnabled)
    }

    func testInterruptedBenchRecoversAtLaunch() {
        seedRealFlight()
        let snap = FlightStateSnapshot.capture(from: d)
        snap.persistAsBreadcrumb(to: d)                     // bench entered
        XCTAssertTrue(d.bool(forKey: FlightStateSnapshot.Key.active))
        // Bench swaps in a sandbox, then the app is "killed" (no clean exit).
        d.set(Data("SANDBOX".utf8), forKey: FlightStateSnapshot.Key.flightPlan)
        d.set("KBOS", forKey: FlightStateSnapshot.Key.airport)
        // Next launch:
        XCTAssertTrue(FlightStateSnapshot.recoverIfInterrupted(in: d))
        XCTAssertEqual(d.data(forKey: FlightStateSnapshot.Key.flightPlan), Data("PLAN".utf8),
                       "the real plan must be back after an interrupted bench")
        XCTAssertEqual(d.string(forKey: FlightStateSnapshot.Key.airport), "KAUS")
        XCTAssertFalse(d.bool(forKey: FlightStateSnapshot.Key.active), "breadcrumb must be cleared")
    }

    func testRecoverIsNoOpWithoutBreadcrumb() {
        seedRealFlight()
        XCTAssertFalse(FlightStateSnapshot.recoverIfInterrupted(in: d))
        XCTAssertEqual(d.data(forKey: FlightStateSnapshot.Key.flightPlan), Data("PLAN".utf8),
                       "no breadcrumb → nothing touched")
    }

    func testCleanExitLeavesNoBreadcrumb() {
        seedRealFlight()
        FlightStateSnapshot.capture(from: d).persistAsBreadcrumb(to: d)
        FlightStateSnapshot.clearBreadcrumb(in: d)
        XCTAssertNil(FlightStateSnapshot.pending(in: d))
        XCTAssertFalse(FlightStateSnapshot.recoverIfInterrupted(in: d))
    }
}
