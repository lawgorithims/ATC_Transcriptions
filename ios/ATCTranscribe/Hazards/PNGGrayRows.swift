import Foundation
import Compression

/// A **row-streaming** decoder for exactly the PNG shape GRIB2 data-representation template 5.41 writes,
/// and deliberately nothing more: non-interlaced greyscale, 8 or 16 bits per sample, filter method 0.
///
/// # Why not ImageIO, which decodes PNG for free
///
/// Because of one number. The MRMS CONUS grid is 7000 × 3500 at 16 bits, so the decoded bitmap is
/// **49 MB** — and ImageIO's API is "give me the whole image". On a phone that is a 49 MB spike (plus
/// whatever ImageIO holds internally) every two minutes, in an app that is also holding chart tiles, a
/// terrain DEM and a Whisper model, to answer a question about a 200-mile box. Streaming the rows and
/// keeping only the window costs **two row buffers, 28 KB**, and lets the decode stop the moment it is
/// past the southern edge of the window instead of inflating the Gulf of Mexico to throw it away.
///
/// The second reason is narrower but real: CoreGraphics is a *rendering* stack. A 16-bit greyscale PNG
/// comes back through it with a colour space attached and a bitmap-info byte order to interpret, and
/// several plausible paths through it (`CGImageSourceCreateThumbnailAtIndex`, any 8-bit context) quietly
/// resample or narrow the samples. Echo tops resampled downward is an under-warning, which is the one
/// direction this feature must not fail in. The samples here are read as the integers they are.
///
/// This is NOT a general PNG decoder and must not grow into one: no palette, no alpha, no RGB, no
/// interlacing, no 1/2/4-bit packing, no ancillary-chunk interpretation. Every one of those returns nil.
///
/// ⚠️ APPLE'S `COMPRESSION_ZLIB` IS RAW DEFLATE — see `Gunzip` and `LZPack`. PNG's IDAT payload is a
/// *zlib* stream (RFC 1950), so its two-octet header is validated and skipped before the bytes are fed
/// to the framework. Feeding the header through produces a clean "0 bytes, no error", which is why it is
/// checked rather than assumed.
///
/// NASA/JPL Power-of-Ten: every loop is bounded by a named cap; both row buffers are allocated once
/// before the first row; no recursion; every chunk length is range-checked against the buffer before it
/// is read; malformed input returns false and never traps.
enum PNGGrayRows {

    // MARK: Caps (rule 2 — every loop below is bounded by one of these)

    /// MRMS CONUS is 7000 wide; Alaska is 1649. Doubling the widest real grid is ample.
    static let maxWidth = 16_384
    /// MRMS CONUS is 3500 tall.
    static let maxHeight = 8_192
    /// A 400 KB payload at the 8 KB chunk size NCEP's encoder uses is ~50 chunks.
    static let maxChunks = 16_384
    /// The compressed IDAT payload, concatenated. MRMS echo tops is ~400 KB.
    static let maxCompressedBytes = 32 << 20
    /// Safety valve on the inflate pump so a stream that produces nothing can never spin.
    static let maxProcessCalls = 1 << 20

    /// What the IHDR says, once it has been checked against what this decoder supports.
    struct Header: Sendable, Equatable {
        let width: Int
        let height: Int
        /// 8 or 16.
        let bitDepth: Int
        /// 1 or 2. Greyscale, so this is also the stride divisor.
        var bytesPerSample: Int { bitDepth / 8 }
        /// Bytes in one unfiltered row.
        var stride: Int { width * bytesPerSample }
    }

    /// Read and validate the IHDR without decoding anything. Cheap: it touches the first 33 octets.
    static func header(_ b: [UInt8]) -> Header? {
        assert(maxWidth > 0 && maxHeight > 0, "PNGGrayRows: dimension caps must be positive")
        guard b.count >= 33 else { return nil }
        guard b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
              b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A else { return nil }
        // The first chunk must be IHDR, 13 octets of payload.
        guard be32(b, 8) == 13, b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 else {
            return nil
        }
        let w = be32(b, 16), h = be32(b, 20)
        let depth = Int(b[24]), colorType = Int(b[25])
        let compression = Int(b[26]), filterMethod = Int(b[27]), interlace = Int(b[28])
        guard w > 0, h > 0, w <= maxWidth, h <= maxHeight else { return nil }
        guard colorType == 0 else { return nil }            // greyscale only
        guard depth == 8 || depth == 16 else { return nil }  // no sub-byte packing
        guard compression == 0, filterMethod == 0 else { return nil }
        guard interlace == 0 else { return nil }             // Adam7 would break row streaming
        return Header(width: w, height: h, bitDepth: depth)
    }

