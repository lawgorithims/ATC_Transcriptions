import XCTest
@testable import ATCTranscribe

/// Stubs HTTP so `CockpitDeviceProbe` is testable without an appliance on the bench.
/// Keyed by host so a single test can present a Stratux and an Obelisk simultaneously.
final class StubProtocol: URLProtocol {
    /// host → (status, body). A nil body simulates a connection failure.
    nonisolated(unsafe) static var responses: [String: (Int, Data?)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let (code, body) = Self.responses[host], let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }
}

final class CockpitDeviceTests: XCTestCase {

    override func tearDown() {
        StubProtocol.responses = [:]
        super.tearDown()
    }

    // MARK: Kinds

    func testDefaultsMatchTheApplianceNetworks() {
        XCTAssertEqual(CockpitDeviceKind.stratux.defaultHost, "192.168.10.1")
        XCTAssertEqual(CockpitDeviceKind.obelisk.defaultHost, "192.168.4.1")
        // Both run the same sidecar, so the port must not diverge by accident.
        XCTAssertEqual(CockpitDeviceKind.stratux.defaultAudioPort,
                       CockpitDeviceKind.obelisk.defaultAudioPort)
        XCTAssertEqual(CockpitDeviceKind.obelisk.defaultAudioPort, 8090)
    }

    /// The Obelisk is audio-only. Selecting it must not switch on the traffic/GPS link, or the
    /// app would poll an endpoint that does not exist and claim a receiver that is not there.
    func testOnlyStratuxProvidesTrafficAndGPS() {
        XCTAssertTrue(CockpitDeviceKind.stratux.providesTrafficAndGPS)
        XCTAssertFalse(CockpitDeviceKind.obelisk.providesTrafficAndGPS)
        XCTAssertFalse(CockpitDeviceKind.stratux.providesBatteryTelemetry)
        XCTAssertTrue(CockpitDeviceKind.obelisk.providesBatteryTelemetry)
    }

    // MARK: Health decoding

    /// The two appliances run different sidecar versions. A decoder that fails on an absent key
    /// would report a healthy device as unreachable — the worst outcome for discovery.
    func testHealthDecodesWhenObeliskOnlyFieldsAreAbsent() throws {
        let json = Data("""
        {"service":"commsight-cockpit-audio","version":"1.2.0","ok":true,
         "rate":16000,"channels":1,"format":"S16_LE",
         "resolved_device":"plughw:1,0","device_present":true,
         "capture_devices":["plughw:1,0"],"streaming":false}
        """.utf8)
        let h = try JSONDecoder().decode(CockpitHealth.self, from: json)
        XCTAssertTrue(h.canStream)
        XCTAssertTrue(h.formatMatchesPipeline)
        XCTAssertNil(h.battery)
        XCTAssertNil(h.filter)
        XCTAssertEqual(h.resolvedDevice, "plughw:1,0")
    }

    func testHealthDecodesObeliskBatteryAndFilter() throws {
        let json = Data("""
        {"ok":true,"device_present":true,"rate":16000,"channels":1,"format":"S16_LE",
         "platform":"obelisk",
         "battery":{"percent":76.5,"voltage":3.98,"charging":false,"minutes_remaining":143},
         "filter":{"enabled":true,"preset":"atc","commsight_source":"raw"}}
        """.utf8)
        let h = try JSONDecoder().decode(CockpitHealth.self, from: json)
        XCTAssertEqual(h.platform, "obelisk")
        XCTAssertEqual(h.battery?.clampedPercent ?? 0, 76.5, accuracy: 0.01)
        XCTAssertEqual(h.battery?.minutesRemaining, 143)
        XCTAssertTrue(h.filter?.enabled ?? false)
        // The toggle under test: filter on, but Obelisk is deliberately fed the RAW feed.
        XCTAssertFalse(h.filter?.servingFiltered ?? true)
    }

