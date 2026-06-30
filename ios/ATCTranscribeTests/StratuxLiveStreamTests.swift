import XCTest
@testable import ATCTranscribe

/// Sustained-streaming validation against the fake Stratux server (stratux-pi/test/fake_stratux.py).
/// Confirms the cockpit-audio source holds ~16 kHz for a sustained window WHILE the traffic WebSocket
/// + GPS poll run concurrently (the "enough bandwidth / can it keep the stream up for both" check),
/// and that the audio reconnects after the server drops it.
///
/// Gated behind STRATUX_VALIDATE=1 so the normal suite skips it (it needs the server + takes ~40 s).
/// The Simulator's 127.0.0.1 is the Mac host, where the fake server runs. Run via
/// `ios/Tools/stratux_validate.sh`.
final class StratuxLiveStreamTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["STRATUX_VALIDATE"] == "1" }
    private var port: Int { Int(ProcessInfo.processInfo.environment["STRATUX_PORT"] ?? "") ?? 9408 }
    private var audioHost: String { "127.0.0.1" }            // audio source takes host + port separately
    private var serviceHost: String { "127.0.0.1:\(port)" }  // service host carries the port (avoids :80)

    /// Thread-safe tally for the service callbacks (which fire off the actor / network threads).
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var trafficPublishes = 0
        private(set) var maxTargets = 0
        private(set) var gpsUpdates = 0
        func traffic(_ n: Int) { lock.lock(); trafficPublishes += 1; maxTargets = max(maxTargets, n); lock.unlock() }
        func gps() { lock.lock(); gpsUpdates += 1; lock.unlock() }
    }

    /// 30 s of audio while traffic + GPS stream concurrently — measure the sustained audio rate.
    func testSustainedAudioWithConcurrentData() async throws {
        try XCTSkipUnless(enabled, "Set STRATUX_VALIDATE=1 + run fake_stratux.py (see stratux_validate.sh).")

        let counters = Counters()
        let svc = StratuxService(
            onTraffic: { list, _ in counters.traffic(list.count) },
            onGPS: { gps in if gps?.hasFix == true { counters.gps() } },
            onStatus: { _ in })
        await svc.sync(host: serviceHost, enabled: true)        // traffic WS + GPS poll start now

        let src = try XCTUnwrap(StratuxAudioSource(host: audioHost, audioPort: port))
        let window = 30.0
        var samples = 0
        var firstAt: Date?
        let deadline = Date().addingTimeInterval(window + 5)     // safety cap
        for await chunk in src.makeStream() {
            if firstAt == nil { firstAt = Date() }
            samples += chunk.count
            if let firstAt, Date().timeIntervalSince(firstAt) >= window { break }
            if Date() >= deadline { break }
        }
        src.stop()
        await svc.sync(host: serviceHost, enabled: false)

        let elapsed = Date().timeIntervalSince(firstAt ?? Date())
        let rate = Double(samples) / max(elapsed, 0.001)
        print(String(format: "[STRATUX-VALIDATE] audio: %d samples in %.1fs → %.0f samples/s (target 16000); "
                     + "data concurrently: traffic publishes=%d maxTargets=%d gpsUpdates=%d",
                     samples, elapsed, rate, counters.trafficPublishes, counters.maxTargets, counters.gpsUpdates))

        XCTAssertNotNil(firstAt, "no audio received at all")
        // Audio holds real time within ±12% (scheduling jitter) — i.e. it never falls behind the feed
        // even with the traffic/GPS load running at the same time.
        XCTAssertGreaterThan(rate, 16000 * 0.88, "audio fell behind real time under concurrent load")
        XCTAssertLessThan(rate, 16000 * 1.20, "audio ran faster than real time (pacing/parse wrong)")
        // The other data kept flowing the whole time.
        XCTAssertGreaterThan(counters.trafficPublishes, 10, "traffic stopped publishing")
        XCTAssertGreaterThan(counters.maxTargets, 0, "no traffic targets decoded")
        XCTAssertGreaterThan(counters.gpsUpdates, 3, "GPS stopped updating")
    }

    /// The server drops the audio every ~3 s; the client must reconnect and keep delivering audio.
    func testAudioReconnectsAfterDrop() async throws {
        try XCTSkipUnless(enabled, "Set STRATUX_VALIDATE=1 + run fake_stratux.py.")

        let src = try XCTUnwrap(StratuxAudioSource(host: audioHost, audioPort: port, path: "/audio.raw?drop=3"))
        let start = Date()
        let deadline = start.addingTimeInterval(9)              // 3s + 1.5s backoff + more
        var samples = 0
        var samplesAfterReconnect = 0                           // received well past the first drop+backoff
        for await chunk in src.makeStream() {
            samples += chunk.count
            if Date().timeIntervalSince(start) > 5.5 { samplesAfterReconnect += chunk.count }
            if Date() >= deadline { break }
        }
        src.stop()
        print(String(format: "[STRATUX-VALIDATE] reconnect: total=%d samples, after-reconnect(>5.5s)=%d",
                     samples, samplesAfterReconnect))
        // ~16000 samples = 1 s of audio after the drop+backoff proves the stream came back on its own.
        XCTAssertGreaterThan(samplesAfterReconnect, 16000, "audio did not resume after the server dropped it")
    }
}
