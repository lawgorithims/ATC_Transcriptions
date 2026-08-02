import Foundation
import Compression
import MapKit   // MKMapRect — the bounds index in LZPackStore

/// Reader for `.lzpack` — the offline off-field-landability fact tiles built by `lz/package.py`.
///
/// WHAT A PACK HOLDS
/// Seven `uint8` FACT planes per 256x256 tile, plus the tile's DEM provenance. Facts, never verdicts:
/// the pipeline is aircraft-agnostic and position-agnostic, and the score is computed on device so
/// that changing aircraft re-tints the map without re-downloading anything.
///
/// TWO FRAMING DECISIONS THAT MUST MATCH `lz/lzcommon.py` EXACTLY
///  1. RAW DEFLATE. Planes are written by Python with `zlib.compressobj(wbits=-15)` because Apple's
///     `COMPRESSION_ZLIB` is raw DEFLATE with no zlib wrapper. If either side ever grows a 2-byte
///     zlib header the failure is NOT an error — every tile fails to decode and the layer renders
///     fully transparent, which a pilot reads as "no risk here".
///  2. TMS ROWS. `MBTilesReader.tileData` already flips XYZ->TMS on read, so this file addresses
///     tiles in plain XYZ and lets the reader do it. Flipping again here would mirror the cell
///     north-for-south while every count and checksum still looked right.
///
/// CORRUPTION DEGRADES, IT NEVER TRAPS. Same doctrine as `TerrainElevation`: a damaged or truncated
/// pack must return nil and leave the layer blank, not take the app down in flight. Every length in
/// the header is treated as hostile until checked against the actual buffer.
enum LZPack {

    // MARK: - Format constants (mirror lz/lzcommon.py)

    static let magic: [UInt8] = Array("LZP1".utf8)
    static let version: UInt8 = 1
    static let schema = 2      // 2 added `extent`
    static let side = 256
    static let planeCount = 7
    static let planeBytes = side * side          // 65_536

    /// Positional plane order. The device indexes by position, so this must not be reordered.
    static let planeClass = 0
    static let planeConf = 1
    static let planeSlope = 2
    static let planeRough = 3
    static let planeHazard = 4
    static let planeFlags = 5
    static let planeExtent = 6
    static let planeNames = ["class", "conf", "slope", "rough", "hazard", "flags", "extent"]

    /// magic(4) + version(1) + planeCount(1) + side(2) + terrainSource(1) + reserved(1)
    static let headerFixed = 10
    static let headerBytes = headerFixed + 4 * planeCount   // 38

    // Quantisation, mirroring lzcommon.
    static let slopeStepDeg = 0.2
    static let slopeNoData: UInt8 = 255
    static let roughNoData: UInt8 = 255
    static let confUnknown: UInt8 = 255
    static let hazardMax = 255.0

    /// DEM provenance, ordered so that `max` is the conservative aggregate.
    static let terrainFine: UInt8 = 0
    static let terrainMixed: UInt8 = 1
    static let terrainCoarse: UInt8 = 2

    /// Flag bits.
    static let flagDOFTower: UInt8 = 1 << 0
    static let flagTXCorridor: UInt8 = 1 << 1
    static let flagRoadBuffer: UInt8 = 1 << 2
    static let flagWaterVeto: UInt8 = 1 << 3
    static let flagWetland: UInt8 = 1 << 4
    static let flagCoarseTerrain: UInt8 = 1 << 5

    /// Surface classes.
    static let classUnknown: UInt8 = 0
    static let classOpenFirm: UInt8 = 1
    static let classOpenSoft: UInt8 = 2
    static let classCrop: UInt8 = 3
    static let classBrush: UInt8 = 4
    static let classForest: UInt8 = 5
    static let classDevelopedOpen: UInt8 = 6
    static let classDevelopedDense: UInt8 = 7
    static let classBarrenRough: UInt8 = 8
    static let classWater: UInt8 = 9
    static let classWetland: UInt8 = 10
    static let classSnowIce: UInt8 = 11

