import UIKit

/// Draws an `AirportSymbol.Spec` as the small mark a pilot reads on a sectional.
///
/// Images are cached by `Spec.signature`, so the thousands of airports that look alike share one
/// bitmap — which is what makes per-airport symbology affordable on the map (MapLibre registers
/// glyphs by name, and the name IS the signature).
///
/// FAA colour convention: BLUE for a towered field, MAGENTA for a non-towered one. When the field is
/// reporting weather the flight category tints the symbol instead, because "can I get in" outranks
/// "is anyone talking" — the tower/no-tower distinction is still carried by the ring weight.
enum AirportSymbolRenderer {

    static let size = CGSize(width: 44, height: 44)

    // FAA sectional colours.
    static let towerBlue   = UIColor(red: 0.13, green: 0.40, blue: 0.78, alpha: 1)
    static let nonTowerMag = UIColor(red: 0.78, green: 0.16, blue: 0.55, alpha: 1)
    static let vfrGreen    = UIColor(red: 0.18, green: 0.75, blue: 0.35, alpha: 1)
    static let mvfrBlue    = UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1)
    static let ifrRed      = UIColor(red: 0.90, green: 0.23, blue: 0.23, alpha: 1)
    static let lifrMagenta = UIColor(red: 0.85, green: 0.20, blue: 0.85, alpha: 1)

    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    /// The rendered glyph for a spec (cached by signature).
    static func image(for spec: AirportSymbol.Spec) -> UIImage {
        let key = spec.signature
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        let img = draw(spec)
        lock.lock(); cache[key] = img; lock.unlock()
        return img
    }

    /// The colour for a reported flight category — shared with the airport card so the chart symbol and
    /// the card's trend chips agree.
    static func categoryColor(_ c: Metar.Category) -> UIColor {
        switch c {
        case .vfr:  return vfrGreen
        case .mvfr: return mvfrBlue
        case .ifr:  return ifrRed
        case .lifr: return lifrMagenta
        case .unknown: return .gray
        }
    }

    /// Base colour: flight category when the field reports, else the FAA tower/no-tower colour.
    static func tint(_ spec: AirportSymbol.Spec) -> UIColor {
        switch spec.category {
        case .vfr:  return vfrGreen
        case .mvfr: return mvfrBlue
        case .ifr:  return ifrRed
        case .lifr: return lifrMagenta
        case nil:   return spec.towered ? towerBlue : nonTowerMag
        }
    }

    private static func draw(_ spec: AirportSymbol.Spec) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = 9
            let color = tint(spec)
            // A towered field carries a heavier ring, so the tower distinction survives the category tint.
            let lw: CGFloat = spec.towered ? 2.6 : 1.8
            c.setStrokeColor(color.cgColor); c.setFillColor(color.cgColor); c.setLineWidth(lw)

            switch spec.kind {
            case .heliport:   drawCircledLetter("H", mid, r, color, lw, c); return
            case .seaplane:   drawAnchor(mid, r, color, lw, c); return
            case .ultralight: drawCircledLetter("F", mid, r, color, lw, c); return
            case .privateUse: drawCircledLetter("R", mid, r, color, lw, c); return
            case .unverified: drawCircledLetter("U", mid, r, color, lw, c); return
            case .abandoned:  drawCircledX(mid, r, color, lw, c); return
            case .military, .airport: break
            }

            // Fuel: short ticks at the four diagonals, the FAA's "notches".
            if spec.fuel {
                // Ticks sit OUTSIDE the runway extent. A runwaysOnly field draws lines out to r+1, so
                // starting the ticks at r+1.5 put them straight through the runway ends and the symbol
                // read as a splatter instead of a layout.
                let inner = spec.shape == .runwaysOnly ? r + 8.0 : r + 5.0
                let outer = inner + 3.5
                c.setLineWidth(1.8)
                for deg in stride(from: 45.0, to: 360.0, by: 90.0) {
                    let a = deg * .pi / 180
                    c.move(to: CGPoint(x: mid.x + cos(a) * inner, y: mid.y + sin(a) * inner))
                    c.addLine(to: CGPoint(x: mid.x + cos(a) * outer, y: mid.y + sin(a) * outer))
                }
                c.strokePath()
                c.setLineWidth(lw)
            }

            switch spec.shape {
            case .filledCircleWithRunways:
                c.addEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
                c.fillPath()
                // Runways in the knockout colour so they read against the filled disc.
                c.setStrokeColor(UIColor.white.cgColor); c.setLineWidth(1.6)
                strokeRunways(spec.runwayAxesDeg, mid, r - 1.5, c)
            case .openCircle:
                c.addEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
                c.strokePath()
            case .runwaysOnly:
                // No circle: the runway layout itself IS the symbol (long/multi-runway fields), so the
                // lines must be long enough to READ as a layout. At r+1 they were shorter than the
                // circle they replaced and the symbol looked like a stray tick rather than an airport.
                c.setLineWidth(spec.runwayAxesDeg.count >= 3 ? 1.9 : 2.6)
                strokeRunways(spec.runwayAxesDeg.isEmpty ? [0, 90] : spec.runwayAxesDeg, mid, r + 5, c)
            }

            // Military: the second ring.
            if spec.kind == .military {
                c.setStrokeColor(color.cgColor); c.setLineWidth(1.4)
                c.addEllipse(in: CGRect(x: mid.x - r - 2.5, y: mid.y - r - 2.5,
                                        width: (r + 2.5) * 2, height: (r + 2.5) * 2))
                c.strokePath()
            }

            // Beacon: a star off the upper-right, the FAA's dusk-to-dawn rotating beacon.
            if spec.beacon { drawStar(CGPoint(x: mid.x + r + 6, y: mid.y - r - 4), 4.2, color, c) }
        }
    }

    /// Runway lines through the centre, drawn on their 0–180° axis (screen y is down, so negate).
    private static func strokeRunways(_ axes: [Int], _ mid: CGPoint, _ len: CGFloat, _ c: CGContext) {
        // Four is the most that stays legible in a 44pt glyph; the airport card lists them all.
        for deg in axes.prefix(4) {                                   // bounded (rule 2)
            let a = Double(deg) * .pi / 180
            let dx = CGFloat(sin(a)) * len, dy = -CGFloat(cos(a)) * len
            c.move(to: CGPoint(x: mid.x - dx, y: mid.y - dy))
            c.addLine(to: CGPoint(x: mid.x + dx, y: mid.y + dy))
        }
        c.strokePath()
    }

    private static func drawCircledLetter(_ ch: String, _ mid: CGPoint, _ r: CGFloat,
                                          _ color: UIColor, _ lw: CGFloat, _ c: CGContext) {
        c.addEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
        c.strokePath()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: r * 1.25, weight: .bold), .foregroundColor: color]
        let s = NSAttributedString(string: ch, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: mid.x - sz.width / 2, y: mid.y - sz.height / 2))
    }

    private static func drawCircledX(_ mid: CGPoint, _ r: CGFloat, _ color: UIColor,
                                     _ lw: CGFloat, _ c: CGContext) {
        c.addEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
        c.strokePath()
        let d = r * 0.62
        c.move(to: CGPoint(x: mid.x - d, y: mid.y - d)); c.addLine(to: CGPoint(x: mid.x + d, y: mid.y + d))
        c.move(to: CGPoint(x: mid.x + d, y: mid.y - d)); c.addLine(to: CGPoint(x: mid.x - d, y: mid.y + d))
        c.strokePath()
    }

    private static func drawAnchor(_ mid: CGPoint, _ r: CGFloat, _ color: UIColor,
                                   _ lw: CGFloat, _ c: CGContext) {
        c.move(to: CGPoint(x: mid.x, y: mid.y - r)); c.addLine(to: CGPoint(x: mid.x, y: mid.y + r))
        c.move(to: CGPoint(x: mid.x - r * 0.6, y: mid.y - r * 0.45))
        c.addLine(to: CGPoint(x: mid.x + r * 0.6, y: mid.y - r * 0.45))
        c.strokePath()
        c.addArc(center: CGPoint(x: mid.x, y: mid.y + r * 0.25), radius: r * 0.75,
                 startAngle: 0, endAngle: .pi, clockwise: false)
        c.strokePath()
    }

    private static func drawStar(_ at: CGPoint, _ r: CGFloat, _ color: UIColor, _ c: CGContext) {
        c.setFillColor(color.cgColor)
        let path = UIBezierPath()
        for i in 0..<10 {                                             // bounded
            let rad = (i % 2 == 0) ? r : r * 0.45
            let a = Double(i) * .pi / 5 - .pi / 2
            let p = CGPoint(x: at.x + CGFloat(cos(a)) * rad, y: at.y + CGFloat(sin(a)) * rad)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.close()
        c.addPath(path.cgPath); c.fillPath()
    }
}
