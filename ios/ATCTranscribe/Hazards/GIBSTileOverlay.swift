import MapKit
import UIKit

/// A NASA GIBS satellite-imagery layer: which product, its web-mercator tile-matrix set, tile format,
/// native max zoom, and how opaquely to draw it over the FAA chart. GIBS serves pre-rendered tiles, so
/// a layer is just this descriptor — no per-tile rendering on our side.
struct GIBSLayer: Equatable {
    let id: String            // GIBS layer identifier
    let matrixSet: String     // web-mercator tile-matrix set, e.g. "GoogleMapsCompatible_Level9"
    let ext: String           // tile extension: "jpg" (opaque true-color) or "png" (transparent overlays)
    let maxZ: Int             // native max web-mercator zoom the matrix set defines
    let alpha: CGFloat        // draw opacity over the chart (kept < 1 so the chart shows through)

    /// The smoke layer: MODIS Terra corrected-reflectance true colour — the recognisable "from orbit"
    /// view where wildfire smoke appears as grey/brown plumes, pairing with the EONET fire points.
    /// 250 m native (Level 9), opaque JPEG tiles. Alpha kept moderate so the FAA chart stays readable
    /// underneath. Verified live against GIBS on 2026-07-13.
    static let smoke = GIBSLayer(
        id: "MODIS_Terra_CorrectedReflectance_TrueColor",
        matrixSet: "GoogleMapsCompatible_Level9",
        ext: "jpg", maxZ: 9, alpha: 0.6)
}

/// Feeds NASA GIBS satellite tiles into MapKit. Distinct from `MBTilesTileOverlay` (local FAA charts):
/// this builds REMOTE GIBS RESTful-WMTS URLs with a DATE in the path, and (past native zoom) crops +
/// upscales the deepest GIBS tile so the layer doesn't vanish when the pilot zooms in — the same trick
/// `MBTilesTileOverlay` uses, because MapKit stops requesting tiles past `maximumZ`.
///
/// Three GIBS-specific rules bake in here:
///   • the path is `…/{TileMatrixSet}/{z}/{y}/{x}.ext` — **row (y) before column (x)**, the reverse of
///     MapKit's usual `{z}/{x}/{y}` template, so the URL is built by hand.
///   • imagery is per-day and polar orbiters fill the globe west→east through the UTC day, so *today's*
///     tiles are half-empty until the satellite has passed; we request the **prior UTC day**. The date
///     is computed LIVE per request (from an injectable clock) so a session that crosses UTC midnight
///     never keeps serving a frozen, going-stale date. It is always observed, prior-day imagery.
///   • GIBS has no tiles past the matrix set's native zoom, so past `maxZ` we overzoom locally.
final class GIBSTileOverlay: MKTileOverlay {
    let layer: GIBSLayer
    private let now: () -> Date          // injectable clock (tests pass a fixed instant)

    /// Zoom levels past native we keep drawing by cropping+upscaling the deepest GIBS tile.
    static let overzoomLevels = 4

    private static let host = "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best"
    private static let fallback = URL(string: "https://gibs.earthdata.nasa.gov/")!

    init(layer: GIBSLayer, now: @escaping () -> Date = { Date() }) {
        assert(!layer.id.isEmpty, "GIBS layer id must be non-empty")
        assert(layer.maxZ > 0 && layer.maxZ <= 22, "layer maxZ in range")
        self.layer = layer
        self.now = now
        super.init(urlTemplate: nil)
        canReplaceMapContent = false          // draws OVER the chart, never replaces it
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 1
        maximumZ = min(layer.maxZ + Self.overzoomLevels, 22)   // request past native; overzoom fills it in
    }

    /// The prior UTC day (`YYYY-MM-DD`) for the current clock — recomputed live, never cached.
    var dateString: String { Self.priorUTCDay(from: now()) }

    /// The day before `date` in UTC, formatted `YYYY-MM-DD` (see the class note on blank same-day tiles).
    static func priorUTCDay(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let day = cal.date(byAdding: .day, value: -1, to: date) ?? date
        let c = cal.dateComponents([.year, .month, .day], from: day)
        assert(c.year != nil && c.month != nil && c.day != nil, "date decomposed")
        let out = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        assert(out.count == 10 && (1...12).contains(c.month ?? 0), "well-formed YYYY-MM-DD")
        return out
    }

    /// Build the GIBS URL for a native-or-shallower tile (z ≤ maxZ). Row (y) precedes column (x).
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        assert(path.z >= 0 && path.x >= 0 && path.y >= 0, "tile path non-negative")
        let z = min(path.z, layer.maxZ)       // never ask GIBS past native — overzoom is handled in loadTile
        assert(z <= layer.maxZ, "requested zoom clamped to native")
        let date = Self.priorUTCDay(from: now())
        let s = "\(Self.host)/\(layer.id)/default/\(date)/\(layer.matrixSet)/\(z)/\(path.y)/\(path.x).\(layer.ext)"
        return URL(string: s) ?? Self.fallback
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        assert(path.z >= 0, "tile zoom non-negative")
        // At or below native, fetch the GIBS tile directly (the default MKTileOverlay behaviour).
        guard path.z > layer.maxZ else { super.loadTile(at: path, result: result); return }
        // Past native: fetch the deepest ancestor GIBS tile, crop the sub-rect, scale to 256 — so the
        // smoke layer stays visible (progressively softer) at approach/pattern zoom instead of vanishing.
        guard let src = MBTilesTileOverlay.overzoomSource(z: path.z, x: path.x, y: path.y, maxZoom: layer.maxZ) else {
            result(nil, nil); return
        }
        let ancestor = MKTileOverlayPath(x: src.ax, y: src.ay, z: layer.maxZ, contentScaleFactor: path.contentScaleFactor)
        super.loadTile(at: ancestor) { data, err in
            guard let data, let img = UIImage(data: data) else { result(data, err); return }
            result(Self.crop(img, src: src), nil)
        }
    }

    /// Crop the `src` sub-rectangle (in the ancestor's 256-pt space) and scale it to a full 256×256 tile.
    /// Mirrors `MBTilesTileOverlay.overzoomedTile`; runs on MapKit's tile queue (off-screen render is safe).
    private static func crop(_ img: UIImage, src: (ax: Int, ay: Int, sub: Double, ox: Double, oy: Double)) -> Data? {
        assert(src.sub > 0, "sub-tile size positive")
        assert(src.ox >= 0 && src.oy >= 0, "sub-tile origin non-negative")
        let tile: CGFloat = 256
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: CGSize(width: tile, height: tile), format: fmt).image { _ in
            let draw = tile / CGFloat(src.sub)                  // scale so the sub-rect fills 256×256
            let size = CGSize(width: img.size.width * draw, height: img.size.height * draw)
            img.draw(in: CGRect(x: -CGFloat(src.ox) * draw, y: -CGFloat(src.oy) * draw,
                                width: size.width, height: size.height))
        }
        return out.jpegData(compressionQuality: 0.8)
    }
}
