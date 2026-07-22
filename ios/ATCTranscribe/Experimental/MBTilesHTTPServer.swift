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

    // The bundled per-layer chart bases (vfr / ifrlow / ifrhigh), each served on its OWN
    // "/base/<name>/{z}/{x}/{y}" path so the map can keep a raster layer per base permanently loaded and switch
    // between them by opacity alone — no reader swap, no tile re-request, so changing chart layer is instant.
    private var baseReaders: [String: MBTilesReader] = [:]
    func setBaseReaders(_ m: [String: MBTilesReader]) { lock.lock(); baseReaders = m; lock.unlock() }
    private func currentBaseReader(_ name: String) -> MBTilesReader? {
        lock.lock(); defer { lock.unlock() }; return baseReaders[name]
    }

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
            } else if let (tile, mime) = self.tile(forPath: path) {
                self.respond(conn, status: "200 OK", contentType: mime, body: tile)
            } else {
                self.respond(conn, status: "404 Not Found", body: nil)   // no chart coverage here → transparent
            }
        }
    }

    /// The MIME actually served for a tile from `r` at zoom `z`. The overzoom branch composites pixels and
    /// always re-encodes to PNG; the in-range branch serves the pack's own bytes (see the passthrough
    /// in `tile(forPath:)`). Serving the truthful type beats the old hardcoded "image/png" for JPEG/WebP bytes.
    private static func mime(for r: MBTilesReader, z: Int) -> String {
        if z > r.maxZoom { return "image/png" }                     // composited (upscaled) by us
        switch r.format {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return MBTilesTileOverlay.webpNativePassthrough ? "image/webp" : "image/png"
        }
    }

    /// "/8/74/97" or "/8/74/97.png" → tile bytes + MIME from the first pack that has it. Bounded scan.
    private func tile(forPath path: String) -> (Data, String)? {
        let comps = path.split(separator: "/").map { $0.split(separator: ".").first.map(String.init) ?? String($0) }
        guard comps.count >= 3, let z = Int(comps[comps.count - 3]),
              let x = Int(comps[comps.count - 2]), let y = Int(comps[comps.count - 1]) else { return nil }
        // "/sat/" → the dedicated satellite base reader ONLY (its own bottom layer); "/base/<name>/" → that one
        // bundled chart base (its own always-loaded layer). Everything else scans the mounted chart packs.
        // Satellite/bases have their own minZoom; z>maxZoom overzooms as usual.
        let readers: [MBTilesReader]
        if comps.first == "sat" {
            readers = currentSatelliteReader().map { [$0] } ?? []
        } else if comps.first == "base", comps.count >= 5 {
            readers = currentBaseReader(comps[1]).map { [$0] } ?? []
        } else {
            readers = currentReaders()
        }
        assert(readers.count <= 64, "unexpectedly many chart packs mounted")
        assert(z >= 0 && z <= 24, "tile: out-of-range zoom")
        for r in readers.prefix(64) {                                    // bounded (rule 2)
            guard z >= r.minZoom, z <= r.maxZoom + MBTilesTileOverlay.overzoomLevels else { continue }
            let key = "\(r.packID)/\(z)/\(x)/\(y)" as NSString
            if let hit = pngCache.object(forKey: key) {
                if hit.length == 0 { continue }        // cached NEGATIVE (this pack has no such tile) → try the next
                return (hit as Data, Self.mime(for: r, z: z))
            }
            let out: Data?
            if z > r.maxZoom {
                // Past the pack's data: upscale the deepest ancestor tile (same math as the MKMapView path,
                // MBTilesTileOverlay.overzoomedTile) so the chart stays visible on close-in/approach zoom
                // instead of vanishing to bare OSM. Without this the +overzoomLevels band was dead allowance.
                out = Self.overzoomedPNG(reader: r, z: z, x: x, y: y)
            } else if let raw = r.tileData(z: z, x: x, y: y) {           // reader flips XYZ→TMS internally
                if r.format == "png" || r.format == "jpg" || r.format == "jpeg" {
                    out = raw
                } else if MBTilesTileOverlay.webpNativePassthrough {
                    // Serve WebP AS-IS. ImageIO has decoded WebP since iOS 14 (deployment target is 17) and the
                    // shipped MapLibre imports CGImageSourceCreateWithData with zero libwebp symbols, so it goes
                    // through ImageIO too — the decoder sniffs the bytes. Transcoding here inflated every tile
                    // 6.9-8.5x and cost 4-8ms, paid on all three always-loaded bases, and blew the 48MB
                    // pngCache (~26MB of WebP becomes ~200MB of PNG). The MapKit path already ships this
                    // passthrough A/B-verified; `atc.chartCompat` remains the escape hatch for both.
                    // NOTE: only this in-range branch can pass through — the overzoom branch composites pixels.
                    out = raw
                } else {
                    // WebP → PNG for MapLibre. A DECODE FAILURE must NOT be served as a mislabeled image/png
                    // (a permanent blank square) nor cached — return no-tile so MapLibre treats it as no coverage.
                    out = UIImage(data: raw)?.pngData()
                }
            } else {
                out = nil                                                // this pack lacks the tile; try the next
            }
            if let out {
                pngCache.setObject(out as NSData, forKey: key, cost: out.count)
                return (out, Self.mime(for: r, z: z))
            }
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
