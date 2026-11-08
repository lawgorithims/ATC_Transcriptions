import XCTest
@testable import ATCTranscribe

/// Builds valid greyscale PNGs in-process, so the decoder can be tested on every filter type and every
/// malformation without a binary fixture.
///
/// The compressed payload uses DEFLATE **stored** blocks (BTYPE=00), which need no compressor: a block
/// is a header octet, LEN, ~LEN, then the literal bytes. That keeps the builder honest — it emits a
/// genuinely valid zlib stream with a real Adler-32, rather than something only this decoder accepts.
enum PNGFixture {

    /// `rows[j]` is one row of samples. `bitDepth` 8 or 16. `filters[j]` picks the row filter, so a
    /// single image can exercise all five.
    static func grey(rows: [[UInt16]], bitDepth: Int, filters: [UInt8],
                     idatChunkSize: Int = 1 << 16) -> [UInt8] {
        precondition(bitDepth == 8 || bitDepth == 16)
        precondition(!rows.isEmpty && rows.allSatisfy { $0.count == rows[0].count })
        precondition(filters.count == rows.count)
        let width = rows[0].count, height = rows.count
        let bpp = bitDepth / 8
        let stride = width * bpp

        // Filter each scanline forward, exactly inverting PNGGrayRows.unfilter.
        var raw: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: stride)
        for j in 0..<height {
            var line = [UInt8](repeating: 0, count: stride)
            for i in 0..<width {
                if bpp == 2 {
                    line[i * 2] = UInt8(rows[j][i] >> 8)
                    line[i * 2 + 1] = UInt8(rows[j][i] & 0xFF)
                } else {
                    line[i] = UInt8(truncatingIfNeeded: rows[j][i])
                }
            }
            let f = filters[j]
            var enc = [UInt8](repeating: 0, count: stride)
            for k in 0..<stride {
                let a = k >= bpp ? Int(line[k - bpp]) : 0
                let b = Int(prev[k])
                let c = k >= bpp ? Int(prev[k - bpp]) : 0
                let pred: Int
                switch f {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = b
                case 3: pred = (a + b) >> 1
                default:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                }
                enc[k] = line[k] &- UInt8(truncatingIfNeeded: pred)
            }
            raw.append(f)
            raw.append(contentsOf: enc)
            prev = line
        }

        // zlib: 0x78 0x01 (CM=8, no dictionary, and 0x7801 % 31 == 0), stored blocks, Adler-32.
        var z: [UInt8] = [0x78, 0x01]
        var off = 0
        repeat {
            let n = min(0xFFFF, raw.count - off)
            let final: UInt8 = (off + n >= raw.count) ? 1 : 0
            z.append(final)
            z.append(UInt8(n & 0xFF)); z.append(UInt8(n >> 8))            // LEN, little-endian
            z.append(UInt8(~n & 0xFF)); z.append(UInt8((~n >> 8) & 0xFF)) // NLEN
            z.append(contentsOf: raw[off..<(off + n)])
            off += n
        } while off < raw.count
        let ad = adler32(raw)
        z.append(contentsOf: [UInt8(ad >> 24), UInt8((ad >> 16) & 0xFF),
                              UInt8((ad >> 8) & 0xFF), UInt8(ad & 0xFF)])

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr: [UInt8] = []
        ihdr += be32(width); ihdr += be32(height)
        ihdr += [UInt8(bitDepth), 0, 0, 0, 0]       // grey, deflate, filter 0, no interlace
        out += chunk("IHDR", ihdr)
        var i = 0
        while i < z.count {                          // split the stream the way NCEP's encoder does
            let n = min(idatChunkSize, z.count - i)
            out += chunk("IDAT", Array(z[i..<(i + n)]))
            i += n
        }
        out += chunk("IEND", [])
        return out
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        let crc = crc32(t + data)
        return be32(data.count) + t + data
             + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func adler32(_ b: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, s: UInt32 = 0
        for byte in b { a = (a + UInt32(byte)) % 65521; s = (s + a) % 65521 }
        return (s << 16) | a
    }

