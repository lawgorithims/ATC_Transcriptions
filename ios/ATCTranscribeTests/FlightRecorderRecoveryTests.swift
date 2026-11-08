import XCTest
@testable import ATCTranscribe

/// Crash recovery for the flight recorder — the path a pilot reported losing a flight to.
///
/// The on-disk mirror and `recoverOnLaunch` were written long before these tests and worked; what was
/// missing was anything that READ the recovered state, so the trail came back into memory and was then
/// overwritten by the first tap of REC. These tests pin the three things that were wrong: the recovery
/// is reachable, starting a new recording cannot destroy it, and it can be closed off and saved.
///
/// Every recorder here gets its own temp directory. Sharing the app's Application Support folder would
/// let a test read — and overwrite — a real in-progress flight.
@MainActor
final class FlightRecorderRecoveryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Drive a recorder far enough to have a trail on disk, then abandon it the way a crash does —
    /// no stop, no flush, just a process that stops existing.
    @discardableResult
    private func recordAndCrash(points: Int = 12) -> FlightRecorder {
        let r = FlightRecorder(directory: dir)
        var i = 0
        r.fixProvider = {
            i += 1
            // ~0.1 NM apart, which clears the 0.02 NM move gate, at a speed well above taxi.
            return BreadcrumbFix(coord: Coord(lat: 33.0 + Double(i) * 0.0017, lon: -97.0),
                                 altFt: 3_500, speedKt: 110, track: 0, source: .device)
        }
        r.startRecording(aircraftCallsign: "N123AB")
        for _ in 0..<points { r.forceSampleForTests() }
        return r
    }

    func testARecorderComesBackWithTheTrailTheCrashSpared() {
        recordAndCrash(points: 12)
        let reborn = FlightRecorder(directory: dir)          // the relaunch
        XCTAssertEqual(reborn.state, .recovered)
        XCTAssertNotNil(reborn.recovered)
        XCTAssertGreaterThan(reborn.trail.count, 0, "the whole point: the trail survived")
        XCTAssertEqual(reborn.recovered?.points, reborn.trail.count)
        XCTAssertGreaterThan(reborn.recovered?.distanceNM ?? 0, 0)
        XCTAssertFalse(reborn.isRecording, "recovered is not recording — the sampler stays down")
    }

    /// THE REPORTED FAULT. Before the guard, the first tap of REC after a crash called
    /// `resetAccumulators()` and then persisted the empty recording over the file — so the recovery
    /// destroyed the flight the crash had spared.
    func testStartingANewRecordingCannotDestroyARecoveredOne() {
        recordAndCrash(points: 12)
        let reborn = FlightRecorder(directory: dir)
        let before = reborn.trail.count
        XCTAssertGreaterThan(before, 0)

        reborn.startRecording(aircraftCallsign: "N999ZZ")    // the tap that used to wipe it

        XCTAssertEqual(reborn.state, .recovered, "a recovered recording is not silently replaced")
        XCTAssertEqual(reborn.trail.count, before, "the trail must still be here")
        // And it is still on disk, so even this launch dying again does not lose it.
        let third = FlightRecorder(directory: dir)
        XCTAssertEqual(third.state, .recovered)
        XCTAssertEqual(third.trail.count, before)
    }

    func testARecoveredRecordingCanBeResumedAndKeepsItsTrail() {
        recordAndCrash(points: 12)
        let reborn = FlightRecorder(directory: dir)
        let before = reborn.trail.count
        reborn.fixProvider = { BreadcrumbFix(coord: Coord(lat: 34.0, lon: -97.0), altFt: 3_500,
                                             speedKt: 110, track: 0, source: .device) }
        reborn.resumeRecovered()
        XCTAssertTrue(reborn.isRecording)
        reborn.forceSampleForTests()
        XCTAssertEqual(reborn.trail.count, before + 1, "resuming appends to the same flight")
    }

    /// A recovered flight has to be closeable, or the only way out of the state is to throw it away.
    /// `stopRecording` used to refuse anything but `.recording` and return nil here.
    func testARecoveredRecordingCanBeStoppedAndSaved() throws {
        recordAndCrash(points: 12)
        let reborn = FlightRecorder(directory: dir)
        let lastPointAt = try XCTUnwrap(reborn.trail.last).t
        let flight = try XCTUnwrap(reborn.stopRecording(), "a recovered flight must be saveable")
        XCTAssertEqual(reborn.state, .idle)
        XCTAssertGreaterThan(flight.distanceNM, 0)
        XCTAssertEqual(flight.aircraftCallsign, "N123AB", "it keeps the tail it was recorded under")
        // ⚠️ Ends at the last breadcrumb, not at `Date()`. The app was shut in between, and billing
        // that time to the flight would put hours the aeroplane spent parked into the logbook.
        XCTAssertEqual(flight.endedAt.timeIntervalSince1970, lastPointAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertLessThan(flight.durationSec, 60, "a short recording stays a short flight")
    }

    func testDiscardingARecoveredRecordingClearsItEverywhere() {
        recordAndCrash(points: 12)
        let reborn = FlightRecorder(directory: dir)
        reborn.discardRecovered()
        XCTAssertEqual(reborn.state, .idle)
        XCTAssertTrue(reborn.trail.isEmpty)
        XCTAssertNil(FlightRecorder(directory: dir).recovered, "and it does not come back next launch")
    }

    /// ⚠️ THE FINISHED FLIGHT REACHES DISK BEFORE THE MIRROR IS REMOVED. `stopRecording` used to
    /// delete the active mirror FIRST and write the pending save second, so a kill in the window
    /// between them left neither file and lost the flight outright — on the one action a pilot takes
    /// believing their flight is now safe. The order is the fix; this pins the end state it produces.
    func testStoppingLeavesTheFinishedFlightOnDiskAndNoMirror() throws {
        recordAndCrash(points: 12)
        let reborn = FlightRecorder(directory: dir)
        XCTAssertNotNil(reborn.stopRecording())

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingPath),
                      "the finished flight must be on disk awaiting its save prompt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: activePath),
                       "and the in-progress mirror must be gone, or it would be recovered again")
        // A relaunch now offers the save prompt and nothing else.
        let next = FlightRecorder(directory: dir)
        XCTAssertNotNil(next.recoveredPendingSave, "the save prompt survives a crash of its own")
        XCTAssertEqual(next.state, .idle)
    }

    /// ⚠️ BOTH FILES AT ONCE — the state the reordering above can now produce, and the one that
    /// would log a flight twice. A kill between writing the pending save and deleting the mirror
    /// leaves a mirror of a recording that has ALREADY been closed off. Recovering it as well would
    /// show a save sheet AND a "resume this flight" banner for the same flight, and resuming would
    /// append fresh points to a trail finished minutes ago.
    ///
    /// Constructed by hand because the window is microseconds wide. The filenames are duplicated
    /// here deliberately: they ARE the on-disk contract, so a rename that broke recovery in the app
    /// should break this test too.
    func testAStaleMirrorBesideAFinishedFlightIsDiscarded() throws {
        recordAndCrash(points: 12)                      // leaves the active mirror
        let finished = LoggedFlight(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                    endedAt: Date(timeIntervalSince1970: 1_793_003_600),
                                    durationSec: 3_600, distanceNM: 120, maxSpeedKt: 140,
                                    avgSpeedKt: 120, maxAltFtMSL: 6_500, stops: [],
                                    aircraftCallsign: "N8925T", aircraftType: nil, notes: "",
                                    breadcrumb: [])
        try JSONEncoder().encode(finished).write(to: URL(fileURLWithPath: pendingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activePath), "setup: both files exist")

        let reborn = FlightRecorder(directory: dir)     // the relaunch into the ambiguous state

        XCTAssertEqual(reborn.recoveredPendingSave?.aircraftCallsign, "N8925T",
                       "the FINISHED flight is the one that survives")
        XCTAssertEqual(reborn.state, .idle, "and the stale mirror does not also become a recovery")
        XCTAssertNil(reborn.recovered)
        XCTAssertTrue(reborn.trail.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activePath),
                       "the stale mirror is removed, not left to reappear at the next launch")
    }

    private var activePath: String {
        dir.appendingPathComponent("flight_recorder_active_v1.json").path
    }
    private var pendingPath: String {
        dir.appendingPathComponent("flight_recorder_pending_v1.json").path
    }

    func testAFreshRecorderWithNothingOnDiskIsIdle() {
        let r = FlightRecorder(directory: dir)
        XCTAssertEqual(r.state, .idle)
        XCTAssertNil(r.recovered)
        XCTAssertNil(r.stopRecording(), "nothing recorded, nothing to save")
    }
}
