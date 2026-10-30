import Foundation
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The "where not to go" map: the contiguous US in longitude bands, one byte per ~30 m pixel, each bit
/// a reason NOT to put an aeroplane down there. Built overnight from national sources (`lz/avoid/`).
///
/// It never says where TO land. Unpainted ground is not endorsed: distribution wires, fences, ditches,
/// crops, livestock and surface condition are not mapped anywhere public, and the legend says so.
/// That is the lesson of the landability layer it replaces as the default: data that cannot see what
/// decides a field must not name a field.
enum AvoidReason: UInt8, CaseIterable, Sendable {
    case water = 1, developed = 2, trees = 4, steep = 8
    case orchard = 16, solar = 32, wires = 64, obstacle = 128

    /// The narrow hidden things that wreck an otherwise good-looking field (drawn strong), as against
    /// broad ground cover the pilot can usually see (drawn as a muted wash, and switchable).
    var isHazard: Bool { rawValue >= AvoidReason.orchard.rawValue }

    var title: String {
        switch self {
        case .water:     return "Water or marsh"
        case .developed: return "Built-up area or road"
        case .trees:     return "Trees"
        case .steep:     return "Steep ground"
        case .orchard:   return "Orchard, vineyard or hop poles"
        case .solar:     return "Solar farm"
        case .wires:     return "Power line or utility poles"
        case .obstacle:  return "Tower, turbine or other obstacle"
        }
    }

    static func reasons(in byte: UInt8) -> [AvoidReason] {
        allCases.filter { byte & $0.rawValue != 0 }
    }
}

enum AvoidMap {
    static let format = "avoid1"
    static let schema = "1"
    static let side = 256
    static let minZoom = 8
    static let maxZoom = 12
    static let magic: [UInt8] = Array("AVD1".utf8)

