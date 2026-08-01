import SwiftUI

/// ITEM 43 — the approach lighting system, DRAWN rather than named.
///
/// "See the ALSF-2 rather than recall it": the acronym encodes a physical layout — how far the bars
/// extend from the threshold, whether there are sequenced flashers, whether there are red side rows —
/// and a pilot briefing at night should not have to reconstruct that from five letters.
///
/// ⚠️ SCHEMATIC, NOT TO SCALE, and it says so. This is a recognition aid: the real geometry runs
/// 1,400–3,000 ft from the threshold with per-installation variation, and drawing it to scale in a
/// strip a few points high would be false precision. What it gets RIGHT is the distinguishing features
/// — bar count, the decision bar, flashers, red side rows — which is what tells one system from another.
///
/// Only the systems that actually appear are drawn (14 codes in the whole NASR table). Anything else
/// renders nothing and the caller falls back to the raw acronym, because a wrong picture is worse than
/// no picture.
struct ApproachLightingView: View {
    let code: String
    let palette: Palette

    /// The features a system has. Derived from the code once, so the drawing stays declarative.
    struct Layout: Equatable {
        let bars: Int                 // white crossbars drawn out from the threshold
        let hasFlashers: Bool         // sequenced flashers ("the rabbit")
        let hasRedSideRows: Bool      // ALSF only — the red terminating bars
        let hasDecisionBar: Bool      // the 1,000 ft crossbar
        let isOmnidirectional: Bool   // ODALS — flashers ONLY, no bars at all
    }

    /// nil when this app does not know the code — including NSTD, which means the installation does not
    /// follow the standard pattern and therefore cannot be drawn as one.
    static func layout(for code: String) -> Layout? {
        switch code.trimmingCharacters(in: .whitespaces).uppercased() {
        case "ALSF1": return Layout(bars: 5, hasFlashers: true, hasRedSideRows: true,
                                    hasDecisionBar: true, isOmnidirectional: false)
        case "ALSF2": return Layout(bars: 5, hasFlashers: true, hasRedSideRows: true,
                                    hasDecisionBar: true, isOmnidirectional: false)
        case "ALSAF": return Layout(bars: 5, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: true, isOmnidirectional: false)
        case "MALSR": return Layout(bars: 3, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: true, isOmnidirectional: false)
        case "MALSF": return Layout(bars: 3, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: false)
        case "MALS":  return Layout(bars: 3, hasFlashers: false, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: false)
        case "SSALR": return Layout(bars: 3, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: true, isOmnidirectional: false)
        case "SSALF": return Layout(bars: 3, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: false)
        case "SSALS": return Layout(bars: 3, hasFlashers: false, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: false)
        case "SALSF": return Layout(bars: 2, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: false)
        case "SALS":  return Layout(bars: 2, hasFlashers: false, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: false)
        case "ODALS": return Layout(bars: 0, hasFlashers: true, hasRedSideRows: false,
                                    hasDecisionBar: false, isOmnidirectional: true)
        default:      return nil       // incl. NSTD and RLLS — not a standard bar layout
        }
    }

    var body: some View {
        if let l = Self.layout(for: code) {
            Canvas { ctx, size in
                let h = size.height, w = size.width
                let mid = h / 2
                // The threshold sits at the RIGHT — the aircraft flies right-to-left toward it, which is
                // the direction the chart's own profile reads.
                let thr = w - 2
                let reach = w - 10
                let step = l.isOmnidirectional ? reach / 6 : reach / CGFloat(max(l.bars, 1) + 2)

                // Threshold bar — the one fixed reference.
                var t = Path()
                t.move(to: CGPoint(x: thr, y: mid - h * 0.34))
                t.addLine(to: CGPoint(x: thr, y: mid + h * 0.34))
                ctx.stroke(t, with: .color(.green), lineWidth: 2)

                if l.isOmnidirectional {
                    // ODALS is flashers only — five of them, and nothing else. Drawing bars would show a
                    // system that is not installed.
                    for i in 1...5 {                                     // bounded (rule 2)
                        let x = thr - CGFloat(i) * step
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: mid - 1.5, width: 3, height: 3)),
                                 with: .color(.white))
                    }
                } else {
                    for i in 1...max(l.bars, 1) {                        // bounded (rule 2)
                        let x = thr - CGFloat(i) * step
                        let half = h * (i == l.bars && l.hasDecisionBar ? 0.30 : 0.18)
                        var bar = Path()
                        bar.move(to: CGPoint(x: x, y: mid - half))
                        bar.addLine(to: CGPoint(x: x, y: mid + half))
                        ctx.stroke(bar, with: .color(.white), lineWidth: 1.6)
                    }
                    if l.hasRedSideRows {
                        // The red terminating bars either side of centreline — the ALSF signature.
                        for dy in [-h * 0.30, h * 0.30] {
                            var r = Path()
                            r.move(to: CGPoint(x: thr - step * 0.6, y: mid + dy))
                            r.addLine(to: CGPoint(x: thr - step * 1.4, y: mid + dy))
                            ctx.stroke(r, with: .color(.red), lineWidth: 1.6)
                        }
                    }
                }
                if l.hasFlashers && !l.isOmnidirectional {
                    // "The rabbit" — sequenced flashers running in toward the threshold.
                    for i in 1...3 {                                     // bounded (rule 2)
                        let x = thr - reach + CGFloat(i) * (step * 0.5)
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: mid - 1.2, width: 2.4, height: 2.4)),
                                 with: .color(.white.opacity(0.9)))
                    }
                }
                // The centreline the bars hang from.
                var c = Path()
                c.move(to: CGPoint(x: thr - reach, y: mid))
                c.addLine(to: CGPoint(x: thr, y: mid))
                ctx.stroke(c, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
            }
            .frame(height: 18)
            .accessibilityLabel(ApproachBrief.decodeApproachLights(code) ?? code)
        }
    }
}
