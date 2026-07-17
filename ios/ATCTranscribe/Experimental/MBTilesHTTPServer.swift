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
    private let queue = DispatchQueue(label: "commsight.mbtiles.http")
    private(set) var port: UInt16 = 0
    // The mounted packs, handed over from the main actor (ChartStore is @MainActor) and read under the
    // lock on the listener's background queue. MBTilesReader is opened FULLMUTEX so its own tile queries
    // are thread-safe; only the array swap needs guarding.
    private let lock = NSLock()
    private var readers: [MBTilesReader] = []

    init() {}

    /// Push the current chart packs (call from the main actor whenever they change).
    func setReaders(_ r: [MBTilesReader]) { lock.lock(); readers = r; lock.unlock() }
    private func currentReaders() -> [MBTilesReader] { lock.lock(); defer { lock.unlock() }; return readers }

    /// Start listening on an ephemeral loopback port. Returns the port, or nil on failure.
    @discardableResult
    func start() -> UInt16? {
        guard listener == nil else { return port }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback            // 127.0.0.1 only — never leaves the device
            let l = try NWListener(using: params, on: .any)     // OS picks a free port
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            let ready = DispatchSemaphore(value: 0)
            l.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
            l.start(queue: queue)
            listener = l
            _ = ready.wait(timeout: .now() + 2)                 // wait for the assigned port
            port = l.port?.rawValue ?? 0
            return port > 0 ? port : nil
        } catch { return nil }
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
        let readers = currentReaders()
        assert(readers.count <= 64, "unexpectedly many chart packs mounted")
        for r in readers.prefix(64) {                                    // bounded (rule 2)
            guard z >= r.minZoom, z <= r.maxZoom + MBTilesTileOverlay.overzoomLevels else { continue }
            guard let raw = r.tileData(z: z, x: x, y: y) else { continue }   // reader flips XYZ→TMS internally
            if r.format == "png" || r.format == "jpg" || r.format == "jpeg" { return raw }
            return UIImage(data: raw)?.pngData() ?? raw                   // WebP → PNG for MapLibre
        }
        return nil
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
