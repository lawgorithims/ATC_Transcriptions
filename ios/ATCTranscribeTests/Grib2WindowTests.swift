import XCTest
@testable import ATCTranscribe

/// Builds a complete GRIB2 message around a chosen payload, so the template-5.41 (PNG) path can be
/// tested end to end without committing a 364 KB MRMS fixture.
///
/// Every octet offset below is the one the decoder reads, which is the point: if a section layout here
/// and in `Grib2Decoder` ever disagree, these tests fail rather than the field coming out plausible and
/// wrong.
enum GribFixture {

    /// A message shaped like the real MRMS echo-top product, measured from a live file on 2026-11-04:
    /// discipline 209, grid template 3.0, product template 4.0 (category 3, number 45, level type 102),
    /// DRS template 5.41 with R = −3000, E = 0, D = 3, 16 bits, and no bitmap.
    static func message(ni: Int, nj: Int,
                        la1: Double, lo1: Double, dLat: Double, dLon: Double,
                        scanMode: UInt8,
                        discipline: UInt8 = 209,
                        drsTemplate: Int = 41,
                        r: Float = -3_000, e: Int = 0, d: Int = 3, bits: Int = 16,
                        payload: [UInt8],
                        reference: DateComponents = DateComponents(year: 2026, month: 11, day: 4,
                                                                   hour: 3, minute: 20, second: 40))
                        -> Data {
        var body: [UInt8] = []

        // ---- section 1 (identification), 21 octets ----
        var s1 = [UInt8](repeating: 0, count: 21)
        put32(&s1, 0, 21); s1[4] = 1
        put16(&s1, 12, reference.year!)
        s1[14] = UInt8(reference.month!); s1[15] = UInt8(reference.day!)
        s1[16] = UInt8(reference.hour!); s1[17] = UInt8(reference.minute!)
        s1[18] = UInt8(reference.second!)
        body += s1

        // ---- section 3 (grid definition), 72 octets, template 3.0 ----
        var s3 = [UInt8](repeating: 0, count: 72)
        put32(&s3, 0, 72); s3[4] = 3
        put32(&s3, 6, ni * nj)                  // number of data points
        put16(&s3, 12, 0)                       // grid template 3.0
        put32(&s3, 30, ni)
        put32(&s3, 34, nj)
        putSM32(&s3, 46, Int((la1 * 1e6).rounded()))
        putSM32(&s3, 50, Int((lo1 * 1e6).rounded()))
        s3[54] = 0x30                           // resolution/component flags, as MRMS writes them
        put32(&s3, 63, Int((dLon * 1e6).rounded()))
        put32(&s3, 67, Int((dLat * 1e6).rounded()))
        s3[71] = scanMode
        body += s3

        // ---- section 4 (product definition), 34 octets, template 4.0 ----
        var s4 = [UInt8](repeating: 0, count: 34)
        put32(&s4, 0, 34); s4[4] = 4
        put16(&s4, 7, 0)                        // product template 4.0
        s4[9] = 3                               // parameter category
        s4[10] = 45                             // parameter number (MRMS echo top, discipline 209)
        s4[17] = 0                              // time unit: minutes
        put32(&s4, 18, 0)                       // forecast time 0 — an observation
        s4[22] = 102                            // fixed surface: altitude above MSL
        s4[23] = 0                              // scale factor
        putSM32(&s4, 24, 500)
        body += s4

        // ---- section 5 (data representation), 21 octets ----
        var s5 = [UInt8](repeating: 0, count: 21)
        put32(&s5, 0, 21); s5[4] = 5
        put32(&s5, 5, ni * nj)
        put16(&s5, 9, drsTemplate)
        let rb = r.bitPattern
        s5[11] = UInt8(rb >> 24); s5[12] = UInt8((rb >> 16) & 0xFF)
        s5[13] = UInt8((rb >> 8) & 0xFF); s5[14] = UInt8(rb & 0xFF)
        putSM16(&s5, 15, e)
        putSM16(&s5, 17, d)
        s5[19] = UInt8(bits)
        s5[20] = 0                              // original field values: floating point
        body += s5

        // ---- section 6 (bitmap), 6 octets, indicator 255 = none ----
        var s6 = [UInt8](repeating: 0, count: 6)
        put32(&s6, 0, 6); s6[4] = 6; s6[5] = 255
        body += s6

        // ---- section 7 (data) ----
        var s7 = [UInt8](repeating: 0, count: 5)
        put32(&s7, 0, payload.count + 5); s7[4] = 7
        body += s7 + payload

        // ---- section 0 (indicator) + "7777" ----
        let total = 16 + body.count + 4
        var s0 = [UInt8](repeating: 0, count: 16)
        s0[0] = 0x47; s0[1] = 0x52; s0[2] = 0x49; s0[3] = 0x42      // "GRIB"
        s0[6] = discipline
        s0[7] = 2                                                   // edition 2
        for k in 0..<8 { s0[8 + k] = UInt8((total >> (8 * (7 - k))) & 0xFF) }
        return Data(s0 + body + [0x37, 0x37, 0x37, 0x37])
    }