    static func className(_ v: UInt8) -> String {
        switch v {
        case classOpenFirm: return "open field"
        case classOpenSoft: return "soft ground"
        case classCrop: return "cropland"
        case classBrush: return "brush"
        case classForest: return "forest"
        case classDevelopedOpen: return "open developed"
        case classDevelopedDense: return "built-up"
        case classBarrenRough: return "barren"
        case classWater: return "water"
        case classWetland: return "wetland"
        case classSnowIce: return "snow/ice"
        default: return "unknown"
        }
    }

    /// Decoded slope in degrees, or nil where the DEM had no coverage.
    static func slopeDegrees(_ raw: UInt8) -> Double? {
        raw == slopeNoData ? nil : Double(raw) * slopeStepDeg
    }

    /// Detrended roughness in metres (stored as centimetres), or nil for no coverage.
    static func roughMetres(_ raw: UInt8) -> Double? {
        raw == roughNoData ? nil : Double(raw) / 100.0
    }

    /// Longest open run through this cell, in metres. 10 m per step — exactly one analysis cell, so
    /// there is no quantisation error — mirroring `lzcommon.EXTENT_STEP_M`.
    static let extentStepM = 10.0

    /// 255 does NOT mean 2550 m. It means "at least 2550 m", which is more room than any light
    /// aeroplane can use, so it is a complete answer rather than a truncated one. Callers comparing
    /// against a required landing distance must treat it as sufficient, never as an exact length.
    static let extentSaturated: UInt8 = 255

    static func extentMetres(_ raw: UInt8) -> Double { Double(raw) * extentStepM }

    /// Whether this cell has room for a run of `metres`. Zero means no open ground here at all —
    /// which is a real answer, not missing data.
    static func extentAdmits(_ raw: UInt8, metres: Double) -> Bool {
        raw == extentSaturated || extentMetres(raw) >= metres
    }
}

/// One decoded tile: every plane as `side * side` bytes, plus the tile's DEM provenance.
struct LZTilePlanes {
    let planes: [[UInt8]]
    let terrainSource: UInt8

    /// Sample a plane at a pixel. Bounds-checked; out-of-range reads return nil rather than trap,
    /// because the callers are a render loop and a tap handler, neither of which should be able to
    /// crash the app with an arithmetic slip.
    func value(plane: Int, x: Int, y: Int) -> UInt8? {
        guard plane >= 0, plane < planes.count else { return nil }
        guard x >= 0, x < LZPack.side, y >= 0, y < LZPack.side else { return nil }
        return planes[plane][y * LZPack.side + x]
    }

    var isCoarseTerrain: Bool { terrainSource != LZPack.terrainFine }
}

/// Blob (de)serialisation. Decode-only on device; `lz/package.py` owns the writer.
enum LZPackBlob {

    /// Decode one tile blob. Returns nil for ANY anomaly — wrong magic, unknown version, a length
    /// that overruns the buffer, a stream that inflates to the wrong size. Never throws, never traps.
    static func decode(_ data: Data) -> LZTilePlanes? {
        assert(LZPack.headerBytes == LZPack.headerFixed + 4 * LZPack.planeCount,
               "LZPack header layout drifted from the packer")
        guard data.count >= LZPack.headerBytes else { return nil }

        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == LZPack.magic else { return nil }
        guard bytes[4] == LZPack.version else { return nil }
        guard Int(bytes[5]) == LZPack.planeCount else { return nil }
        let side = Int(bytes[6]) | (Int(bytes[7]) << 8)
        guard side == LZPack.side else { return nil }
        let terrainSource = bytes[8]
        guard terrainSource <= LZPack.terrainCoarse else { return nil }

        var lengths = [Int]()
        lengths.reserveCapacity(LZPack.planeCount)
        for i in 0..<LZPack.planeCount {
            let o = LZPack.headerFixed + 4 * i
            let n = Int(bytes[o]) | (Int(bytes[o + 1]) << 8)
                  | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24)
            // A negative-looking or absurd length is corruption, not a big tile.
            guard n >= 0, n <= data.count else { return nil }
            lengths.append(n)
        }

