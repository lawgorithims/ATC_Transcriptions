import XCTest
@testable import ATCTranscribe

/// ADS-B model decode, freshness/staleness math, the airport-coordinate lookup, the corrector
/// read-site expiry + epoch guarantee, and the polling service driven by a fake fetcher.
final class ADSBServiceTests: XCTestCase {

    private let fixture = """
    { "now": 1782650000000, "ac": [
      {"hex":"a0045c","flight":"N10WN   ","r":"N10WN","t":"M20P","lat":32.94,"lon":-97.60,
       "alt_baro":7100,"gs":140.7,"track":283.1,"squawk":"5273","seen":0.0,"seen_pos":0.1,"dst":18.3},
      {"hex":"abc123","flight":"AAL1234 ","r":"N1AA","t":"B738","lat":32.9,"lon":-97.0,
       "alt_baro":"ground","gs":12,"track":90,"seen":45.0,"seen_pos":45.0,"dst":2.1},
      {"hex":"def456","flight":"        ","alt_baro":"garbage","seen":3.0,"dst":9.0}
    ]}
    """.data(using: .utf8)!

    // MARK: decode + tolerance

    func testDecodeFixture() throws {
        let at = Date()
        let (acs, serverNow) = try Aircraft.decode(fixture, fetchedAt: at)
        XCTAssertEqual(acs.count, 3)
        XCTAssertNotNil(serverNow)
        let a = acs.first { $0.hex == "a0045c" }!
        XCTAssertEqual(a.callsign, "N10WN")          // space-padded `flight` trimmed
        XCTAssertEqual(a.registration, "N10WN")
        XCTAssertEqual(a.altBaroFt, 7100)
        XCTAssertFalse(a.onGround)
        XCTAssertEqual(a.distanceNm ?? 0, 18.3, accuracy: 0.001)

        let grounded = acs.first { $0.hex == "abc123" }!
        XCTAssertTrue(grounded.onGround)             // alt_baro "ground"
        XCTAssertNil(grounded.altBaroFt)

        let blankFlight = acs.first { $0.hex == "def456" }!
        XCTAssertNil(blankFlight.callsign)           // all-spaces flight → nil, not ""
        XCTAssertNil(blankFlight.altBaroFt)          // unknown alt_baro tolerated (→ ground, no feet)
        XCTAssertTrue(blankFlight.onGround)
    }

    func testMalformedElementDoesNotThrow() throws {
        let data = #"{"ac":[{"hex":"x"},{"nohex":true},{"hex":"y","alt_baro":{}}]}"#.data(using: .utf8)!
        let (acs, _) = try Aircraft.decode(data, fetchedAt: Date())
        XCTAssertEqual(acs.map(\.hex).sorted(), ["x", "y"])   // the element without hex is dropped
    }

    // MARK: freshness

    func testLastSeenIsServerAnchoredNotPollTime() {
        let at = Date()
        var ac = Aircraft(hex: "h", onGround: false, fetchedAt: at, seenSec: 40, seenPosSec: 50)
        // lastSeen uses seen_pos (50s) when present — older than seen — anchored to fetchedAt.
        XCTAssertEqual(ac.lastSeen.timeIntervalSince(at), -50, accuracy: 0.001)
        XCTAssertTrue(ac.isStale(window: 30, now: at))
        ac = Aircraft(hex: "h", onGround: false, fetchedAt: at, seenSec: 2, seenPosSec: nil)
        XCTAssertFalse(ac.isStale(window: 30, now: at))
    }

    // MARK: airport coordinates