    /// Stream unfiltered rows top-to-bottom.
    ///
    /// `body(row, bytes)` is handed one complete, **unfiltered** row of `header.stride` octets, in the
    /// PNG's own top-down order — the caller is responsible for knowing which way the grid scans.
    /// Samples are big-endian within the row, as PNG mandates. Returning `false` from `body` stops the
    /// decode immediately and is NOT an error; it is the mechanism that makes a windowed read cheap.
    ///
    /// Returns `true` if every row it was asked for arrived intact, `false` on any malformation. ⚠️ A
    /// `false` return means the rows already delivered cannot be trusted either — a truncated DEFLATE
    /// stream can deliver plausible rows and then stop, and a weather grid that is 90% decoded is a map
    /// with a hole in it rather than an error.
    static func forEachRow(_ b: [UInt8],
                           _ body: (Int, UnsafeBufferPointer<UInt8>) -> Bool) -> Bool {
        assert(maxProcessCalls > 0, "PNGGrayRows: pump cap must be positive")
        guard let h = header(b) else { return false }
        guard let idat = concatenatedIDAT(b) else { return false }
        // zlib header (RFC 1950 §2.2): low nibble of CMF is the compression method (8 = DEFLATE), the
        // pair is a multiple of 31, and a preset dictionary is not permitted in PNG.
        guard idat.count > 2, idat[0] & 0x0F == 8, idat[1] & 0x20 == 0,
              (Int(idat[0]) << 8 | Int(idat[1])) % 31 == 0 else { return false }

        let stride = h.stride
        let bpp = h.bytesPerSample
        // Allocated ONCE, before the first row (rule 3). `rowBuf` carries the filter octet plus the row,
        // which is exactly what the DEFLATE stream produces per scanline.
        var rowBuf = [UInt8](repeating: 0, count: stride + 1)
        var cur = [UInt8](repeating: 0, count: stride)
        var prev = [UInt8](repeating: 0, count: stride)

        // Heap-allocated rather than a local `var`: `compression_stream` is a C struct with no Swift
        // initialiser worth constructing by hand, and `compression_stream_init` fills it in place.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return false }
        defer { compression_stream_destroy(stream) }

        var row = 0
        var stoppedByCaller = false
        var malformed = false

        idat.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { malformed = true; return }
            // The whole payload is in hand, so FINALIZE is correct on every call: it tells the framework
            // no more input is coming. Without it, a pump with an exhausted source returns OK having
            // done nothing, and the loop below would be the one spinning.
            stream.pointee.src_ptr = srcBase + 2            // past the zlib header
            stream.pointee.src_size = src.count - 2

            rowBuf.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { malformed = true; return }
                stream.pointee.dst_ptr = dstBase
                stream.pointee.dst_size = dst.count

                var calls = 0
                while calls < maxProcessCalls {             // bounded (rule 2)
                    calls += 1
                    let status = compression_stream_process(
                        stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                        malformed = true
                        return
                    }
                    // A complete scanline is buffered exactly when the destination filled up.
                    if stream.pointee.dst_size == 0 {
                        guard row < h.height else { malformed = true; return }   // more rows than IHDR
                        // `dst` rather than `rowBuf`: reading the array while its own mutable buffer
                        // pointer is live is an exclusivity violation, and the pointer is the same bytes.
                        guard unfilter(dst, into: &cur, prev: prev, stride: stride, bpp: bpp) else {
                            malformed = true
                            return
                        }
                        let keepGoing = cur.withUnsafeBufferPointer { body(row, $0) }
                        row += 1
                        swap(&prev, &cur)
                        if !keepGoing || row == h.height { stoppedByCaller = !keepGoing; return }
                        stream.pointee.dst_ptr = dstBase
                        stream.pointee.dst_size = dst.count
                    }
                    if status == COMPRESSION_STATUS_END { return }
                }
                malformed = true                            // pump cap hit: treat as corruption
            }
        }

        if malformed { return false }
        // Either the caller stopped early, or the stream must have produced every scanline. A partial
        // last row (dst_size != 0 at END) lands here as `row < height` and is rejected.
        return stoppedByCaller || row == h.height
    }

    // MARK: - filters (PNG spec §9.2; `prev` is the already-unfiltered row above)

    /// Reverse one scanline's filter. `src` is the filter octet followed by `stride` filtered octets.
    private static func unfilter(_ src: UnsafeMutableBufferPointer<UInt8>, into out: inout [UInt8],
                                 prev: [UInt8], stride: Int, bpp: Int) -> Bool {
        assert(src.count == stride + 1, "PNGGrayRows: row buffer sized to filter octet plus stride")
        assert(out.count == stride && prev.count == stride, "PNGGrayRows: row buffers mismatched")
        assert(bpp == 1 || bpp == 2, "PNGGrayRows: greyscale is 1 or 2 octets per sample")
        let filter = src[0]
        // Every arithmetic step below is modulo 256 by specification — `&+` is the operator, not a
        // shortcut. Plain `+` would trap on the first dark-to-light edge in the image.
        switch filter {
        case 0:                                             // None
            for k in 0..<stride { out[k] = src[k + 1] }
        case 1:                                             // Sub
            for k in 0..<stride {
                out[k] = k >= bpp ? src[k + 1] &+ out[k - bpp] : src[k + 1]
            }
        case 2:                                             // Up
            for k in 0..<stride { out[k] = src[k + 1] &+ prev[k] }
        case 3:                                             // Average — the mean is FLOORED, in 9 bits
            for k in 0..<stride {
                let left = k >= bpp ? Int(out[k - bpp]) : 0
                out[k] = src[k + 1] &+ UInt8(truncatingIfNeeded: (left + Int(prev[k])) >> 1)
            }
        case 4:                                             // Paeth
            for k in 0..<stride {
                let a = k >= bpp ? Int(out[k - bpp]) : 0
                let bAbove = Int(prev[k])
                let c = k >= bpp ? Int(prev[k - bpp]) : 0
                let p = a + bAbove - c
                let pa = abs(p - a), pb = abs(p - bAbove), pc = abs(p - c)
                let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? bAbove : c)
                out[k] = src[k + 1] &+ UInt8(truncatingIfNeeded: pred)
            }
        default:
            return false                                    // filter types are 0...4; anything else is corruption
        }
        return true
    }

    // MARK: - chunks

    /// Concatenate every IDAT payload in order. The spec permits splitting the zlib stream at ANY octet
    /// boundary, so the pieces cannot be inflated independently — NCEP's encoder splits at 8 KB.
    /// Concatenating costs the compressed size (~400 KB for MRMS), which is the small number here; it is
    /// the *decoded* 49 MB that this file exists to avoid materialising.
    private static func concatenatedIDAT(_ b: [UInt8]) -> [UInt8]? {
        assert(maxChunks > 0, "PNGGrayRows: chunk cap must be positive")
        var out: [UInt8] = []
        var p = 8                                           // past the signature
        var chunks = 0
        var sawIDAT = false
        while p + 12 <= b.count && chunks < maxChunks {      // bounded: p strictly increases (rule 2)
            let len = be32(b, p)
            // A length that overruns the buffer is corruption, and `p + 12 + len` must not overflow.
            guard len >= 0, len <= maxCompressedBytes, p + 12 + len <= b.count else { return nil }
            let isIDAT = b[p + 4] == 0x49 && b[p + 5] == 0x44 && b[p + 6] == 0x41 && b[p + 7] == 0x54
            let isIEND = b[p + 4] == 0x49 && b[p + 5] == 0x45 && b[p + 6] == 0x4E && b[p + 7] == 0x44
            if isIDAT {
                guard out.count + len <= maxCompressedBytes else { return nil }
                out.append(contentsOf: b[(p + 8)..<(p + 8 + len)])
                sawIDAT = true
            } else if sawIDAT && !isIEND {
                // IDAT chunks must be consecutive (spec §5.6). A chunk between them means either
                // corruption or a layout this decoder has not been reasoned about.
                return nil
            }
            if isIEND { break }
            p += 12 + len
            chunks += 1
        }
        return out.isEmpty ? nil : out
    }

    @inline(__always) private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        assert(i >= 0 && i + 3 < b.count, "PNGGrayRows: be32 out of range")
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
}