    static func put16(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8((v >> 8) & 0xFF); b[i + 1] = UInt8(v & 0xFF)
    }
    static func put32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        for k in 0..<4 { b[i + k] = UInt8((v >> (8 * (3 - k))) & 0xFF) }
    }
    /// GRIB2 signed integers are SIGN-MAGNITUDE, not two's complement.
    static func putSM16(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        put16(&b, i, v < 0 ? (0x8000 | -v) : v)
    }
    static func putSM32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        put32(&b, i, v < 0 ? (0x8000_0000 | -v) : v)
    }
}

/// The windowed decode path, and the template-5.41 payload it exists for.
final class Grib2WindowTests: XCTestCase {

    // MARK: - the simple-packing window, cross-checked against the whole-field decode

    /// ⚠️ THE STRONGEST TEST IN THIS FILE, and it needs no expectations of its own.
    ///
    /// `wind_fixture.grib2` is a real NOMADS payload the whole-field decoder is already pinned against
    /// by `Grib2DecoderTests` (independently, via `wind_fixture_expected.json`). So windowing it and
    /// comparing cell for cell against that decode tests the window arithmetic — the geographic/stored
    /// index mapping, the scan-mode handling, the corner cases — without inventing a second set of
    /// numbers that could be wrong in the same direction.
    ///
    /// It is also the only test of the arbitrary-bit-offset reader on a payload that needs it: the
    /// fixture packs at **10 bits per value**, so three values in four straddle an octet boundary. A
    /// byte-aligned reader passes a 8- or 16-bit test and fails here.
    func testEveryWindowedCellMatchesTheWholeFieldDecodeExactly() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"))
        let data = try Data(contentsOf: url)
        let full = try XCTUnwrap(Grib2Decoder.messages(from: data).first)
        XCTAssertEqual(full.discipline, 0, "GFS wind is discipline 0")

