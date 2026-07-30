import XCTest
@testable import ATCTranscribe

/// GRIB2 decode pinned against a REAL NOMADS payload, not a synthetic one. `wind_fixture.grib2` is the
/// GFS 0.25° 06z +9h UGRD/VGRD pair at 850 hPa over a CONUS box, downloaded from
/// `filter_gfs_0p25_1hr.pl` on 2026-07-29, and `wind_fixture_expected.json` holds the values an
/// independent reference decoder produced from it. That independence is the point: a test written from the
/// Swift decoder's own output would pin its bugs rather than the format.
final class Grib2DecoderTests: XCTestCase {

    private struct Expected: Decodable {
        struct Spot: Decodable { let j, i: Int; let u, v: Double }
        struct Bilinear: Decodable {
            let name: String; let lat, lon, u, v, kt, dirFrom: Double
        }
        struct Packing: Decodable { let R: Double; let E, D, nbits: Int }
        let ni, nj: Int
        let minLat, minLon, dLat, dLon: Double
        let scanMode, levelType, levelValue: Int
        let referenceTimeUTC: String
        let forecastHours, forecastUnit, messageCount: Int
        let uMin, uMax, vMin, vMax, uMean, vMean: Double
        let spots: [Spot]
        let bilinear: [Bilinear]
        let packing: Packing
    }