    /// A sidecar that answers happily with no adapter plugged in serves silence. `ok` alone
    /// must not be treated as "can stream".
    func testCanStreamRequiresAnActualAdapter() throws {
        let json = Data(#"{"ok":true,"device_present":false}"#.utf8)
        let h = try JSONDecoder().decode(CockpitHealth.self, from: json)
        XCTAssertFalse(h.canStream, "no adapter present must not count as streamable")
    }

    /// A sidecar misconfigured to 44.1 kHz stereo streams bytes that decode as fast noise.
    func testWrongFormatIsDetected() throws {
        let json = Data(#"{"ok":true,"device_present":true,"rate":44100,"channels":2,"format":"S16_LE"}"#.utf8)
        let h = try JSONDecoder().decode(CockpitHealth.self, from: json)
        XCTAssertTrue(h.canStream)
        XCTAssertFalse(h.formatMatchesPipeline)
    }

    // MARK: Battery

    func testBatteryPercentIsClamped() {
        // The PiSugar fuel gauge can read slightly over 100 while charging.
        let over = BatteryTelemetry(percent: 103.2, voltage: nil, current: nil,
                                    charging: true, temperatureC: nil, minutesRemaining: nil)
        XCTAssertEqual(over.clampedPercent ?? 0, 100, accuracy: 0.001)
        let under = BatteryTelemetry(percent: -1.5, voltage: nil, current: nil,
                                     charging: false, temperatureC: nil, minutesRemaining: nil)
        XCTAssertEqual(under.clampedPercent ?? -1, 0, accuracy: 0.001)
    }

    func testLowBatteryOnlyWhenNotCharging() {
        let discharging = BatteryTelemetry(percent: 12, voltage: nil, current: nil,
                                           charging: false, temperatureC: nil, minutesRemaining: nil)
        XCTAssertTrue(discharging.isLow)
        let charging = BatteryTelemetry(percent: 12, voltage: nil, current: nil,
                                        charging: true, temperatureC: nil, minutesRemaining: nil)
        XCTAssertFalse(charging.isLow, "on charge at 12% is not a warning state")
    }

    // MARK: Probe

    func testProbeReturnsUsableForAHealthyObelisk() async {
        StubProtocol.responses["192.168.4.1"] = (200, Data("""
        {"ok":true,"device_present":true,"rate":16000,"channels":1,"format":"S16_LE"}
        """.utf8))
        let s = await CockpitDeviceProbe.probe(kind: .obelisk, session: StubProtocol.session())
        XCTAssertTrue(s.reachable)
        XCTAssertTrue(s.isUsable)
        XCTAssertEqual(s.summary, "Ready")
        XCTAssertEqual(s.host, "192.168.4.1")
    }

    /// An unreachable device is a normal discovery outcome, not an error to throw.
    func testProbeOfAbsentDeviceIsNotAnError() async {
        let s = await CockpitDeviceProbe.probe(kind: .stratux, session: StubProtocol.session())
        XCTAssertFalse(s.reachable)
        XCTAssertFalse(s.isUsable)
        XCTAssertTrue(s.summary.contains("Not found"))
    }

    /// "Not found" sends people to reboot routers; "no adapter plugged in" sends them to the
    /// actual fault. The distinction is the point of the summary.
    func testSummaryNamesTheRealFault() async {
        StubProtocol.responses["192.168.4.1"] = (200, Data(#"{"ok":true,"device_present":false}"#.utf8))
        let s = await CockpitDeviceProbe.probe(kind: .obelisk, session: StubProtocol.session())
        XCTAssertTrue(s.reachable)
        XCTAssertFalse(s.isUsable)
        XCTAssertTrue(s.summary.contains("no audio adapter"), "got: \(s.summary)")
    }

    func testDiscoverySortsUsableDevicesFirst() async {
        // Stratux answers but has no adapter; Obelisk is fully healthy.
        StubProtocol.responses["192.168.10.1"] = (200, Data(#"{"ok":true,"device_present":false}"#.utf8))
        StubProtocol.responses["192.168.4.1"] = (200, Data("""
        {"ok":true,"device_present":true,"rate":16000,"channels":1,"format":"S16_LE"}
        """.utf8))
        let all = await CockpitDeviceProbe.discover(session: StubProtocol.session())
        XCTAssertEqual(all.count, CockpitDeviceKind.allCases.count)
        XCTAssertEqual(all.first?.kind, .obelisk, "the usable device must sort first")
        XCTAssertTrue(all.first?.isUsable ?? false)
    }

    /// Both are probed even when one answers: a cockpit may legitimately run a Stratux for
    /// traffic and an Obelisk for audio, and preferring whichever replied first would make the
    /// result vary between runs.
    func testDiscoveryProbesEveryKind() async {
        StubProtocol.responses["192.168.4.1"] = (200, Data(#"{"ok":true,"device_present":true}"#.utf8))
        let all = await CockpitDeviceProbe.discover(session: StubProtocol.session())
        XCTAssertEqual(Set(all.map(\.kind)), Set(CockpitDeviceKind.allCases))
    }

    func testBatteryIsNeverFetchedForStratux() async {
        StubProtocol.responses["192.168.10.1"] = (200, Data("""
        {"ok":true,"device_present":true,"battery":{"percent":50}}
        """.utf8))
        // Even if a Stratux somehow reported one, we do not surface it — the capability flag,
        // not the payload, decides.
        let b = await CockpitDeviceProbe.battery(kind: .stratux, session: StubProtocol.session())
        XCTAssertNil(b)
    }

    func testHostOverrideIsHonoured() async {
        StubProtocol.responses["10.0.0.55"] = (200, Data(#"{"ok":true,"device_present":true}"#.utf8))
        let s = await CockpitDeviceProbe.probe(kind: .obelisk, host: "10.0.0.55", port: 9999,
                                               session: StubProtocol.session())
        XCTAssertTrue(s.isUsable)
        XCTAssertEqual(s.port, 9999)
    }
}
