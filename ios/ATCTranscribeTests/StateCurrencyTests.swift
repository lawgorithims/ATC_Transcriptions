import XCTest
@testable import ATCTranscribe

/// M4 (remediation): a returning mic-permission grant may start capture ONLY if nothing moved under
/// the async dialog. The decision is a pure predicate so it is testable without the (untestable)
/// system permission prompt.
final class StartPermissionGuardTests: XCTestCase {

    private func current(sessionMatches: Bool = true, status: SessionStatus = .starting,
                         sceneActive: Bool = true, source: SourceKind = .microphone,
                         requested: SourceKind = .microphone) -> Bool {
        AppModel.captureRequestStillCurrent(sessionMatches: sessionMatches, status: status,
                                            sceneActive: sceneActive, source: source, requested: requested)
    }

    func testAllCurrentProceeds() {
        XCTAssertTrue(current(), "the untouched grant must proceed")
    }

    func testStaleSessionAborts() {
        // A model swap replaced the session while the dialog was open.
        XCTAssertFalse(current(sessionMatches: false))
    }

    func testNonStartingStatusAborts() {
        // Stop pressed during the dialog moved status to .stopped; a running session is .live.
        XCTAssertFalse(current(status: .stopped))
        XCTAssertFalse(current(status: .live))
        XCTAssertFalse(current(status: .idle))
    }

    func testBackgroundedAborts() {
        XCTAssertFalse(current(sceneActive: false))
    }

    func testSourceRePickAborts() {
        // The user switched the input source while the mic dialog was open.
        XCTAssertFalse(current(source: .usbAudio, requested: .microphone))
        XCTAssertFalse(current(source: .microphone, requested: .usbAudio))
        XCTAssertFalse(current(source: .liveFeed, requested: .microphone))
    }

    func testUsbToUsbProceeds() {
        XCTAssertTrue(current(source: .usbAudio, requested: .usbAudio))
    }
}

/// M7 (remediation): the saved-map-camera freshness rule — restore a rebuilt map to the user's last
/// pan/zoom only within 30 min, so a thermal blip restores but an hours-later return re-frames.
final class MapCameraTests: XCTestCase {

    private func fresh(_ ageSeconds: TimeInterval) -> Bool {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        return SavedMapCamera.cameraIsFresh(savedAt: saved, now: saved.addingTimeInterval(ageSeconds))
    }

    func testFreshWithinWindow() {
        XCTAssertTrue(fresh(0),          "just-saved must be fresh")
        XCTAssertTrue(fresh(29 * 60),    "29 min must be fresh")
    }

    func testStaleAtAndBeyondWindow() {
        XCTAssertFalse(fresh(30 * 60),   "exactly 30 min is the cutoff — stale")
        XCTAssertFalse(fresh(31 * 60),   "31 min must be stale")
    }

    func testNegativeAgeIsNotFresh() {
        // Clock skew / a savedAt in the future must never read as fresh.
        XCTAssertFalse(fresh(-10))
    }
}
