import UIKit

/// The chart marker for a station whose weather is going downhill.
///
/// Two severities, because they answer different questions. `falling` means conditions are dropping
/// fast (≥200 ft/hr of ceiling or ≥1 SM/hr of visibility) but the field is projected to hold its
/// category. `dropping` means the projection actually crosses INTO a worse category within two hours —
/// that is the one that changes a go/no-go, so it is drawn heavier and in the warning colour.
enum WxTrendMarker {
    enum Severity { case falling, dropping }

    static let size = CGSize(width: 30, height: 30)
    private static var cache: [String: UIImage] = [:]

    static func image(severity: Severity) -> UIImage {
        let key = severity == .dropping ? "dropping" : "falling"
        if let hit = cache[key] { return hit }
        let color = severity == .dropping
            ? UIColor(red: 0.98, green: 0.55, blue: 0.10, alpha: 1)     // amber — category change coming
            : UIColor(red: 0.85, green: 0.80, blue: 0.25, alpha: 1)     // yellow — falling, same category
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = severity == .dropping ? 10 : 8.5
            // A downward chevron in a ring: reads as "going down" at a glance, and doesn't collide
            // visually with any airport glyph (which are circles, letters and runway lines).
            c.setStrokeColor(color.cgColor)
            c.setLineWidth(severity == .dropping ? 2.4 : 1.8)
            c.addEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
            c.strokePath()
            c.setLineWidth(severity == .dropping ? 2.6 : 2.0)
            c.setLineCap(.round)
            let w = r * 0.55, h = r * 0.42
            c.move(to: CGPoint(x: mid.x - w, y: mid.y - h))
            c.addLine(to: CGPoint(x: mid.x, y: mid.y + h))
            c.addLine(to: CGPoint(x: mid.x + w, y: mid.y - h))
            c.strokePath()
        }
        cache[key] = img
        return img
    }
}

/// One deteriorating station, resolved to a place on the chart. Built on the main actor from
/// `MetarStore.deterioratingStations` + the nav database, then handed to the map engine.
struct WxTrendPin: Equatable {
    let ident: String
    let coord: Coord
    let severity: WxTrendMarker.Severity
    /// Short caption drawn under the marker, e.g. "KBOS ↓400" — enough to know WHICH field without tapping.
    let caption: String

    /// Resolve a set of trend results to map pins. Stations we can't place are dropped, not guessed.
    static func pins(from results: [MetarTrend.Result], limit: Int = 60) -> [WxTrendPin] {
        assert(limit > 0, "pins: limit must be positive")
        var out: [WxTrendPin] = []
        for r in results.prefix(limit) {                            // bounded (rule 2)
            guard let c = NavDatabase.resolve(r.ident, near: nil) else { continue }
            var cap = r.ident
            if let ft = r.ceilingRateFtPerHr, ft <= -50 { cap += " ↓\(Int(abs(ft).rounded()))" }
            else if let v = r.visRateSmPerHr, v <= -0.5 { cap += String(format: " ↓%.1fSM", abs(v)) }
            out.append(WxTrendPin(ident: r.ident, coord: c,
                                  severity: r.projectsCategoryDrop ? .dropping : .falling,
                                  caption: cap))
        }
        assert(out.count <= limit, "pins: bound exceeded")
        return out
    }
}