        let boxes: [(ClosedRange<Double>, ClosedRange<Double>, String)] = [
            (20.0...55.0, (-130.0)...(-60.0), "the whole grid"),
            (33.0...42.0, (-105.0)...(-95.0), "a mid-grid box"),
            (20.0...21.0, (-130.0)...(-129.0), "the south-west corner"),
            (54.0...55.0, (-61.0)...(-60.0), "the north-east corner"),
            (37.1...37.4, (-97.3)...(-97.1), "a sliver off the gridlines"),
        ]
        var compared = 0
        for (lat, lon, what) in boxes {
            let w = try XCTUnwrap(
                Grib2Decoder.windows(from: data, latRange: lat, lonRange: lon)
                    .first { $0.paramNumber == full.paramNumber },
                "no window for \(what)")
            for j in 0..<w.nj {
                let gj = Int(((w.lat(ofRow: j) - full.minLat) / full.dLat).rounded())
                for i in 0..<w.ni {
                    let gi = Int(((w.lon(ofCol: i) - full.minLon) / full.dLon).rounded())
                    XCTAssertTrue(gj >= 0 && gj < full.nj && gi >= 0 && gi < full.ni,
                                  "\(what): window cell outside the source grid")
                    XCTAssertEqual(w.values[j * w.ni + i], full.values[gj * full.ni + gi],
                                   "\(what): value disagrees at window (\(j),\(i))")
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(compared, 40_000, "the boxes above really do cover the grid")
    }

    /// A box that straddles an edge is INCLUDED, not clipped — the caller is asking what weather is
    /// near them, and dropping a cell because its centre fell 300 m outside is the wrong way to round.
    func testAStraddlingEdgeIsIncludedRatherThanClipped() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"))
        let data = try Data(contentsOf: url)
        // 0.25° grid from 20.0 / −130.0. Ask for a box inside one cell.
        let w = try XCTUnwrap(Grib2Decoder.windows(from: data,
                                                   latRange: 30.10...30.20,
                                                   lonRange: (-100.10)...(-100.05)).first)
        XCTAssertEqual(w.minLat, 30.0, accuracy: 1e-9, "floored to the gridline below")
        XCTAssertEqual(w.minLon, -100.25, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(w.nj, 2, "and extended to the gridline above")
        XCTAssertGreaterThanOrEqual(w.ni, 2)
    }

    /// Off the grid entirely must yield NOTHING. Clamping the indices without this check would return a
    /// one-cell window of weather two thousand miles away, which is far worse than no window.
    func testARequestOffTheGridYieldsNoWindow() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"))
        let data = try Data(contentsOf: url)
        XCTAssertTrue(Grib2Decoder.windows(from: data, latRange: 45.0...50.0,
                                           lonRange: 2.0...8.0).isEmpty, "Europe")
        XCTAssertTrue(Grib2Decoder.windows(from: data, latRange: 10.0...15.0,
                                           lonRange: (-160.0)...(-150.0)).isEmpty, "mid-Pacific")
        XCTAssertTrue(Grib2Decoder.windows(from: data, latRange: (-40.0)...(-30.0),
                                           lonRange: (-70.0)...(-60.0)).isEmpty, "South America")
    }

    func testAnOutOfRangeRequestIsRefusedRatherThanClamped() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"))
        let data = try Data(contentsOf: url)
        XCTAssertTrue(Grib2Decoder.windows(from: data, latRange: 80.0...100.0,
                                           lonRange: (-100.0)...(-90.0)).isEmpty)
        XCTAssertTrue(Grib2Decoder.windows(from: data, latRange: 30.0...40.0,
                                           lonRange: (-200.0)...(-90.0)).isEmpty)
    }

    // MARK: - template 5.41, the PNG payload