    func testKBOSResolves() {
        let c = AirportCoordinates.coordinate(icao: "kbos")   // case-insensitive
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.lat, 42.3656, accuracy: 0.01)
        XCTAssertEqual(c!.lon, -71.0096, accuracy: 0.01)
        XCTAssertNil(AirportCoordinates.coordinate(icao: "ZZZZ"))
    }

    // MARK: corrector read-site expiry + epoch (the no-stale-data guarantee)

    func testTrafficBlockExpiresAtReadSite() {
        let ctx = ATCContext(config: nil, feedKey: nil)
        ctx.setTraffic(block: "Traffic in range (live ADS-B): N10WN.", vocab: ["N10WN"],
                       expiry: Date().addingTimeInterval(10), epoch: 1)
        XCTAssertTrue(ctx.retrieveKnowledge(for: "november one zero whiskey").block.contains("N10WN"))
        // Traffic feeds the PROMPT but NOT the validator snap-vocab — so the LLM can't overwrite a
        // spoken callsign with the raw ADS-B code form.
        XCTAssertFalse(ctx.retrieveKnowledge(for: "november one zero whiskey").vocab.contains("N10WN"))

        // An expired block is NOT consumed, even though it's still stored.
        ctx.setTraffic(block: "Traffic in range (live ADS-B): N10WN.", vocab: ["N10WN"],
                       expiry: Date().addingTimeInterval(-1), epoch: 2)
        XCTAssertFalse(ctx.retrieveKnowledge(for: "november one zero whiskey").block.contains("N10WN"))
    }

    func testClearEpochWinsOverStaleSet() {
        let ctx = ATCContext(config: nil, feedKey: nil)
        ctx.clearTraffic(epoch: 5)                              // advance the epoch (toggle-off)
        ctx.setTraffic(block: "Traffic in range (live ADS-B): N10WN.", vocab: ["N10WN"],
                       expiry: Date().addingTimeInterval(10), epoch: 4)   // stale epoch (in-flight)
        XCTAssertFalse(ctx.retrieveKnowledge(for: "x").block.contains("N10WN"))   // ignored
    }

    // MARK: callsign-link chip (matchTraffic)

    func testMatchTrafficRespectsFreshness() {
        let ctx = ATCContext(config: nil, feedKey: nil)
        ctx.setTraffic(block: "Traffic in range (live ADS-B): JBU771, N9133M.", vocab: ["JBU771", "N9133M"],
                       expiry: Date().addingTimeInterval(10), epoch: 1)
        XCTAssertEqual(ctx.matchTraffic(in: "jetblue seventy one JBU771 cleared to land"), "JBU771")
        XCTAssertNil(ctx.matchTraffic(in: "delta eight ninety contact ground"))     // no in-range token
        // An expired snapshot never tags a transmission.
        ctx.setTraffic(block: "x", vocab: ["JBU771"], expiry: Date().addingTimeInterval(-1), epoch: 2)
        XCTAssertNil(ctx.matchTraffic(in: "JBU771 cleared to land"))
    }

    // MARK: service (fake fetcher)

    func testServicePublishesFreshAndPrunesStale() async {
        let at = Date()
        let fresh = Aircraft(hex: "f", callsign: "N1", onGround: false, fetchedAt: at, seenSec: 1, seenPosSec: nil)
        let stale = Aircraft(hex: "s", callsign: "N2", onGround: false, fetchedAt: at, seenSec: 99, seenPosSec: nil)
        let box = Box()
        let svc = ADSBService(config: .init(pollInterval: 0.02, contactWindow: 30),
                              fetcher: FakeFetcher(scripted: [.success([fresh, stale])]),
                              onUpdate: { list, _ in box.add(list) })
        await svc.sync(center: Coord(lat: 42.36, lon: -71.0), enabled: true)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let snapshots = box.all()                              // capture before stop (stop clears)
        await svc.sync(center: nil, enabled: false)
        XCTAssertTrue(snapshots.contains { $0.map(\.hex) == ["f"] },   // stale "s" pruned by contactWindow
                      "got \(snapshots.map { $0.map(\.hex) })")
    }

    func testServiceFailurePublishesEmptyNotFrozen() async {
        let box = Box()
        let svc = ADSBService(config: .init(pollInterval: 0.02, contactWindow: 30),
                              fetcher: FakeFetcher(scripted: [.failure(ADSBFeedError.rateLimited)]),
                              onUpdate: { list, _ in box.add(list) })
        await svc.sync(center: Coord(lat: 42.36, lon: -71.0), enabled: true)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let snapshots = box.all()
        await svc.sync(center: nil, enabled: false)
        XCTAssertFalse(snapshots.isEmpty)                      // it did poll
        XCTAssertTrue(snapshots.allSatisfy { $0.isEmpty })    // a failed poll never surfaces contacts
    }
}

// MARK: - Test doubles

private enum Scripted { case success([Aircraft]); case failure(Error) }

private struct FakeFetcher: AircraftFetching {
    let scripted: [Scripted]
    private let idx = Counter()
    func fetch(center: Coord, radiusNm: Int) async throws -> (aircraft: [Aircraft], serverNow: Date?) {
        let i = min(idx.next(), scripted.count - 1)
        switch scripted[i] {
        case .success(let acs): return (acs, nil)
        case .failure(let e): throw e
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var lists: [[Aircraft]] = []
    func add(_ l: [Aircraft]) { lock.lock(); lists.append(l); lock.unlock() }
    func all() -> [[Aircraft]] { lock.lock(); defer { lock.unlock() }; return lists }
}