    private var expected: Expected!
    private var messages: [Grib2Decoder.Message]!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        let gribURL = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"),
                                    "wind_fixture.grib2 missing from the test bundle")
        let jsonURL = try XCTUnwrap(bundle.url(forResource: "wind_fixture_expected", withExtension: "json"))
        expected = try JSONDecoder().decode(Expected.self, from: try Data(contentsOf: jsonURL))
        messages = Grib2Decoder.messages(from: try Data(contentsOf: gribURL))
    }

    func testDecodesBothMessagesWithTheExpectedIdentity() {
        XCTAssertEqual(messages.count, expected.messageCount)
        let u = messages.first { $0.paramNumber == 2 }
        let v = messages.first { $0.paramNumber == 3 }
        XCTAssertNotNil(u, "no UGRD message")
        XCTAssertNotNil(v, "no VGRD message")
        for m in messages {
            XCTAssertEqual(m.paramCategory, 2, "wind lives in discipline-0 category 2")
            XCTAssertEqual(m.levelType, expected.levelType)
            XCTAssertEqual(m.levelValue, expected.levelValue)
            XCTAssertEqual(m.forecastHours, expected.forecastHours)
        }
        XCTAssertEqual(WindLevel.from(levelType: expected.levelType, levelValue: expected.levelValue), .mb850)
    }

    func testGridGeometryMatchesTheReference() {
        let m = messages[0]
        XCTAssertEqual(m.ni, expected.ni)
        XCTAssertEqual(m.nj, expected.nj)
        XCTAssertEqual(m.minLat, expected.minLat, accuracy: 1e-9)
        XCTAssertEqual(m.dLat, expected.dLat, accuracy: 1e-9)
        XCTAssertEqual(m.dLon, expected.dLon, accuracy: 1e-9)
        // The payload states longitude in 0…360 (230°); the decoder must hand back the app's −180…180.
        XCTAssertEqual(m.minLon, expected.minLon, accuracy: 1e-9)
        XCTAssertEqual(m.values.count, expected.ni * expected.nj)
    }

    func testReferenceTimeIsParsedAsUTC() throws {
        let iso = ISO8601DateFormatter()
        let want = try XCTUnwrap(iso.date(from: expected.referenceTimeUTC))
        let got = try XCTUnwrap(messages[0].referenceTime)
        XCTAssertEqual(got.timeIntervalSince1970, want.timeIntervalSince1970, accuracy: 0.5)
    }

    /// The simple-packing arithmetic and the bit reader, checked at the extremes and on the mean — a
    /// per-value bit-alignment slip shows up in the mean even when spot checks happen to land right.
    func testUnpackedValueStatisticsMatchTheReference() throws {
        let u = try XCTUnwrap(messages.first { $0.paramNumber == 2 }).values
        let v = try XCTUnwrap(messages.first { $0.paramNumber == 3 }).values
        XCTAssertEqual(Double(u.min() ?? 0), expected.uMin, accuracy: 1e-3)
        XCTAssertEqual(Double(u.max() ?? 0), expected.uMax, accuracy: 1e-3)
        XCTAssertEqual(Double(v.min() ?? 0), expected.vMin, accuracy: 1e-3)
        XCTAssertEqual(Double(v.max() ?? 0), expected.vMax, accuracy: 1e-3)
        XCTAssertEqual(mean(u), expected.uMean, accuracy: 1e-3)
        XCTAssertEqual(mean(v), expected.vMean, accuracy: 1e-3)
    }

    /// Row/column order: scan mode 0x40 means row 0 is the SOUTHERN edge. A grid read without honouring
    /// the flags decodes with identical statistics but renders the wind field upside down, so the spot
    /// checks are indexed by (row-from-south, column-from-west).
    func testGridPointsLandAtTheExpectedIndices() throws {
        XCTAssertEqual(expected.scanMode, 64, "fixture is the +i/+j GFS scan")
        let u = try XCTUnwrap(messages.first { $0.paramNumber == 2 }).values
        let v = try XCTUnwrap(messages.first { $0.paramNumber == 3 }).values
        for s in expected.spots {
            let idx = s.j * expected.ni + s.i
            XCTAssertEqual(Double(u[idx]), s.u, accuracy: 1e-3, "u at (\(s.j),\(s.i))")
            XCTAssertEqual(Double(v[idx]), s.v, accuracy: 1e-3, "v at (\(s.j),\(s.i))")
        }
    }

    // MARK: lenient failure — malformed input must return nothing, never trap

    func testGarbageInputDecodesToNothing() {
        XCTAssertTrue(Grib2Decoder.messages(from: Data()).isEmpty)
        XCTAssertTrue(Grib2Decoder.messages(from: Data(repeating: 0, count: 64)).isEmpty)
        XCTAssertTrue(Grib2Decoder.messages(from: Data("<!DOCTYPE html><html>404".utf8)).isEmpty,
                      "an HTML error page must not decode as weather")
    }

    func testTruncatedMessageIsDropped() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wind_fixture", withExtension: "grib2"))
        let full = try Data(contentsOf: url)
        XCTAssertTrue(Grib2Decoder.messages(from: full.prefix(2000)).isEmpty,
                      "a message whose declared length overruns the buffer must be dropped")
        // A clean first message followed by a truncated second one yields exactly the intact one.
        let firstLen = 49706
        XCTAssertEqual(Grib2Decoder.messages(from: full.prefix(firstLen + 500)).count, 1)
    }

    /// An unsupported edition is dropped WITHOUT losing the rest of the stream: the walk still advances by
    /// the declared message length, so the intact VGRD message behind the corrupted UGRD one survives.
    func testWrongEditionIsDroppedButTheStreamResyncs() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wind_fixture", withExtension: "grib2"))
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[7] = 1                                   // claim GRIB edition 1 on the FIRST message only
        let out = Grib2Decoder.messages(from: Data(bytes))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.paramNumber, 3, "the surviving message is VGRD")

        bytes[49_706 + 7] = 1                          // corrupt the second message's edition too
        XCTAssertTrue(Grib2Decoder.messages(from: Data(bytes)).isEmpty)
    }

    /// A bitmap means some grid points have no data; this decoder does not carry a missing-value path, so
    /// such a message must be dropped rather than decoded with the bitmap ignored (which would shift every
    /// value after the first gap).
    func testBitmappedMessageIsDropped() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "wind_fixture", withExtension: "grib2"))
        var bytes = [UInt8](try Data(contentsOf: url))
        let sectionSix = try XCTUnwrap(indexOfSectionSix(bytes), "no section 6 in the fixture")
        bytes[sectionSix + 5] = 0                      // 0 = a bitmap follows
        XCTAssertEqual(Grib2Decoder.messages(from: Data(bytes)).count, 1,
                       "only the untouched message should decode")
    }

    /// Walk the first message's sections to find section 6, rather than hardcoding an offset.
    private func indexOfSectionSix(_ b: [UInt8]) -> Int? {
        var p = 16
        var hops = 0
        while p + 5 <= b.count && hops < Grib2Decoder.maxSectionsPerMessage {
            if b[p] == 0x37 && b[p + 1] == 0x37 { return nil }
            let len = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            guard len >= 5 else { return nil }
            if b[p + 4] == 6 { return p }
            p += len
            hops += 1
        }
        return nil
    }

    private func mean(_ xs: [Float]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0.0) { $0 + Double($1) } / Double(xs.count)
    }
}