    /// A 16-bit grey raster through the whole stack: `value = (R + X·2^E) / 10^D` with the real MRMS
    /// packing parameters, on a north-down grid like the real one.
    func testAPNGPayloadDecodesWithTheMRMSPackingParameters() throws {
        let ni = 6, nj = 4
        // X values chosen so the decoded value is a round number of kilometres: (−3000 + X)/1000.
        // Row 0 is the NORTHERNMOST, because scan mode 0x00 runs north → south.
        let xs: [[UInt16]] = [
            [3000, 3000, 3000, 3000, 3000, 3000],          //  0.0 km, the whole top row
            [2000, 2700, 15000, 18000, 2700, 2000],        // −1.0 (no echo), −0.3, 12.0, 15.0, …
            [2000, 3500, 16000, 12000, 3500, 2000],
            [0, 0, 0, 0, 0, 0],                            // −3.0 km: no radar coverage
        ]
        let png = PNGFixture.grey(rows: xs, bitDepth: 16, filters: [0, 1, 2, 4])
        let grib = GribFixture.message(ni: ni, nj: nj, la1: 40.03, lo1: 260.0,
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00, payload: png)

        // The whole-field path must REFUSE a PNG payload: materialising such a grid is the thing the
        // windowed path exists to avoid, so it is rejected rather than quietly allocated.
        XCTAssertTrue(Grib2Decoder.messages(from: grib).isEmpty,
                      "messages(from:) must not accept template 5.41")

        let w = try XCTUnwrap(Grib2Decoder.windows(from: grib,
                                                   latRange: 39.9...40.1,
                                                   lonRange: (-100.1)...(-99.9)).first)
        XCTAssertEqual(w.discipline, 209, "MRMS lives in NCEP's local-use discipline")
        XCTAssertEqual(w.paramCategory, 3)
        XCTAssertEqual(w.paramNumber, 45)
        XCTAssertEqual(w.levelType, 102)
        XCTAssertEqual(w.ni, ni)
        XCTAssertEqual(w.nj, nj)
        XCTAssertEqual(w.referenceTime,
                       DateComponents(calendar: Calendar(identifier: .gregorian),
                                      timeZone: TimeZone(identifier: "UTC"),
                                      year: 2026, month: 11, day: 4,
                                      hour: 3, minute: 20, second: 40).date)

        // ⚠️ ROW ORDER. The window is normalised SOUTH-UP, and the source scans north-down, so window
        // row 0 must be the source's LAST row. Read the other way the grid is mirrored north-for-south
        // and every storm appears on the wrong side of the aeroplane.
        XCTAssertEqual(w.minLat, 40.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(w.value(row: 0, col: 0)), -3.0, accuracy: 1e-4,
                       "window row 0 is the southern edge, which is the source's row 3")
        XCTAssertEqual(try XCTUnwrap(w.value(row: 3, col: 0)), 0.0, accuracy: 1e-4,
                       "and window row 3 is the source's row 0")
        XCTAssertEqual(try XCTUnwrap(w.value(row: 2, col: 2)), 12.0, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(w.value(row: 2, col: 3)), 15.0, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(w.value(row: 1, col: 2)), 13.0, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(w.value(row: 1, col: 0)), -1.0, accuracy: 1e-4,
                       "the no-echo sentinel survives as the negative number it is")
    }

    /// Longitude arrives in 0…360 and must come out in the app's −180…180.
    func testLongitudeIsNormalisedOutOfTheGribConvention() throws {
        let png = PNGFixture.grey(rows: [[9_000, 9_100], [9_200, 9_300]],
                                  bitDepth: 16, filters: [0, 0])
        let grib = GribFixture.message(ni: 2, nj: 2, la1: 27.01, lo1: 262.5,   // 262.5 = −97.5
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00, payload: png)
        let w = try XCTUnwrap(Grib2Decoder.windows(from: grib, latRange: 26.9...27.1,
                                                   lonRange: (-97.6)...(-97.4)).first)
        XCTAssertEqual(w.minLon, -97.5, accuracy: 1e-9)
        XCTAssertEqual(w.lon(ofCol: 1), -97.49, accuracy: 1e-9)
    }

    /// A south-up PNG grid must NOT be flipped. The scan-mode flags are honoured rather than trusted,
    /// so both polarities have to be exercised or the mirror bug hides in whichever one is untested.
    func testASouthUpScanIsLeftAlone() throws {
        // scan mode 0x40 sets the j-positive bit: rows run south → north.
        let png = PNGFixture.grey(rows: [[4_000, 4_000], [20_000, 20_000]],
                                  bitDepth: 16, filters: [0, 0])
        let grib = GribFixture.message(ni: 2, nj: 2, la1: 30.00, lo1: 265.0,
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x40, payload: png)
        let w = try XCTUnwrap(Grib2Decoder.windows(from: grib, latRange: 29.9...30.1,
                                                   lonRange: (-95.1)...(-94.9)).first)
        XCTAssertEqual(try XCTUnwrap(w.value(row: 0, col: 0)), 1.0, accuracy: 1e-4,
                       "source row 0 IS the southern edge here, so it stays at window row 0")
        XCTAssertEqual(try XCTUnwrap(w.value(row: 1, col: 0)), 17.0, accuracy: 1e-4)
    }

    /// The raster must BE the grid. A section 3 and a section 7 that disagree about the field's shape
    /// give no safe way to choose which one is lying, so the message is dropped.
    func testARasterThatDisagreesWithTheGridIsDropped() throws {
        let png = PNGFixture.grey(rows: [[1, 2, 3], [4, 5, 6]], bitDepth: 16, filters: [0, 0])
        let grib = GribFixture.message(ni: 4, nj: 2, la1: 40.01, lo1: 260.0,      // says 4 wide
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00, payload: png)
        XCTAssertTrue(Grib2Decoder.windows(from: grib, latRange: 39.9...40.1,
                                           lonRange: (-100.1)...(-99.9)).isEmpty)
    }