    /// "AVD1" + raw DEFLATE (Apple's COMPRESSION_ZLIB takes no zlib wrapper) of 65,536 bytes.
    /// Anything else is nil — a corrupt tile reads as "no data here", never as "nothing to avoid".
    static func decode(_ data: Data) -> [UInt8]? {
        let n = side * side
        guard data.count > magic.count, Array(data.prefix(magic.count)) == magic else { return nil }
        var out = [UInt8](repeating: 0, count: n)
        let written: Int = data.dropFirst(magic.count).withUnsafeBytes { src in
            guard let base = src.baseAddress else { return 0 }
            return out.withUnsafeMutableBytes { dst in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, n,
                                          base.assumingMemoryBound(to: UInt8.self), src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written == n ? out : nil
    }

    /// The z/x/y tile and the pixel inside it for a coordinate (Web Mercator, XYZ rows).
    static func tilePixel(lon: Double, lat: Double, z: Int) -> (x: Int, y: Int, px: Int, py: Int)? {
        guard (0...24).contains(z), abs(lat) < 85.05, (-180...180).contains(lon) else { return nil }
        let n = Double(1 << z)
        let fx = (lon + 180) / 360 * n
        let r = lat * .pi / 180
        let fy = (1 - asinh(tan(r)) / .pi) / 2 * n
        let x = Int(fx), y = Int(fy)
        guard x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        let px = min(side - 1, Int((fx - Double(x)) * Double(side)))
        let py = min(side - 1, Int((fy - Double(y)) * Double(side)))
        return (x, y, px, py)
    }
}

/// What one installed band says about itself (its MBTiles metadata).
struct AvoidMapInfo: Equatable, Sendable {
    let builtAt: String
    let slopeThresholdDeg: String
    let attribution: String
    let caveat: String
    let fileName: String
    /// The band's name (`w125-w118`) and the z8 tile columns it holds, every zoom below included.
    /// A file without band metadata is one map of everything: "all", every column.
    let shardID: String
    let columns: ClosedRange<Int>
}

/// The installed map: one file per longitude band, one reader each, opened once. A band holds whole
/// z8 tile columns and everything under them, so a tile is always read from exactly ONE file — the band
/// whose columns hold its z8 ancestor — and bands are never merged.
///
/// A new download is swapped in under the lock and a superseded FILE is left for the next launch to
/// delete: deleting a database that a reader still has open poisons that connection (Apple's
/// libsqlite3 invalidates it; see NavDataUpdate).
final class AvoidMapStore: @unchecked Sendable {
    static let shared = AvoidMapStore()
    static let filePrefix = "avoid_"

    let directory: URL
    private let lock = NSLock()
    private var bands: [(reader: MBTilesReader, info: AvoidMapInfo)] = []   // sorted by column, never overlapping

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? base.appendingPathComponent("avoid", isDirectory: true)
    }

    private var removalMarker: URL { directory.appendingPathComponent("remove-on-launch") }

    /// Every installed band, west to east.
    var installed: [AvoidMapInfo] { lock.lock(); defer { lock.unlock() }; return bands.map(\.info) }
    var isInstalled: Bool { !installed.isEmpty }
    /// The OLDEST installed band's build: what the map as a whole can claim to be current to.
    var builtAt: String? { installed.map(\.builtAt).min() }

    /// Change token for render signatures: any band added, replaced or removed is a new map.
    var fingerprint: String { installed.map { "\($0.fileName)|\($0.builtAt)" }.joined(separator: ",") }

    /// Opens the newest valid file for each band and deletes every other copy. Call at launch, before
    /// any tile is served — the one moment no reader can have a superseded copy open.
    func reload() {
        // A removal names the exact files it removed, so bands downloaded AFTER it survive this launch
        // while every removed one goes — even one not re-downloaded, which would otherwise come back as
        // the "newest" copy of its ground.
        if let listed = try? String(contentsOf: removalMarker, encoding: .utf8) {
            for name in listed.split(separator: "\n").map(String.init) where Self.isMapFileName(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: removalMarker)
        }
        let files = Self.candidates(in: directory)                       // newest first
        var kept: [(reader: MBTilesReader, info: AvoidMapInfo)] = []
        for url in files {                                              // bounded: files in one directory
            // Newest first, so a file overlapping one already kept is the older copy of that ground.
            if let band = Self.open(url), !kept.contains(where: { $0.info.columns.overlaps(band.1.columns) }) {
                kept.append((band.0, band.1))
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
        kept.sort { $0.info.columns.lowerBound < $1.info.columns.lowerBound }
        lock.lock(); bands = kept; lock.unlock()
    }

    /// Adopt a verified download as its band, replacing whatever covered those columns. The old file
    /// is NOT deleted here (see the type comment); the next launch's `reload()` drops it as older.
    @discardableResult
    func install(_ downloaded: URL) throws -> AvoidMapInfo {
        let id: String
        do {
            guard let probe = Self.open(downloaded) else { throw CocoaError(.fileReadCorruptFile) }
            id = probe.1.shardID
        }                                                                // the probe closes before the move
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent("\(Self.filePrefix)\(id)-\(UUID().uuidString.prefix(8)).mbtiles")
        try FileManager.default.moveItem(at: downloaded, to: dest)
        guard let (r, i) = Self.open(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw CocoaError(.fileReadCorruptFile)
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var d = dest; try? d.setResourceValues(values)
        lock.lock()
        bands.removeAll { $0.info.columns.overlaps(i.columns) }
        bands.append((r, i))
        bands.sort { $0.info.columns.lowerBound < $1.info.columns.lowerBound }
        lock.unlock()
        return i
    }

    /// Stop serving now; the files go at the next launch's `reload()`. Not deleted here: a tile
    /// request in flight may still hold an old reader, and deleting under it poisons the connection.
    func uninstallKeepingFilesUntilRelaunch() {
        lock.lock(); bands = []; lock.unlock()
        let pending = (try? String(contentsOf: removalMarker, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let names = Set(pending + Self.candidates(in: directory).map(\.lastPathComponent))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? names.sorted().joined(separator: "\n").write(to: removalMarker, atomically: true, encoding: .utf8)
    }

    /// Our own band file names only: nothing in the removal list can reach outside this directory.
    static func isMapFileName(_ name: String) -> Bool {
        name.hasPrefix(filePrefix) && name.hasSuffix(".mbtiles") && !name.contains("/") && !name.contains("..")
    }

    /// The band holding a tile, or nil when that ground is not installed.
    private func reader(z: Int, x: Int) -> MBTilesReader? {
        guard (AvoidMap.minZoom...AvoidMap.maxZoom).contains(z), x >= 0 else { return nil }
        let column = x >> (z - AvoidMap.minZoom)
        lock.lock(); defer { lock.unlock() }
        return bands.first { $0.info.columns.contains(column) }?.reader
    }

    func covers(z: Int, x: Int) -> Bool { reader(z: z, x: x) != nil }

    func mask(z: Int, x: Int, y: Int) -> [UInt8]? {
        guard let r = reader(z: z, x: x), let data = r.tileData(z: z, x: x, y: y) else { return nil }
        return AvoidMap.decode(data)
    }

    /// Every reason at a coordinate (z12, the finest level). Empty = mapped and nothing to report;
    /// nil = this ground is not installed.
    func reasons(lon: Double, lat: Double) -> [AvoidReason]? {
        guard let t = AvoidMap.tilePixel(lon: lon, lat: lat, z: AvoidMap.maxZoom),
              covers(z: AvoidMap.maxZoom, x: t.x) else { return nil }
        guard let m = mask(z: AvoidMap.maxZoom, x: t.x, y: t.y) else { return [] }
        return AvoidReason.reasons(in: m[t.py * AvoidMap.side + t.px])
    }

    static func candidates(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let maps = all.filter { $0.pathExtension == "mbtiles" && $0.lastPathComponent.hasPrefix(filePrefix) }
        let dated = maps.map { u in (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.map(\.0)                  // newest first
    }

    static func open(_ url: URL) -> (MBTilesReader, AvoidMapInfo)? {
        guard let r = MBTilesReader(path: url.path) else { return nil }
        let m = r.metadata
        guard m["format"] == AvoidMap.format, m["avoid_schema"] == AvoidMap.schema else { return nil }
        guard let columns = columns(m["shard_x8"]) else { return nil }
        let info = AvoidMapInfo(builtAt: m["built_at"] ?? "", slopeThresholdDeg: m["slope_threshold_deg"] ?? "",
                                attribution: m["attribution"] ?? "", caveat: m["caveat"] ?? "",
                                fileName: url.lastPathComponent, shardID: m["shard"] ?? "all", columns: columns)
        return (r, info)
    }

    /// "lo,hi" z8 columns; absent means every column. Anything malformed refuses the file.
    static func columns(_ text: String?) -> ClosedRange<Int>? {
        let all = 0...((1 << AvoidMap.minZoom) - 1)
        guard let text else { return all }
        let parts = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] <= parts[1], all.contains(parts[0]), all.contains(parts[1]) else { return nil }
        return parts[0]...parts[1]
    }
}

/// Mask → PNG for the map, through one 256-entry colour table per (theme, cover shown).
final class AvoidTileRenderer: @unchecked Sendable {
    static let shared = AvoidTileRenderer(store: .shared)

    let store: AvoidMapStore
    private let cache = NSCache<NSString, NSData>()

    init(store: AvoidMapStore) {
        self.store = store
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    /// Changes with the map file, the theme and the cover switch, so MapLibre's cache can never serve a
    /// tile painted for something else. Lowercase hex: the server's path parser insists on it.
    func signature(theme: AppTheme, showCover: Bool) -> String? {
        let f = store.fingerprint
        guard !f.isEmpty else { return nil }
        var h: UInt64 = 0xcbf29ce484222325                              // FNV-1a
        for b in Array("\(f)|\(theme.rawValue)|\(showCover)".utf8) { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    func tilePNG(signature: String, theme: AppTheme, showCover: Bool, z: Int, x: Int, y: Int) -> Data? {
        guard signature == self.signature(theme: theme, showCover: showCover) else { return nil }
        let key = "\(signature)/\(z)/\(x)/\(y)" as NSString
        if let hit = cache.object(forKey: key) { return hit as Data }
        guard let mask = store.mask(z: z, x: x, y: y) else { return nil }
        let lut = Self.lut(theme: theme, showCover: showCover)
        var pixels = [UInt32](repeating: 0, count: mask.count)
        var painted = 0
        for i in 0..<mask.count {                                       // bounded: 65,536 pixels
            let c = lut[Int(mask[i])]
            pixels[i] = c
            if c != 0 { painted += 1 }
        }
        guard painted > 0, let png = Self.encodePNG(pixels) else { return nil }   // nothing to say: 404
        cache.setObject(png as NSData, forKey: key, cost: png.count)
        return png
    }

    /// Hazards strong (wires and obstacles over solar over orchards), then steep ground, then — only if
    /// asked for — trees, water and built-up areas as one muted wash. Steep ground is always drawn: unlike
    /// a forest it is hard to judge from the air at night. No green anywhere: nothing here is an invitation.
    static func lut(theme: AppTheme, showCover: Bool) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 256)
        for b in 1..<256 {                                              // bounded: 255 combinations
            if let c = colour(forByte: UInt8(b), theme: theme, showCover: showCover) {
                out[b] = premultiplied(c)
            }
        }
        return out
    }

    /// The one colour table, shared by the tiles and the legend so they cannot drift apart.
    static func colour(forByte byte: UInt8, theme: AppTheme, showCover: Bool) -> (Double, Double, Double, Double)? {
        if let h = [AvoidReason.wires, .obstacle, .solar, .orchard].first(where: { byte & $0.rawValue != 0 }) {
            return colour(h, theme: theme)
        }
        if byte & AvoidReason.steep.rawValue != 0 { return colour(.steep, theme: theme) }
        if showCover, byte != 0 { return colour(.trees, theme: theme) }
        return nil
    }

    static func colour(_ r: AvoidReason, theme: AppTheme) -> (Double, Double, Double, Double) {
        let night = theme == .night
        switch r {
        case .wires, .obstacle: return night ? (0.80, 0.12, 0.06, 0.70) : (1.00, 0.27, 0.00, 0.88)
        case .solar:            return night ? (0.70, 0.42, 0.05, 0.60) : (1.00, 0.84, 0.00, 0.80)
        case .orchard:          return night ? (0.48, 0.16, 0.40, 0.55) : (0.62, 0.30, 0.85, 0.75)
        case .steep:            return night ? (0.45, 0.18, 0.08, 0.40) : (0.62, 0.42, 0.22, 0.48)
        case .water, .developed, .trees:
            return night ? (0.32, 0.10, 0.08, 0.28)
                : (theme == .day ? (0.28, 0.26, 0.24, 0.26) : (0.42, 0.40, 0.38, 0.32))
        }
    }

    /// `premultipliedFirst | byteOrder32Little` reads the word as ARGB: A<<24 | R<<16 | G<<8 | B.
    private static func premultiplied(_ c: (Double, Double, Double, Double)) -> UInt32 {
        let (r, g, b, a) = c
        func ch(_ v: Double) -> UInt32 { UInt32(max(0, min(255, Int((v * 255).rounded())))) }
        return (ch(a) << 24) | (ch(r * a) << 16) | (ch(g * a) << 8) | ch(b * a)
    }

    private static func encodePNG(_ pixels: [UInt32]) -> Data? {
        let side = AvoidMap.side
        var buf = pixels
        let bytes = buf.withUnsafeMutableBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
