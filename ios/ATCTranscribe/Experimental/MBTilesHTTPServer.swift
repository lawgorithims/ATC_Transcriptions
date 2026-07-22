// EXPERIMENTAL — branch experimental/maplibre-migration. DO NOT MERGE.
//
// A tiny loopback HTTP tile server that bridges our offline `.mbtiles` chart packs to MapLibre. MapLibre's
// raster source wants an http(s) `{z}/{x}/{y}` URL template; our charts live in local SQLite MBTiles. So we
// serve them from 127.0.0.1: MapLibre requests http://127.0.0.1:<port>/{z}/{x}/{y}, and we answer from the
// mounted `MBTilesReader`s (WebP transcoded to PNG, since the MapLibre binary may not decode WebP). This is
// the standard "MBTiles → MapLibre on iOS" technique and is what lets the FAA charts render offline, in the
// cockpit, on the globe.

import Foundation
import Network
import UIKit

/// Serves chart tiles from the currently-mounted MBTiles packs over loopback HTTP. Thread-safe: the tile
/// lookup runs on the listener's queue; `readersProvider` is a closure so the server always serves whatever
/// packs are mounted right now (they change as the user pans / switches layers).
final class MBTilesHTTPServer {
    private var listener: NWListener?
    // CONCURRENT: MapLibre fires many parallel tile requests when filling a region. MBTilesReader is opened
    // FULLMUTEX (thread-safe reads) and the reader-array swap is NSLock-guarded, so tiles can decode/upscale
    // in parallel instead of serializing behind one another on a single serial queue.
    private let queue = DispatchQueue(label: "commsight.mbtiles.http", attributes: .concurrent)
    private(set) var port: UInt16 = 0
    // The mounted packs, handed over from the main actor (ChartStore is @MainActor) and read under the
    // lock on the listener's background queue. MBTilesReader is opened FULLMUTEX so its own tile queries
    // are thread-safe; only the array swap needs guarding.
    private let lock = NSLock()
    private var readers: [MBTilesReader] = []
    // Bounded, self-evicting cache of ready-to-serve PNG bytes keyed "packID/z/x/y", so a re-requested tile
    // skips the SQLite read + WebP transcode / overzoom upscale (mirrors the MKMapView path's shared cache).
    // NSCache is thread-safe, so it needs no extra locking on the concurrent queue.
    private let pngCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>(); c.totalCostLimit = 48 * 1024 * 1024; return c
    }()

    init() {}

    /// Push the current chart packs (call from the main actor whenever they change).
    func setReaders(_ r: [MBTilesReader]) { lock.lock(); readers = r; lock.unlock() }
    private func currentReaders() -> [MBTilesReader] { lock.lock(); defer { lock.unlock() }; return readers }

    // The GLOBE base satellite reader, served on a SEPARATE "/sat/{z}/{x}/{y}" path so it renders as its own
    // opaque bottom layer — the chart layer's transparent collars then composite over satellite, not the sea.
    private var satelliteReader: MBTilesReader?
    func setSatelliteReader(_ r: MBTilesReader?) { lock.lock(); satelliteReader = r; lock.unlock() }
    private func currentSatelliteReader() -> MBTilesReader? { lock.lock(); defer { lock.unlock() }; return satelliteReader }

    /// Start the loopback listener WITHOUT blocking the caller. `onReady` is invoked on the MAIN queue with
    /// the bound port once the listener reaches `.ready` (or 0 on failure) — the caller installs the MapLibre
    /// style then. This replaces the old synchronous `DispatchSemaphore.wait(timeout: 2)`, which parked the
    /// MAIN thread (Coordinator.init runs on it) for up to 2s while the listener bound a port.
    func start(onReady: @escaping (UInt16) -> Void) {
        guard listener == nil else { if port > 0 { onReady(port) }; return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback            // 127.0.0.1 only — never leaves the device
            let l = try NWListener(using: params, on: .any)     // OS picks a free port
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let p = l.port?.rawValue ?? 0
                    self?.port = p
                    DispatchQueue.main.async { onReady(p) }
                case .failed, .cancelled:
                    DispatchQueue.main.async { onReady(0) } // surface the failure instead of a silent 2s stall
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch { DispatchQueue.main.async { onReady(0) } }
    }

    func stop() { listener?.cancel(); listener = nil; port = 0 }

    // MARK: connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, err in
            guard let self, let data, err == nil,
                  let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { conn.cancel(); return }
            // "GET /z/x/y HTTP/1.1"
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { self.respond(conn, status: "400 Bad Request", body: nil); return }
            let path = String(parts[1])
            if path.hasPrefix("/font/") {
                if let pbf = self.glyph(forPath: path) {
                    self.respond(conn, status: "200 OK", contentType: "application/x-protobuf", body: pbf)
                } else {
                    self.respond(conn, status: "404 Not Found", body: nil)
                }
            } else if let tile = self.tile(forPath: path) {
                self.respond(conn, status: "200 OK", contentType: "image/png", body: tile)
            } else {
                self.respond(conn, status: "404 Not Found", body: nil)   // no chart coverage here → transparent
            }
        }
    }

    /// "/8/74/97" or "/8/74/97.png" → PNG tile bytes from the first pack that has it. Bounded scan.
    private func tile(forPath path: String) -> Data? {
        let comps = path.split(separator: "/").map { $0.split(separator: ".").first.map(String.init) ?? String($0) }
        guard comps.count >= 3, let z = Int(comps[comps.count - 3]),
              let x = Int(comps[comps.count - 2]), let y = Int(comps[comps.count - 1]) else { return nil }
        // GLOBE money-shot: the globe style requests through a "/uz/{z}/{x}/{y}" prefix so that when zoomed OUT
        // past a pack's minZoom we composite + downsample its minZoom tiles into a low-res chart draped on the
        // sphere (context, not detail). The flat map keeps the plain "/{z}/{x}/{y}" URL → unchanged (no underzoom).
        let underzoom = comps.first == "uz"
        // "/sat/" → the dedicated satellite base reader ONLY (its own bottom layer). Everything else scans the
        // mounted chart packs. Satellite has z0, so it never needs underzoom; z>maxZoom overzooms as usual.
        let readers = comps.first == "sat" ? (currentSatelliteReader().map { [$0] } ?? []) : currentReaders()
        assert(readers.count <= 64, "unexpectedly many chart packs mounted")
        assert(z >= 0 && z <= 24, "tile: out-of-range zoom")
        for r in readers.prefix(64) {                                    // bounded (rule 2)
            let minServe = underzoom ? max(0, r.minZoom - Self.underzoomLevels) : r.minZoom
            guard z >= minServe, z <= r.maxZoom + MBTilesTileOverlay.overzoomLevels else { continue }
            let key = "\(r.packID)/\(z)/\(x)/\(y)" as NSString
            if let hit = pngCache.object(forKey: key) {
                if hit.length == 0 { continue }        // cached NEGATIVE (this pack has no such tile) → try the next
                return hit as Data
            }
            let out: Data?
            if z > r.maxZoom {
                // Past the pack's data: upscale the deepest ancestor tile (same math as the MKMapView path,
                // MBTilesTileOverlay.overzoomedTile) so the chart stays visible on close-in/approach zoom
                // instead of vanishing to bare OSM. Without this the +overzoomLevels band was dead allowance.
                out = Self.overzoomedPNG(reader: r, z: z, x: x, y: y)
            } else if z < r.minZoom {
                // Below the pack (only reached under the "/uz/" globe prefix): composite the 2^k × 2^k block of
                // minZoom tiles covering this low-zoom tile, each downsampled, so the whole chart drapes on the
                // globe zoomed out. Bounded to underzoomLevels (<=8×8). Transparent where the pack has no data.
                out = Self.underzoomedPNG(reader: r, z: z, x: x, y: y)
            } else if let raw = r.tileData(z: z, x: x, y: y) {           // reader flips XYZ→TMS internally
                if r.format == "png" || r.format == "jpg" || r.format == "jpeg" {
                    out = raw
                } else {
                    // WebP → PNG for MapLibre. A DECODE FAILURE must NOT be served as a mislabeled image/png
                    // (a permanent blank square) nor cached — return no-tile so MapLibre treats it as no coverage.
                    out = UIImage(data: raw)?.pngData()
                }
            } else {
                out = nil                                                // this pack lacks the tile; try the next
            }
            if let out { pngCache.setObject(out as NSData, forKey: key, cost: out.count); return out }
            // Cache the miss (empty sentinel) so an uncovered tile isn't re-scanned via SQLite every request
            // (a pan over open water re-requests the same empties constantly). NSCache still bounds growth.
            pngCache.setObject(NSData(), forKey: key, cost: 1)
        }
        return nil
    }

    /// Upscale the deepest available ancestor tile to cover a z>maxZoom request (mirrors
    /// MBTilesTileOverlay.overzoomedTile; reuses its pure, unit-tested `overzoomSource` math). Bounded.
    private static func overzoomedPNG(reader r: MBTilesReader, z: Int, x: Int, y: Int) -> Data? {
        assert(z > r.maxZoom, "overzoomedPNG called at/below the pack's maxZoom")
        guard let src = MBTilesTileOverlay.overzoomSource(z: z, x: x, y: y, maxZoom: r.maxZoom),
              let raw = r.tileData(z: r.maxZoom, x: src.ax, y: src.ay),
              let img = UIImage(data: raw) else { return nil }
        assert(src.sub > 0, "overzoomedPNG: non-positive sub-tile size")
        let tile: CGFloat = 256
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = false
        let outImg = UIGraphicsImageRenderer(size: CGSize(width: tile, height: tile), format: fmt).image { _ in
            let draw = tile / CGFloat(src.sub)                          // == scale factor
            let size = CGSize(width: img.size.width * draw, height: img.size.height * draw)
            img.draw(in: CGRect(x: -CGFloat(src.ox) * draw, y: -CGFloat(src.oy) * draw,
                                width: size.width, height: size.height))
        }
        return outImg.pngData()
    }

    /// How many zoom levels BELOW a pack's minZoom the "/uz/" globe path will synthesize (a low-res chart draped
    /// on the zoomed-out sphere). k levels down composites a 2^k × 2^k block, so 3 == at most an 8×8 = 64-tile
    /// mosaic per output tile — bounded, and only the tiles the pack actually has are drawn (rest transparent).
    static let underzoomLevels = 3

    /// Build a z(<minZoom) tile by compositing the covering minZoom tiles, each downsampled into its cell. Returns
    /// nil when the pack has NO covering tile here (→ transparent, land base shows through). Bounded (n<=8).
    private static func underzoomedPNG(reader r: MBTilesReader, z: Int, x: Int, y: Int) -> Data? {
        assert(z < r.minZoom, "underzoomedPNG called at/above the pack's minZoom")
        let k = r.minZoom - z
        guard k >= 1, k <= underzoomLevels else { return nil }
        let n = 1 << k                                   // minZoom tiles per side (2, 4, or 8)
        let tile: CGFloat = 256
        let cell = tile / CGFloat(n)                     // each source tile's footprint in the 256px output
        let baseX = x * n, baseY = y * n                 // top-left (north-west) covering tile at minZoom (XYZ)
        var drewAny = false
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = false
        let outImg = UIGraphicsImageRenderer(size: CGSize(width: tile, height: tile), format: fmt).image { _ in
            for row in 0..<n {                           // bounded (rule 2): n <= 8
                for col in 0..<n {                       // bounded (rule 2): n <= 8
                    guard let raw = r.tileData(z: r.minZoom, x: baseX + col, y: baseY + row),  // XYZ→TMS internal
                          let img = UIImage(data: raw) else { continue }                       // missing → transparent
                    img.draw(in: CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                    drewAny = true
                }
            }
        }
        return drewAny ? outImg.pngData() : nil
    }

    /// "/font/Arial%20Bold/0-255.pbf" → the bundled SDF glyph PBF for that fontstack + range. MapLibre
    /// needs these to render any symbol-layer TEXT; we serve them from the app bundle so labels work offline.
    private func glyph(forPath path: String) -> Data? {
        let comps = path.split(separator: "/")     // ["font", "<fontstack>", "<range>.pbf"]
        guard comps.count >= 3 else { return nil }
        let fontstack = String(comps[comps.count - 2]).removingPercentEncoding ?? String(comps[comps.count - 2])
        let file = String(comps[comps.count - 1])
        let range = (file.hasSuffix(".pbf") ? String(file.dropLast(4)) : file)
        assert(!fontstack.isEmpty && !range.isEmpty, "glyph: empty fontstack/range")
        guard let url = Bundle.main.url(forResource: range, withExtension: "pbf",
                                        subdirectory: "glyphs/\(fontstack)") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func respond(_ conn: NWConnection, status: String, contentType: String = "text/plain",
                         body: Data?) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body?.count ?? 0)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