    /// The bit width in section 5 must match the raster's depth, for the same reason.
    func testABitWidthThatDisagreesWithTheRasterDepthIsDropped() throws {
        let png = PNGFixture.grey(rows: [[1, 2], [3, 4]], bitDepth: 8, filters: [0, 0])
        let grib = GribFixture.message(ni: 2, nj: 2, la1: 40.01, lo1: 260.0,
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00,
                                       bits: 16, payload: png)                    // says 16, raster is 8
        XCTAssertTrue(Grib2Decoder.windows(from: grib, latRange: 39.9...40.1,
                                           lonRange: (-100.1)...(-99.9)).isEmpty)
    }

    /// Disciplines outside the supported set are refused, so a foreign product cannot have its numbers
    /// read against the wrong parameter table.
    func testAnUnsupportedDisciplineIsRefused() throws {
        let png = PNGFixture.grey(rows: [[1, 2], [3, 4]], bitDepth: 16, filters: [0, 0])
        let grib = GribFixture.message(ni: 2, nj: 2, la1: 40.01, lo1: 260.0,
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00,
                                       discipline: 10,              // oceanographic
                                       payload: png)
        XCTAssertTrue(Grib2Decoder.windows(from: grib, latRange: 39.9...40.1,
                                           lonRange: (-100.1)...(-99.9)).isEmpty)
        XCTAssertEqual(Grib2Decoder.supportedDisciplines, [0, 209])
    }

    func testAnUnsupportedDRSTemplateIsRefused() throws {
        let png = PNGFixture.grey(rows: [[1, 2], [3, 4]], bitDepth: 16, filters: [0, 0])
        let grib = GribFixture.message(ni: 2, nj: 2, la1: 40.01, lo1: 260.0,
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00,
                                       drsTemplate: 40,             // JPEG2000 — not implemented
                                       payload: png)
        XCTAssertTrue(Grib2Decoder.windows(from: grib, latRange: 39.9...40.1,
                                           lonRange: (-100.1)...(-99.9)).isEmpty)
    }

    /// Garbage in, empty out — never a trap. The decoder is fed by the network.
    func testMalformedInputYieldsNothingAndNeverTraps() {
        XCTAssertTrue(Grib2Decoder.windows(from: Data(), latRange: 20...30,
                                           lonRange: (-100)...(-90)).isEmpty)
        XCTAssertTrue(Grib2Decoder.windows(from: Data(repeating: 0xAB, count: 4_096),
                                           latRange: 20...30, lonRange: (-100)...(-90)).isEmpty)
        let png = PNGFixture.grey(rows: [[1, 2], [3, 4]], bitDepth: 16, filters: [0, 0])
        let grib = GribFixture.message(ni: 2, nj: 2, la1: 40.01, lo1: 260.0,
                                       dLat: 0.01, dLon: 0.01, scanMode: 0x00, payload: png)
        for cut in [8, 20, 40, 100, grib.count - 10] where cut > 0 && cut < grib.count {
            _ = Grib2Decoder.windows(from: grib.prefix(cut), latRange: 39.9...40.1,
                                     lonRange: (-100.1)...(-99.9))
        }
    }

    /// The window cap has to be large enough for the box the service actually asks for: 2.5° half-span
    /// at MRMS's 0.01° is 501 × 501.
    func testTheWindowCapFitsTheBoxTheServiceAsksFor() {
        let side = Int((2 * 2.5) / 0.01) + 1
        XCTAssertGreaterThanOrEqual(Grib2Decoder.maxWindowPoints, side * side)
        XCTAssertGreaterThanOrEqual(Grib2Decoder.maxRowPoints, 7_000, "MRMS CONUS row length")
        XCTAssertLessThan(Grib2Decoder.maxGridPoints, 7_000 * 3_500,
                          "the whole-field path must keep refusing the MRMS grid")
    }
}
