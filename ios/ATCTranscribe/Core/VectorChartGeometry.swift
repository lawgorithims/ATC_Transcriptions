import Foundation
import CoreGraphics

/// The projection behind a VECTOR procedure chart: geographic positions to view points, at a real,
/// stated scale.
///
/// This is what "everything drawn to scale" (item 9) actually requires. A raster plate is a picture at
/// a fixed scale chosen by the FAA; a vector chart must know its own scale so distances, protected
/// areas and turn radii are truthful at any zoom — and so the app can say what the scale IS rather than
/// implying one.
///
/// Equirectangular about the chart's own centre, NOT Web Mercator. A terminal procedure spans tens of
/// nautical miles, where the two are indistinguishable, and the equirectangular form keeps NM/point
/// constant across the whole chart — which is the property that makes a drawn distance mean something.
/// (Mercator's scale varies with latitude; over a 40 NM chart at 60°N that is a visible error in the
/// wrong direction.)
struct VectorChartGeometry: Equatable {

    /// Geographic centre of the drawn area.
    let center: Coord
    /// Nautical miles per view point. THE scale — everything else derives from it.
    let nmPerPoint: Double
    /// The view's size in points.
    let size: CGSize

    static let nmPerDegreeLat = 60.0

    /// Fit `coords` into `size` with `paddingPoints` of margin, and return the geometry that does it.
    ///
    /// Returns nil for an empty or degenerate input rather than inventing a scale: a chart of one point
    /// has no meaningful zoom, and picking one would draw a procedure that appears to span the screen.
    static func fitting(_ coords: [Coord], in size: CGSize,
                        paddingPoints: Double = 24) -> VectorChartGeometry? {
        guard !coords.isEmpty, size.width > 1, size.height > 1 else { return nil }
        var minLat = coords[0].lat, maxLat = minLat
        var minLon = coords[0].lon, maxLon = minLon
        for c in coords.prefix(4096) {                                   // bounded (rule 2)
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let center = Coord(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
        let cosLat = max(0.02, cos(center.lat * .pi / 180))               // guard the poles
        let spanNmY = (maxLat - minLat) * nmPerDegreeLat
        let spanNmX = (maxLon - minLon) * nmPerDegreeLat * cosLat
        let usableW = max(1, Double(size.width) - 2 * paddingPoints)
        let usableH = max(1, Double(size.height) - 2 * paddingPoints)
        // A single point, or a perfectly straight north-south procedure, has zero span on one axis —
        // fall back to the other rather than dividing by zero.
        let byX = spanNmX > 0 ? spanNmX / usableW : 0
        let byY = spanNmY > 0 ? spanNmY / usableH : 0
        let scale = max(byX, byY)
        guard scale > 0, scale.isFinite else { return nil }
        assert(scale < 100, "VectorChartGeometry: implausible scale")
        return VectorChartGeometry(center: center, nmPerPoint: scale, size: size)
    }

    /// Geographic → view point. The origin is the view's centre; y grows DOWNWARD, as UIKit expects,
    /// so north is up.
    func point(_ c: Coord) -> CGPoint {
        let cosLat = max(0.02, cos(center.lat * .pi / 180))
        let dxNm = (c.lon - center.lon) * Self.nmPerDegreeLat * cosLat
        let dyNm = (c.lat - center.lat) * Self.nmPerDegreeLat
        return CGPoint(x: size.width / 2 + CGFloat(dxNm / nmPerPoint),
                       y: size.height / 2 - CGFloat(dyNm / nmPerPoint))
    }

    /// View points for a distance in nautical miles — how a protected area or a range ring is sized.
    func points(nm: Double) -> CGFloat {
        assert(nm >= 0, "VectorChartGeometry: negative distance")
        return CGFloat(nm / nmPerPoint)
    }

    /// The chart's own scale as a pilot-readable string, so the view can state it instead of implying it.
    var scaleLabel: String {
        let nmAcross = nmPerPoint * Double(size.width)
        return nmAcross >= 10 ? "\(Int(nmAcross.rounded())) NM across"
                              : String(format: "%.1f NM across", nmAcross)
    }

    /// Zoomed by `factor` about the same centre. Used by the pinch gesture; the centre moves separately.
    func zoomed(_ factor: Double) -> VectorChartGeometry {
        assert(factor > 0, "VectorChartGeometry: non-positive zoom")
        return VectorChartGeometry(center: center, nmPerPoint: nmPerPoint / factor, size: size)
    }

    /// Re-centred on `c`, keeping the scale.
    func centered(on c: Coord) -> VectorChartGeometry {
        VectorChartGeometry(center: c, nmPerPoint: nmPerPoint, size: size)
    }
}

/// PROGRESSIVE DISCLOSURE (item 6): what a chart shows depends on how far in the pilot is zoomed.
///
/// The tiers are keyed on the chart's own SCALE, not on an abstract zoom level, so the rule is a real
/// statement about legibility: at 40 NM across, fix idents collide and crossing restrictions are
/// unreadable mush, so they are not drawn. The thresholds are the NM-across values at which each layer
/// stops being readable at typical iPad point sizes.
enum ChartDetail: Int, Comparable, CaseIterable {
    /// The overview: the track, the runway, and the fixes that define the shape.
    case overview = 0
    /// Plus every fix ident.
    case idents = 1
    /// Plus published crossing restrictions and the procedure's own annotations.
    case restrictions = 2

    static func < (l: ChartDetail, r: ChartDetail) -> Bool { l.rawValue < r.rawValue }

    /// The detail a chart of this width supports.
    static func forScale(nmAcross: Double) -> ChartDetail {
        assert(nmAcross > 0, "ChartDetail: non-positive width")
        if nmAcross <= 12 { return .restrictions }
        if nmAcross <= 30 { return .idents }
        return .overview
    }
}