        var planes = [[UInt8]]()
        planes.reserveCapacity(LZPack.planeCount)
        var offset = LZPack.headerBytes
        for n in lengths {
            guard offset + n <= bytes.count else { return nil }
            guard let raw = inflate(Array(bytes[offset..<(offset + n)])) else { return nil }
            guard raw.count == LZPack.planeBytes else { return nil }
            planes.append(raw)
            offset += n
        }
        assert(planes.count == LZPack.planeCount, "decoded plane count must be fixed")
        return LZTilePlanes(planes: planes, terrainSource: terrainSource)
    }

    /// RAW DEFLATE inflate. `COMPRESSION_ZLIB` in Apple's framework is raw DEFLATE (no zlib
    /// wrapper), which is why the packer uses `wbits=-15`. Output size is known exactly, so this
    /// allocates once and rejects anything that does not fill it.
    private static func inflate(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        let capacity = LZPack.planeBytes
        var out = [UInt8](repeating: 0, count: capacity)
        let written = out.withUnsafeMutableBufferPointer { dst -> Int in
            guard let dstBase = dst.baseAddress else { return 0 }
            return input.withUnsafeBufferPointer { src -> Int in
                guard let srcBase = src.baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, capacity,
                                                 srcBase, src.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == capacity else { return nil }
        return out
    }
}

/// Mounts every `.lzpack` the pilot has installed and answers tile lookups from them.
///
/// Storage mirrors `ChartLibrary`: `Application Support/lz/`, excluded from backup, NEVER
/// `.cachesDirectory` — iOS purges caches under storage pressure, and a pilot's offline kit
/// vanishing mid-flight with no warning is the failure that rule exists to prevent.
final class LZPackStore {

    /// Far above any plausible install; exists so a directory full of junk cannot spin forever.
    private static let maxPacks = 64

    /// A mounted pack plus the rect it covers, resolved ONCE at mount.
    ///
    /// Without this, `planes(z:x:y:)` asked every pack for every tile and relied on SQLite to say
    /// "no such row" — an O(packs) query storm on the tile-serving hot path, for a question the
    /// pack's own `bounds` answers for free. Harmless with one pack, which is all there ever was;
    /// a region is a dozen, and a served tile is on a MapLibre worker thread with a frame waiting.
    struct Mounted {
        let reader: MBTilesReader
        let rect: MKMapRect
    }

    private(set) var mounted: [Mounted] = []
    private(set) var rejected: [String] = []
    let directory: URL

    /// The mounted readers, in mount order. Kept as the public surface because callers care about
    /// packs, not about the bounds index that makes lookups cheap.
    var readers: [MBTilesReader] { mounted.map(\.reader) }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        assert(!self.directory.path.isEmpty, "LZPackStore: empty pack directory")
        reload()
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        var d = base.appendingPathComponent("lz", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        return d
    }

    /// Rescan the directory. Mounts only files that open AND declare a schema this build knows:
    /// a pack from a newer pipeline is REFUSED rather than read as garbage, and the refusal is
    /// recorded so the UI can say why instead of showing an empty map.
    func reload() {
        mounted.removeAll()
        rejected.removeAll()
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: directory,
                                               includingPropertiesForKeys: nil)) ?? []
        let packs = all.filter { $0.pathExtension.lowercased() == "lzpack" }
                       .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in packs {
            guard mounted.count < Self.maxPacks else { break }
            guard let r = MBTilesReader(path: url.path) else {
                rejected.append("\(url.lastPathComponent): unreadable")
                continue
            }
            let declared = Int(r.metadata["lz_schema"] ?? "") ?? -1
            guard declared == LZPack.schema else {
                rejected.append("\(url.lastPathComponent): schema \(declared) != \(LZPack.schema)")
                continue
            }
            guard r.metadata["lz_planes"] == LZPack.planeNames.joined(separator: ",") else {
                rejected.append("\(url.lastPathComponent): plane order mismatch")
                continue
            }
            mounted.append(Mounted(reader: r, rect: Self.coveredRect(r)))
        }
        assert(mounted.count <= Self.maxPacks, "LZPackStore: pack cap exceeded")
        assert(rejected.count <= packs.count, "LZPackStore: more rejections than files")
    }

    /// The MKMapRect a z/x/y tile covers. `MKMapRect` IS the Web Mercator square normalised to
    /// `MKMapSize.world`, so this is exact and needs no trigonometry — the tile grid at zoom z is
    /// just the world divided into 2^z along each axis.
    static func tileRect(z: Int, x: Int, y: Int) -> MKMapRect {
        let side = MKMapSize.world.width / Double(1 << z)
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }

    /// What a pack ACTUALLY covers, derived from the tile addresses it stores — not from the
    /// `bounds` it claims in metadata.
    ///
    /// Bounds metadata is a claim, and a pack whose claim disagrees with its contents would have
    /// every real tile silently skipped by the index below. That is not hypothetical: the test
    /// fixture is a synthetic four-tile pack whose addresses sit nowhere near the cell its metadata
    /// names, and trusting `bounds` made it serve nothing at all. The stored extent cannot lie.
    ///
    /// Falls back to the whole world when the pack is empty or the query fails — degraded to the
    /// old per-tile-query behaviour, which is slow but correct. Fast-but-wrong is not a trade worth
    /// making with the ground under an aeroplane.
    static func coveredRect(_ r: MBTilesReader) -> MKMapRect {
        guard let e = r.tileExtent(z: r.minZoom) else { return .world }
        let a = tileRect(z: r.minZoom, x: e.minX, y: e.minY)
        let b = tileRect(z: r.minZoom, x: e.maxX, y: e.maxY)
        let rect = a.union(b)
        return rect.isNull || rect.isEmpty ? .world : rect
    }

    var isAvailable: Bool { !mounted.isEmpty }

    /// Identity of the mounted SET — every pack id paired with its build stamp, sorted.
    ///
    /// The tile cache and the served tile URL both key on a signature derived from this. Keying on
    /// the pack COUNT instead (what this replaced) meant installing one cell and removing another
    /// left the signature unchanged, so the map went on serving cached tiles composited from a pack
    /// that is no longer mounted — stale ground under a pilot, indistinguishable from correct.
    /// Rebuilding a pack under the same filename has the same shape, which is why the stamp is in
    /// here and not just the id.
    var packFingerprint: String {
        mounted
            .map { "\($0.reader.packID):\($0.reader.metadata["built_at"] ?? "?")" }
            .sorted()
            .joined(separator: "|")
    }

    /// Data vintages, for the "what does this layer know, and how old is it" line on the card.
    var vintages: [String: String] {
        var out: [String: String] = [:]
        for r in readers {
            if let v = r.metadata["lz_vintages"] { out[r.packID] = v }
        }
        return out
    }

    /// Decode the tile at an XYZ address from the first pack that holds it.
    /// `MBTilesReader` performs the TMS row flip, so the address stays XYZ here.
    ///
    /// Rejects by BOUNDS before touching SQLite. Over a region of cells the overwhelmingly common
    /// case is "this tile is not in this pack", and answering that from a rect the pack already
    /// declared costs a comparison instead of a query.
    func planes(z: Int, x: Int, y: Int) -> LZTilePlanes? {
        guard z >= 0, z <= 24 else { return nil }
        guard x >= 0, y >= 0 else { return nil }
        let want = Self.tileRect(z: z, x: x, y: y)
        for m in mounted {                                   // bounded by maxPacks (rule 2)
            guard z >= m.reader.minZoom, z <= m.reader.maxZoom else { continue }
            guard m.rect.intersects(want) else { continue }
            if let data = m.reader.tileData(z: z, x: x, y: y), let p = LZPackBlob.decode(data) {
                return p
            }
        }
        return nil
    }

    /// The deepest zoom any mounted pack stores. The map declares this as the source's true
    /// maxzoom so MapLibre magnifies on the GPU past it instead of asking for tiles that
    /// do not exist.
    var maxZoom: Int { readers.map { $0.maxZoom }.max() ?? LZPack.schema }
    var minZoom: Int { readers.map { $0.minZoom }.min() ?? 0 }
}
