import Foundation
import CoreGraphics

/// A precomputed georeference for one plate PDF: the placement that lands the plate's plan view on
/// the map (center of the full page in lat/lon, the geographic width the page spans, and a
/// clockwise-from-north rotation ≈ 0 since FAA plan views are north-up), plus the fit's residual and
/// control-point count for a confidence read.
struct PlateGeorefEntry {
    let centerLat: Double
    let centerLon: Double
    let widthMeters: Double
    let rotationDeg: Double
    let rmsMeters: Double
    let inliers: Int

    /// The invariants a HIGH-CONFIDENCE fit must satisfy — the exact predicate `build_plate_georef`
    /// enforces before writing an entry, promoted into the runtime so a corrupted / hand-edited /
    /// stale table can never place a mis-scaled or rotated plate in front of a pilot. Fails CLOSED:
    /// anything outside these bounds → treated as "no georeference" → the pilot hand-aligns instead.
    var isPlausible: Bool {
        guard centerLat.isFinite, centerLon.isFinite, widthMeters.isFinite,
              rotationDeg.isFinite, rmsMeters.isFinite else { return false }
        guard abs(centerLat) <= 90, abs(centerLon) <= 180 else { return false }
        guard widthMeters > 8_000, widthMeters < 250_000 else { return false }
        guard abs(PlateSimilarity.normalizeDeg(rotationDeg)) < 12 else { return false }   // north-up prior
        guard rmsMeters >= 0, rmsMeters < 250 else { return false }
        guard inliers >= 3 else { return false }
        return true
    }

    /// Map a world coordinate onto the plate's PDF page, or nil if it falls outside the page. Uses the
    /// SAME similarity as the map overlay (`PlateSimilarity`): the plate image center is the georef
    /// center, the page spans `widthMeters`, rotated `rotationDeg` clockwise-from-north. `pageSize` is
    /// the PDF mediaBox size (points). Returned point is in PDF page space (origin BOTTOM-left). This is
    /// what places ownship / ADS-B traffic on a georeferenced plate.
    func pagePoint(lat: Double, lon: Double, pageSize: CGSize) -> CGPoint? {
        guard isPlausible, pageSize.width > 1, pageSize.height > 1 else { return nil }
        let e = (lon - centerLon) * 111_320.0 * cos(centerLat * .pi / 180)   // ENU metres from the center
        let n = (lat - centerLat) * 111_320.0
        let pl = PlateSimilarity.Placement(centerEast: 0, centerNorth: 0,
                                           widthMeters: widthMeters, rotationDeg: rotationDeg)
        let px = PlateSimilarity.worldToPixel(pl, imageW: Double(pageSize.width), imageH: Double(pageSize.height),
                                              east: e, north: n)
        guard px.x >= 0, px.x <= Double(pageSize.width), px.y >= 0, px.y <= Double(pageSize.height) else { return nil }
        return CGPoint(x: px.x, y: Double(pageSize.height) - px.y)   // image y-down → PDF page y-up
    }
}

/// Bundled lookup of the offline plate-georeference table (`nav/plate_georef.json`, built by
/// `Tools/build_plate_georef` — OCR the plate, match its fixes to CIFP coords, solve a similarity).
/// Only high-confidence fits are in the table, so a hit means the plate can be auto-aligned; a miss
/// means the pilot hand-aligns it. Load-once, like `NavMeta`/`Procedures`.
enum PlateGeoref {
    private struct DTO: Decodable {
        let cycle: String
        let plates: [String: Entry]

        struct Entry: Decodable {
            let centerLat: Double; let centerLon: Double; let widthMeters: Double
            let rotationDeg: Double; let rmsMeters: Double; let inliers: Int
        }

        /// One malformed/partial row must NOT collapse the whole table (F6): decode each entry
        /// failably and drop only the bad ones. A wrapper whose `init` swallows a decode error.
        private struct Failable: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
        private enum Key: String, CodingKey { case cycle, plates }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            cycle = (try? c.decode(String.self, forKey: .cycle)) ?? ""
            let raw = (try? c.decode([String: Failable].self, forKey: .plates)) ?? [:]
            plates = raw.compactMapValues { $0.entry }
        }
        init(cycle: String, plates: [String: Entry]) { self.cycle = cycle; self.plates = plates }
    }
    private static let data: DTO = load()

    /// The chart cycle the table was built for ("" when the resource is absent).
    static var cycle: String { data.cycle }
    /// How many plates have a georeference (0 when the resource is absent).
    static var count: Int { data.plates.count }

    /// The precomputed placement for a plate's PDF filename, or nil if it wasn't confidently fit OR
    /// the stored entry fails the plausibility invariants (fail-closed — see `isPlausible`).
    static func lookup(pdf: String) -> PlateGeorefEntry? {
        assert(!pdf.isEmpty, "lookup: empty pdf key")
        guard !pdf.isEmpty, let e = data.plates[pdf] else { return nil }
        let entry = PlateGeorefEntry(centerLat: e.centerLat, centerLon: e.centerLon, widthMeters: e.widthMeters,
                                     rotationDeg: e.rotationDeg, rmsMeters: e.rmsMeters, inliers: e.inliers)
        guard entry.isPlausible else { return nil }   // never trust a malformed / out-of-range fit
        return entry
    }

    private static func load() -> DTO {
        let url = Bundle.main.url(forResource: "plate_georef", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "plate_georef", withExtension: "json")
        guard let url, let d = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: d) else { return DTO(cycle: "", plates: [:]) }
        assert(dto.plates.count >= 0)
        return dto
    }
}