    static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in b {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

final class PNGGrayRowsTests: XCTestCase {

    /// Collect every row the decoder hands back, as 16-bit samples.
    private func decode(_ png: [UInt8], bpp: Int, stopAfter: Int = .max) -> (rows: [[UInt16]], ok: Bool) {
        var rows: [[UInt16]] = []
        let ok = PNGGrayRows.forEachRow(png) { _, row in
            var out: [UInt16] = []
            var i = 0
            while i + bpp <= row.count {
                out.append(bpp == 2 ? UInt16(row[i]) << 8 | UInt16(row[i + 1]) : UInt16(row[i]))
                i += bpp
            }
            rows.append(out)
            return rows.count < stopAfter
        }
        return (rows, ok)
    }

    // MARK: Every filter type

    /// ⚠️ ALL FIVE FILTERS, IN ONE IMAGE, BECAUSE REAL MRMS USES AT LEAST THREE. Sampling every 500th
    /// row of a live CONUS echo-top grid found filter types 1 (Sub), 2 (Up) and 4 (Paeth) in use, and
    /// the encoder picks per row — so a decoder that got Average or Paeth wrong would produce a grid
    /// that was correct in most places and quietly wrong in bands.
    func testEveryFilterTypeRoundTrips() throws {
        let w = 9
        var rows: [[UInt16]] = []
        for j in 0..<5 {
            // A ramp with a wrap, so every filter's modulo-256 arithmetic is actually exercised.
            rows.append((0..<w).map { UInt16((($0 * 37 + j * 91) % 256) * 257) })
        }
        for depth in [8, 16] {
            let bpp = depth / 8
            let png = PNGFixture.grey(rows: rows, bitDepth: depth, filters: [0, 1, 2, 3, 4])
            let (got, ok) = decode(png, bpp: bpp)
            XCTAssertTrue(ok, "depth \(depth) must decode cleanly")
            XCTAssertEqual(got.count, 5)
            for j in 0..<5 {
                let expected = depth == 16 ? rows[j] : rows[j].map { UInt16($0 >> 8) }
                XCTAssertEqual(got[j], expected, "filter \(j) at depth \(depth)")
            }
        }
    }

    /// The zlib stream may be split at ANY octet — NCEP's encoder uses 8 KB chunks. The pieces cannot
    /// be inflated independently, so a decoder that treated each IDAT as its own stream would decode
    /// the first chunk and then fail, which on a real grid is the northern third of CONUS.
    func testASplitIDATStreamIsReassembled() throws {
        let rows = (0..<6).map { j in (0..<11).map { UInt16((($0 + j * 5) % 256) * 257) } }
        let png = PNGFixture.grey(rows: rows, bitDepth: 16, filters: [4, 4, 3, 2, 1, 0],
                                  idatChunkSize: 7)      // deliberately absurd, to split mid-block
        let (got, ok) = decode(png, bpp: 2)
        XCTAssertTrue(ok)
        XCTAssertEqual(got, rows)
    }

    // MARK: Early stop — the mechanism that makes a windowed read cheap

    func testStoppingEarlyIsNotAnError() throws {
        let rows = (0..<40).map { j in [UInt16](repeating: UInt16(j * 100), count: 4) }
        let png = PNGFixture.grey(rows: rows, bitDepth: 16, filters: [UInt8](repeating: 2, count: 40))
        let (got, ok) = decode(png, bpp: 2, stopAfter: 3)
        XCTAssertTrue(ok, "a caller that has seen enough is not a malformation")
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got[2], [200, 200, 200, 200], "and the rows it did get are correct")
    }

    // MARK: The header gate

    func testTheHeaderReportsTheRealGeometry() throws {
        let png = PNGFixture.grey(rows: [[1, 2, 3], [4, 5, 6]], bitDepth: 16, filters: [0, 0])
        let h = try XCTUnwrap(PNGGrayRows.header(png))
        XCTAssertEqual(h.width, 3)
        XCTAssertEqual(h.height, 2)
        XCTAssertEqual(h.bitDepth, 16)
        XCTAssertEqual(h.bytesPerSample, 2)
        XCTAssertEqual(h.stride, 6)
    }

    /// Everything this decoder is NOT is refused at the header, rather than half-decoded. A colour type
    /// it cannot read is the realistic future case: GRIB2 template 5.41 writes 24- and 32-bit fields as
    /// RGB and RGBA rasters, so an MRMS product in that shape must fail loudly here.
    func testUnsupportedPNGShapesAreRefused() throws {
        var png = PNGFixture.grey(rows: [[1, 2], [3, 4]], bitDepth: 8, filters: [0, 0])
        XCTAssertNotNil(PNGGrayRows.header(png))

        func mutated(_ offset: Int, _ value: UInt8) -> [UInt8] {
            var c = png; c[offset] = value; return c
        }
        // IHDR payload starts at octet 16: w(4) h(4) depth colorType compression filter interlace
        XCTAssertNil(PNGGrayRows.header(mutated(25, 2)), "RGB (colour type 2) is not greyscale")
        XCTAssertNil(PNGGrayRows.header(mutated(25, 6)), "RGBA (colour type 6) is not greyscale")
        XCTAssertNil(PNGGrayRows.header(mutated(25, 3)), "palette is not greyscale")
        XCTAssertNil(PNGGrayRows.header(mutated(24, 4)), "sub-byte packing is unsupported")
        XCTAssertNil(PNGGrayRows.header(mutated(28, 1)), "Adam7 interlacing would break row streaming")
        XCTAssertNil(PNGGrayRows.header(mutated(0, 0x88)), "a broken signature")

        png = PNGFixture.grey(rows: [[1]], bitDepth: 8, filters: [0])
        XCTAssertNil(PNGGrayRows.header(Array(png.prefix(20))), "a truncated header")
        XCTAssertNil(PNGGrayRows.header([]))
    }

    /// ⚠️ The zlib two-octet header must be VALIDATED, not merely skipped. Apple's `COMPRESSION_ZLIB` is
    /// raw DEFLATE, so feeding the header through it returns "0 bytes, no error" — and a silent zero on
    /// a weather decode is precisely the failure this app refuses to have.
    func testACorruptZlibHeaderIsRejectedRatherThanSilentlyProducingNothing() throws {
        let rows = [[UInt16]](repeating: [1, 2, 3], count: 3)
        let png = PNGFixture.grey(rows: rows, bitDepth: 16, filters: [0, 0, 0])
        // Find the first IDAT payload octet: 8 signature + 25 IHDR chunk + 8 length/type.
        let idatPayload = 8 + 25 + 8
        XCTAssertEqual(png[idatPayload], 0x78, "the fixture really does start with a zlib header")
        var broken = png
        broken[idatPayload] = 0x79                       // CM becomes 9, and the %31 check fails
        var delivered = 0
        let ok = PNGGrayRows.forEachRow(broken) { _, _ in delivered += 1; return true }
        XCTAssertFalse(ok)
        XCTAssertEqual(delivered, 0)
    }

    /// A truncated DEFLATE stream can deliver plausible rows and then stop. ⚠️ The return value must be
    /// false even though some rows arrived — a grid that is 90% decoded is a map with a hole in it, and
    /// the caller has no other way to tell.
    func testATruncatedStreamFailsEvenThoughSomeRowsArrived() throws {
        let rows = (0..<30).map { j in [UInt16](repeating: UInt16(j), count: 8) }
        let png = PNGFixture.grey(rows: rows, bitDepth: 16, filters: [UInt8](repeating: 1, count: 30))
        let cut = Array(png.prefix(png.count - 120))
        var delivered = 0
        let ok = PNGGrayRows.forEachRow(cut) { _, _ in delivered += 1; return true }
        XCTAssertFalse(ok, "a short stream is a failure, whatever it managed to produce first")
        XCTAssertLessThan(delivered, 30)
    }

    func testAnUnknownFilterTypeIsRejected() throws {
        // Filter 5 does not exist; the spec defines 0...4.
        var png = PNGFixture.grey(rows: [[7, 8, 9]], bitDepth: 8, filters: [0])
        let idatPayload = 8 + 25 + 8
        // zlib header (2) + stored-block header (1) + LEN (2) + NLEN (2) = the first raw octet.
        png[idatPayload + 7] = 5
        XCTAssertFalse(PNGGrayRows.forEachRow(png) { _, _ in true })
    }

    /// Bounded by construction, so a hostile IHDR cannot make the decoder allocate the world.
    func testAbsurdDimensionsAreRefused() throws {
        var png = PNGFixture.grey(rows: [[1, 2], [3, 4]], bitDepth: 8, filters: [0, 0])
        png[16] = 0xFF; png[17] = 0xFF; png[18] = 0xFF; png[19] = 0xFF   // width = 4,294,967,295
        XCTAssertNil(PNGGrayRows.header(png))
        XCTAssertGreaterThan(PNGGrayRows.maxWidth, 7_000, "MRMS CONUS is 7000 wide")
        XCTAssertGreaterThan(PNGGrayRows.maxHeight, 3_500, "and 3500 tall")
    }
}
