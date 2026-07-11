import XCTest
import AVFoundation
@testable import ATCTranscribe

/// H1/L1/L2 (remediation): the pure audio-session event classifier, the monitor's play() self-heal,
/// and the stream source's bounded give-up when it can never decode.
final class AudioRecoveryTests: XCTestCase {

    // MARK: - H1: AudioSessionEvent classifier (the unit-testable seam of interruption recovery)

    func testInterruptionBeganClassifies() {
        let e = AudioSessionEvent.classify(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertEqual(e, .interruptionBegan)
    }

    func testInterruptionEndedWithShouldResume() {
        let e = AudioSessionEvent.classify(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertEqual(e, .interruptionEnded(shouldResume: true))
    }

    func testInterruptionEndedWithoutOptions() {
        let e = AudioSessionEvent.classify(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        XCTAssertEqual(e, .interruptionEnded(shouldResume: false))
    }

    func testMalformedInterruptionIsIrrelevant() {
        XCTAssertEqual(AudioSessionEvent.classify(name: AVAudioSession.interruptionNotification,
                                                  userInfo: nil), .irrelevant)
        XCTAssertEqual(AudioSessionEvent.classify(name: AVAudioSession.interruptionNotification,
                                                  userInfo: [AVAudioSessionInterruptionTypeKey: "bogus"]),
                       .irrelevant)
        XCTAssertEqual(AudioSessionEvent.classify(name: AVAudioSession.interruptionNotification,
                                                  userInfo: [AVAudioSessionInterruptionTypeKey: UInt(999)]),
                       .irrelevant)
    }

    func testRouteChangeOldDeviceUnavailableIsInputRouteLost() {
        let e = AudioSessionEvent.classify(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(e, .inputRouteLost)
    }

    func testRouteChangeCategoryChangeIsIrrelevant() {
        let e = AudioSessionEvent.classify(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue])
        XCTAssertEqual(e, .irrelevant)
    }

    func testMediaServicesResetClassifies() {
        XCTAssertEqual(AudioSessionEvent.classify(name: AVAudioSession.mediaServicesWereResetNotification,
                                                  userInfo: nil), .mediaServicesReset)
    }

    func testUnrelatedNotificationIsIrrelevant() {
        XCTAssertEqual(AudioSessionEvent.classify(name: Notification.Name("some.other.note"),
                                                  userInfo: nil), .irrelevant)
    }

    // MARK: - L1: AudioMonitor self-heal

    #if DEBUG
    func testPlayHealsAfterEngineStops() {
        let monitor = AudioMonitor()
        monitor.start()
        // If the sim's audio host refused to start the engine at all, healing is untestable here.
        try? XCTSkipUnless(monitor._engineIsRunningForTests, "audio engine unavailable in this environment")
        monitor._stopEngineForTests()                       // simulate an interruption stopping it
        XCTAssertFalse(monitor._engineIsRunningForTests)
        monitor.play([Float](repeating: 0, count: 1600))    // one chunk → self-heal fires
        XCTAssertTrue(monitor._engineIsRunningForTests,
                      "play() must restart an interruption-stopped engine within one chunk")
        monitor.stop()
    }
    #endif

    // MARK: - L2: a never-decoding stream gives up (bounded) instead of wedging forever

    func testUnreachableFeedGivesUpAndFinishesStream() async {
        // 127.0.0.1:1 refuses instantly (offline-safe). Every connect fails → scheduleRetry counts
        // up → give-up cap (candidates × 2) → teardown FINISHES the stream with zero chunks.
        let source = StreamAudioSource(url: URL(string: "http://127.0.0.1:1/dead.mp3")!)
        var chunks = 0
        // Outer safety bound so a regression can't hang the suite: give-up takes ~(attempts × 2 s).
        let watchdog = Task { try? await Task.sleep(nanoseconds: 25_000_000_000); source.stop() }
        for await _ in source.makeStream() { chunks += 1 }
        watchdog.cancel()
        XCTAssertEqual(chunks, 0, "a dead feed must yield no audio")
        // Reaching here at all proves the stream FINISHED (the wedge would hang the for-await).
    }
}
