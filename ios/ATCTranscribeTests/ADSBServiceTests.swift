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

    /// A verbatim adsb.lol `/v2/point` body, captured live the day the provider was changed.
    ///
    /// ⚠️ THIS EXISTS BECAUSE THE PREVIOUS PROVIDER WENT AWAY AND NOTHING NOTICED.
    /// `api.airplanes.live` began answering 403 — they closed the open endpoint — and because a
    /// traffic layer that is switched on and shows an empty sky looks exactly like a quiet one, it
    /// was flown for a long time before being reported as "ADS-B never works". Pinning a real body
    /// from the provider the app actually calls is the cheapest thing that turns the NEXT such change
    /// from a silent nothing into a red test. The field names are readsb/tar1090's, which is why the
    /// switch needed no decoder change at all.
    func testDecodesARealBodyFromTheCurrentProvider() throws {
        let json = "{\"ac\":["
            + "{\"hex\":\"abe0bb\",\"flight\":\"SWA2114 \",\"lat\":40.570084,\"lon\":-74.077148,"
            + "\"alt_baro\":5000,\"gs\":230.4,\"track\":40.95,\"seen\":0.0,\"seen_pos\":0.138,"
            + "\"category\":\"A3\"},"
            + "{\"hex\":\"a1b2c3\",\"flight\":\"N442QS  \",\"lat\":40.7,\"lon\":-73.9,"
            + "\"alt_baro\":\"ground\",\"gs\":12.0,\"track\":180.0,\"seen\":1.2,\"seen_pos\":1.2}"
            + "],\"now\":1794030450000,\"total\":2}"
        let at = Date(timeIntervalSince1970: 1_794_030_450)
        let (acs, serverNow) = try Aircraft.decode(Data(json.utf8), fetchedAt: at)
        XCTAssertEqual(acs.count, 2, "both contacts decode from the live shape")
        XCTAssertEqual(acs.first?.hex, "abe0bb")
        // Trailing spaces are how these feeds pad the callsign field; the UI must not show them.
        XCTAssertEqual(acs.first?.callsign?.trimmingCharacters(in: .whitespaces), "SWA2114")
        // ⚠️ `now` arrives in MILLISECONDS and is normalised to seconds. A thousand-fold error here
        // would date every contact to 1970 or the far future, and the server-anchored prune — which
        // is what stops stale traffic reaching a prompt — would silently discard the whole snapshot.
        XCTAssertEqual(try XCTUnwrap(serverNow).timeIntervalSince1970, 1_794_030_450, accuracy: 1)
        // "ground" is a STRING where a number usually is. One odd value must not take the sky down.
        XCTAssertEqual(acs.count, 2, "a non-numeric alt_baro does not discard the contact")
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
        // Wait for the poll to PUBLISH CONTACTS, rather than sleeping a span tuned on an idle machine
        // (see AsyncTestSupport). ⚠️ "a snapshot arrived" is NOT the event: `sync` publishes an empty
        // list synchronously to clear the old facility's contacts, so that condition is already true
        // before the first poll and waiting on it tests nothing. The first snapshot carrying any
        // contact is the poll result; which contacts survived is then the actual assertion.
        await waitUntil("a poll to publish contacts") { box.all().contains { !$0.isEmpty } }
        let snapshots = box.all()                              // capture before stop (stop clears)
        await svc.sync(center: nil, enabled: false)
        XCTAssertTrue(snapshots.contains { $0.map(\.hex) == ["f"] },   // stale "s" pruned by contactWindow
                      "got \(snapshots.map { $0.map(\.hex) })")
    }

    func testServiceFailurePublishesEmptyNotFrozen() async {
        let box = Box()
        let statuses = StatusBox()
        let svc = ADSBService(config: .init(pollInterval: 0.02, contactWindow: 30),
                              fetcher: FakeFetcher(scripted: [.failure(ADSBFeedError.rateLimited)]),
                              onUpdate: { list, _ in box.add(list) },
                              onStatus: { statuses.add($0) })
        await svc.sync(center: Coord(lat: 42.36, lon: -71.0), enabled: true)
        // ⚠️ A FAILED poll publishes ([], .distantPast) — byte-identical to the empty list `sync`
        // publishes synchronously to clear the previous facility. So neither "a snapshot arrived" nor
        // the old fixed sleep could distinguish "it polled and failed" from "it never polled at all",
        // and the `it did poll` assertion below was satisfiable without a single poll. The STATUS
        // callback is the unambiguous signal, so wait for that and assert on it.
        await waitUntil("a poll to report failure") { statuses.all().contains { if case .error = $0 { return true }; return false } }
        let snapshots = box.all()
        await svc.sync(center: nil, enabled: false)
        XCTAssertTrue(statuses.all().contains { if case .error = $0 { return true }; return false },
                      "it did poll, and the poll failed")
        XCTAssertFalse(snapshots.isEmpty)
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

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock(); private var statuses: [ADSBStatus] = []
    func add(_ s: ADSBStatus) { lock.lock(); statuses.append(s); lock.unlock() }
    func all() -> [ADSBStatus] { lock.lock(); defer { lock.unlock() }; return statuses }
}
