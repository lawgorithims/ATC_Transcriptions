import XCTest
@testable import ATCTranscribe

/// Payload bytes must be a deterministic function of the value.
///
/// REGRESSION, and it was shipping: `JSONEncoder` does not promise a key order, and it genuinely
/// varies between two encodes of the same value in one process. With a plain `JSONEncoder()`, two
/// devices holding an identical flight produced payloads that differed in bytes only — so the merge
/// read `mine != theirs`, found both clocks equal and both records live, broke the tie by byte order
/// and queued an upload. On every pass, forever, on both devices.
///
/// Nothing in a round-trip test catches it: encode-then-decode is perfectly correct. It only shows up
/// when two separately-produced payloads for the same value are compared, which is what sync does and
/// nothing else in the app does.
@MainActor
final class SyncCodingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func flight() -> LoggedFlight {
        let trail = (0..<4).map { i in
            Breadcrumb(t: t0.addingTimeInterval(Double(i) * 60), lat: 42 + Double(i) * 0.1,
                       lon: -71 - Double(i) * 0.1, altFt: 3000, speedKt: 120, track: 90)
        }
        return LoggedFlight(id: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!,
                            startedAt: t0, endedAt: t0.addingTimeInterval(3600), durationSec: 3600,
                            distanceNM: 100, maxSpeedKt: 140, avgSpeedKt: 110, maxAltFtMSL: 8500,
                            stops: [FlightStop(id: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!,
                                               lat: 42, lon: -71, arrivedAt: t0, durationSec: 600,
                                               airport: "KBED")],
                            aircraftCallsign: "N8925T", aircraftType: "Seneca",
                            notes: "two bags of ice", breadcrumb: trail)
    }

    /// Encoding the same flight repeatedly must give byte-identical output. Several rounds, because the
    /// unstable ordering did not show on every pair.
    func testEncodingTheSameFlightIsByteStable() throws {
        let f = flight()
        let first = try SyncCoding.encoder.encode(f)
        for round in 1...25 {
            XCTAssertEqual(try SyncCoding.encoder.encode(f), first,
                           "round \(round): the payload for one value must have one encoding, or the "
                           + "merge sees a difference that is not there and uploads forever")
        }
    }

    /// The plain encoder is NOT stable. Asserting the bug exists is what stops someone "simplifying"
    /// `SyncCoding` away — if this ever starts failing, Foundation has been fixed and the comment in
    /// `SyncCoding` should say so before anyone deletes it.
    func testThePlainEncoderIsTheProblemThisTypeSolves() throws {
        let f = flight()
        var encodings = Set<Data>()
        for _ in 0..<50 { encodings.insert(try JSONEncoder().encode(f)) }
        if encodings.count == 1 {
            throw XCTSkip("JSONEncoder emitted a stable key order 50 times — Foundation may have "
                          + "changed. SyncCoding is still correct; this test is just no longer "
                          + "demonstrating the hazard.")
        }
        XCTAssertGreaterThan(encodings.count, 1,
                             "this is the hazard SyncCoding exists for, kept as a live demonstration")
    }

    /// The round trip still works — a canonical encoder is useless if it cannot be read back.
    func testCanonicalPayloadsStillDecode() throws {
        let f = flight()
        let decoded = try SyncCoding.decoder.decode(LoggedFlight.self,
                                                    from: try SyncCoding.encoder.encode(f))
        XCTAssertEqual(decoded, f)
    }

    /// And the note envelope, which carries binary ink alongside its metadata.
    func testNotePayloadsAreByteStableThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir, ledger: SyncLedger(directory: dir))
        _ = store.save(id: "A-NOTE", title: "brief", drawing: Data(repeating: 7, count: 512),
                       thumbnail: Data(repeating: 9, count: 64), createdAt: t0, now: t0)

        let first = store.syncRecords()
        for round in 1...10 {
            XCTAssertEqual(store.syncRecords(), first, "round \(round): a note payload must be stable too")
        }
    }
}
