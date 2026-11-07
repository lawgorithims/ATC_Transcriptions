import XCTest
@testable import ATCTranscribe

/// What the app SAYS when a recording stops — the half of the logbook fix that is not about data.
///
/// ⚠️ EVERY TEST HERE PINS A SENTENCE THAT USED TO BE SILENCE. The crash-recovery work fixed the
/// data and left the pilot no way to read the outcome: stopping a recording that caught no fix set
/// `pendingLoggedFlight = nil` and returned, and pressing REC over a recovered recording hit a guard
/// that returned. Both are correct behaviour and both looked, from the cockpit, like a broken
/// button — which is how "flights are not saving to the logbook" was reported.
///
/// Each recorder gets its own temp directory. A default `FlightRecorder` reads the app's real
/// Application Support folder, so a test sharing it could read and overwrite a pilot's live flight.
@MainActor
final class LogbookSaveFeedbackTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func recorder() -> FlightRecorder { FlightRecorder(directory: dir) }

    private func crashedRecorder(points: Int = 12) -> FlightRecorder {
        let r = FlightRecorder(directory: dir)
        var i = 0
        r.fixProvider = {
            i += 1
            return BreadcrumbFix(coord: Coord(lat: 33.0 + Double(i) * 0.0017, lon: -97.0),
                                 altFt: 3_500, speedKt: 110, track: 0, source: .device)
        }
        r.startRecording(aircraftCallsign: "N123AB")
        for _ in 0..<points { r.forceSampleForTests() }
        return FlightRecorder(directory: dir)        // the relaunch — comes back `.recovered`
    }

    // MARK: - the two silences

    /// THE REPORTED DOUBT. A recording that caught no fix produces no flight and no save sheet, and
    /// without a word about it the pilot cannot tell that from a flight that saved.
    func testStoppingARecordingThatCaughtNothingSaysSo() {
        let r = recorder()
        let model = AppModel(flightRecorder: r)
        r.fixProvider = { nil }                      // no GPS for the whole recording
        r.startRecording(aircraftCallsign: "N123AB")
        r.forceSampleForTests()
        XCTAssertTrue(r.trail.isEmpty, "setup: nothing was recorded")

        model.toggleFlightRecording()

        XCTAssertNil(model.pendingLoggedFlight, "there is genuinely no flight to save")
        let said = model.transientMessage
        XCTAssertNotNil(said, "and the app has to say that out loud")
        XCTAssertTrue(said?.text.contains("Nothing to save") == true)
        XCTAssertEqual(said?.tone, .warn, "it explains a non-event, which needs the longer read")
    }

    /// ⚠️ THE SILENCE THE CRASH FIX ITSELF CREATED. `startRecording` refuses over `.recovered` — that
    /// guard is what stops the first REC tap after a crash destroying the trail — but the refusal
    /// was mute, so the button simply did nothing while an unsaved flight sat on screen.
    func testPressingRecordOverARecoveredFlightExplainsItself() {
        let r = crashedRecorder()
        XCTAssertEqual(r.state, .recovered, "setup: there is a flight waiting")
        let model = AppModel(flightRecorder: r)
        let trailBefore = r.trail.count

        model.toggleFlightRecording()

        XCTAssertEqual(r.state, .recovered, "the recovered flight is still untouched")
        XCTAssertEqual(r.trail.count, trailBefore, "and still whole")
        XCTAssertFalse(r.isRecording, "no new recording quietly started on top of it")
        let said = model.transientMessage
        XCTAssertNotNil(said, "the dead button has to account for itself")
        XCTAssertTrue(said?.text.contains("recovered") == true)
        XCTAssertEqual(said?.tone, .warn)
    }

    /// Saving a recovered flight goes through the same funnel and, because it DOES produce a flight,
    /// says nothing — the save sheet is the answer.
    func testSavingARecoveredFlightOpensTheSheetAndStaysQuiet() {
        let r = crashedRecorder()
        let model = AppModel(flightRecorder: r)
        model.dismissTransientMessage()              // ignore anything from init

        model.saveRecoveredRecording()

        XCTAssertNotNil(model.pendingLoggedFlight, "the flight reaches the save prompt")
        XCTAssertNil(model.transientMessage, "a visible sheet needs no toast beside it")
    }

    // MARK: - the message slot itself

    /// ⚠️ ONE SLOT AND THE NEWEST WINS. A queue would make a pilot wait out stale sentences to reach
    /// the current one; in a cockpit the latest fact is the only one worth the screen. It is also
    /// what keeps this bounded however fast something calls it.
    func testTheNewestMessageReplacesTheOneBeforeIt() {
        let model = AppModel(flightRecorder: recorder())
        model.say("first")
        let first = model.transientMessage
        model.say("second")
        XCTAssertEqual(model.transientMessage?.text, "second")
        XCTAssertNotEqual(model.transientMessage?.id, first?.id, "replaced, not amended")
    }

    func testAnEmptyMessageIsNotSaid() {
        let model = AppModel(flightRecorder: recorder())
        model.say("")
        XCTAssertNil(model.transientMessage, "an empty capsule is worse than none")
    }

    func testDismissingClearsIt() {
        let model = AppModel(flightRecorder: recorder())
        model.say("something")
        XCTAssertNotNil(model.transientMessage)
        model.dismissTransientMessage()
        XCTAssertNil(model.transientMessage)
    }

    /// A warning is usually the longer sentence AND the one read while also flying.
    func testAWarningStaysOnScreenLongerThanAStatement() {
        let warn = TransientMessage(text: "x", icon: "i", tone: .warn)
        let good = TransientMessage(text: "x", icon: "i", tone: .good)
        XCTAssertGreaterThan(warn.visibleSec, good.visibleSec)
        XCTAssertGreaterThanOrEqual(good.visibleSec, 4, "still long enough to read twice")
    }
}
