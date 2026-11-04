import Foundation
import Compression

/// RFC 1952 (gzip) unwrapping, for the one thing in this app that arrives gzipped: NOAA publishes every
/// MRMS grid as `*.grib2.gz`, and there is no uncompressed variant to ask for.
///
/// ⚠️ APPLE'S `COMPRESSION_ZLIB` IS **RAW DEFLATE**, NOT THE ZLIB OR GZIP CONTAINER. That is already
/// recorded in `LZPack` (whose packer therefore writes `wbits=-15`), and it is the whole reason this file
/// exists: the bytes NOAA serves have a gzip header in front and a CRC/length trailer behind, and handing
/// them straight to `compression_decode_buffer` returns 0 without an error. A silent 0 on a weather
/// decode is the failure mode this app treats as unacceptable, so the container is parsed explicitly and
/// anything unexpected returns nil.
///
/// # The one genuinely useful thing the trailer gives us
///
/// gzip's last four octets are `ISIZE`, the uncompressed length mod 2³². For a 400 KB GRIB that is the
/// exact output size, so the buffer is allocated once at the right size and a stream that inflates to
/// anything else is rejected rather than truncated — the same "output size is known exactly" discipline
/// `LZPackBlob.inflate` uses. It is taken as a HINT and bounded by `maxOutputBytes`, because it is
/// attacker-controlled: a four-byte field can ask for 4 GB.
///
/// NASA/JPL Power-of-Ten: the header walk is bounded by a named cap and a strictly-increasing cursor,
/// every offset is checked against the buffer before it is read, there is no recursion, and corruption
/// returns nil rather than trapping.
enum Gunzip {

    /// Refuse anything that claims to inflate larger than this. The MRMS CONUS echo-top grid — the
    /// largest thing this app gunzips — is 401,853 bytes, so 64 MB is three orders of magnitude of slack
    /// while still being far below the point where the allocation itself is the problem on a phone.
    static let maxOutputBytes = 64 << 20

    /// The optional-field walk (FEXTRA/FNAME/FCOMMENT/FHCRC) cannot run past this many octets.
    static let maxHeaderBytes = 4_096

    /// Header flag bits (RFC 1952 §2.3.1).
    private static let fhcrc = 0x02, fextra = 0x04, fname = 0x08, fcomment = 0x10, freserved = 0xE0

    /// Fixed header (10) + trailer CRC32 and ISIZE (8).
    private static let fixedHeader = 10, trailer = 8

    /// True if these bytes begin with the gzip magic. Cheap enough to call before `inflate`.
    static func isGzip(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Inflate a complete gzip member. Returns nil for ANY anomaly: wrong magic, a compression method
    /// this is not, reserved flags set, a truncated header, an absurd `ISIZE`, or a DEFLATE stream that
    /// does not inflate to exactly the length the trailer claims.
    ///
    /// Only the FIRST member is read. gzip permits concatenated members and NOAA does not use them; a
    /// multi-member file would decode to its first member here, which is why the length check against
    /// `ISIZE` matters — it is what makes that a rejection rather than a silent partial read.
    static func inflate(_ data: Data) -> Data? {
        assert(maxOutputBytes > 0, "Gunzip: output cap must be positive")
        assert(maxHeaderBytes > fixedHeader, "Gunzip: header cap must exceed the fixed header")
        guard data.count > fixedHeader + trailer else { return nil }
        let b = [UInt8](data)
        assert(b.count == data.count, "Gunzip: byte copy changed length")

        guard b[0] == 0x1F, b[1] == 0x8B else { return nil }
        guard b[2] == 8 else { return nil }                      // CM: DEFLATE is the only method defined
        let flags = Int(b[3])
        guard flags & freserved == 0 else { return nil }          // reserved bits set = not a format we know

        // Skip the optional fields, in the order RFC 1952 fixes them.
        var p = fixedHeader
        if flags & fextra != 0 {
            guard p + 2 <= b.count else { return nil }
            let xlen = Int(b[p]) | Int(b[p + 1]) << 8             // ⚠️ LITTLE-endian, unlike GRIB2
            p += 2 + xlen
        }
        if flags & fname != 0 {
            guard let next = zeroTerminated(b, from: p) else { return nil }
            p = next
        }
        if flags & fcomment != 0 {
            guard let next = zeroTerminated(b, from: p) else { return nil }
            p = next
        }
        if flags & fhcrc != 0 { p += 2 }
        guard p >= fixedHeader, p <= maxHeaderBytes, p + trailer < b.count else { return nil }

        // ISIZE, the last four octets, little-endian.
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        guard isize > 0, isize <= maxOutputBytes else { return nil }

        let bodyStart = p, bodyCount = n - trailer - p
        guard bodyCount > 0 else { return nil }

        // ⚠️ THE BUFFER IS ONE OCTET LARGER THAN THE ANSWER, AND THAT OCTET IS THE WHOLE CHECK.
        //
        // `compression_decode_buffer` reports how much it wrote and has NO separate error channel, so
        // a destination exactly `isize` long cannot distinguish "inflated to exactly isize" from
        // "inflated to more than isize and I stopped when I ran out of room" — both return `isize`.
        // Caught by a test that corrupted ISIZE downward and watched a 1,000-octet member decode
        // happily to a 785-octet prefix. With one octet of slack, a stream that produces more than
        // claimed writes `isize + 1` and fails the comparison below.
        var out = [UInt8](repeating: 0, count: isize + 1)
        let written = out.withUnsafeMutableBufferPointer { dst -> Int in
            guard let dstBase = dst.baseAddress else { return 0 }
            return b.withUnsafeBufferPointer { src -> Int in
                guard let srcBase = src.baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, isize + 1,
                                                 srcBase + bodyStart, bodyCount,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        // Exactly `isize` or nothing. A short inflate is a truncated download, and a weather grid that
        // is 90% there decodes to a map with a hole in it rather than to an error.
        guard written == isize else { return nil }
        out.removeLast()
        return Data(out)
    }

    /// Index just past the next NUL at or after `from`, or nil if there is none inside the header cap.
    private static func zeroTerminated(_ b: [UInt8], from: Int) -> Int? {
        assert(from >= 0, "Gunzip: negative field offset")
        guard from < b.count else { return nil }
        var i = from
        let limit = min(b.count, maxHeaderBytes)
        while i < limit {                                   // bounded by the header cap (rule 2)
            if b[i] == 0 { return i + 1 }
            i += 1
        }
        return nil
    }
}
