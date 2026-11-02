import SwiftUI

/// The rulers, drawn over whichever map engine is live.
///
/// SwiftUI rather than an engine overlay, and ONE `Canvas` rather than a view per ruler, for the same
/// reason the search highlight is drawn this way: the geometry arrives as screen points that the
/// engine re-publishes on every camera change, so a view hierarchy would be rebuilt dozens of times
/// a second during a pan. It is also the only arrangement that renders identically on both engines —
/// a pilot must not get a different-looking ruler because the GPU chart fell back to the classic one.
///
/// Never hit-testable. Every touch belongs to the map or to `MapRulerController`'s recognizers; a
/// ruler that ate a tap meant for an airport would be worse than no ruler.
struct MapRulerLayer: View {
    @ObservedObject var store: MapRulerStore = .shared
    let palette: Palette
    /// Ground speed to turn distance into time — the pilot's own, when they are moving.
    let groundSpeedKt: Double?
    /// Planned cruise from the selected aircraft profile, used only when the aircraft is not moving.
    let cruiseKt: Int?

    /// Drawn thicker than a chart line and with a dark casing under it, because this is read against
    /// a sectional — which is already full of magenta and blue lines of its own.
    private let lineWidth: CGFloat = 2.6
    private let capRadius: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            for ruler in store.rulers {
                guard let seg = store.segments[ruler.id], onScreen(seg, in: size) else { continue }
                let live = store.liveID == ruler.id
                draw(ruler: ruler, seg: seg, live: live, ctx: &ctx, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Cheap rejection: both ends far outside the viewport AND the segment not crossing it. A ruler
    /// whose ends are off-screen either side still has to draw — that is the long-range case.
    private func onScreen(_ seg: MapRulerStore.ScreenSegment, in size: CGSize) -> Bool {
        let pad: CGFloat = 4000          // generous: projections can throw ends a long way out
        let box = CGRect(x: -pad, y: -pad, width: size.width + pad * 2, height: size.height + pad * 2)
        return box.contains(seg.a) || box.contains(seg.b)
    }

    private func draw(ruler: MapRuler, seg: MapRulerStore.ScreenSegment,
                      live: Bool, ctx: inout GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: seg.a)
        line.addLine(to: seg.b)

        // Dark casing first, then the accent on top: the same two-pass trick the route line uses, and
        // the only thing that keeps a thin line legible over both a white sectional and a night chart.
        ctx.stroke(line, with: .color(.black.opacity(0.55)),
                   style: StrokeStyle(lineWidth: lineWidth + 2.4, lineCap: .round))
        ctx.stroke(line, with: .color(live ? palette.warn : palette.accent),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                      dash: live ? [7, 4] : []))

        for end in [seg.a, seg.b] {
            let r = live ? capRadius + 1.5 : capRadius
            let box = CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(.black.opacity(0.6)))
            ctx.fill(Path(ellipseIn: box.insetBy(dx: 1.6, dy: 1.6)),
                     with: .color(live ? palette.warn : palette.accent))
        }

        let readout = MapRulerMath.readout(ruler, groundSpeedKt: groundSpeedKt,
                                           cruiseKt: cruiseKt, variation: MagneticVariation.at)
        drawLabel(readout, seg: seg, live: live, ctx: &ctx, size: size)
    }

    private func drawLabel(_ readout: MapRulerReadout, seg: MapRulerStore.ScreenSegment,
                           live: Bool, ctx: inout GraphicsContext, size: CGSize) {
        let summary = MapRulerMath.summary(readout)
        let note = MapRulerMath.speedNote(readout)

        let resolved = ctx.resolve(Text(summary).font(.dsLabelSBold).foregroundStyle(palette.text))
        let resolvedNote = note.map {
            ctx.resolve(Text($0).font(.dsLabelS).foregroundStyle(palette.textDim))
        }
        let summarySize = resolved.measure(in: CGSize(width: 320, height: 60))
        let noteSize = resolvedNote?.measure(in: CGSize(width: 320, height: 60)) ?? .zero

        let padding: CGFloat = 6
        let w = max(summarySize.width, noteSize.width) + padding * 2
        let h = summarySize.height + (noteSize.height > 0 ? noteSize.height + 1 : 0) + padding * 2

        // Centred on the line's midpoint and nudged clear of it, then CLAMPED into the viewport. A
        // label that sits off-screen is the whole measurement lost, and on a long ruler the midpoint
        // is frequently outside the display.
        let mid = CGPoint(x: (seg.a.x + seg.b.x) / 2, y: (seg.a.y + seg.b.y) / 2)
        let dx = seg.b.x - seg.a.x, dy = seg.b.y - seg.a.y
        let len = max(hypot(dx, dy), 0.001)
        let offset = CGPoint(x: -dy / len * (h / 2 + 8), y: dx / len * (h / 2 + 8))
        var origin = CGPoint(x: mid.x + offset.x - w / 2, y: mid.y + offset.y - h / 2)
        origin.x = min(max(origin.x, 6), max(size.width - w - 6, 6))
        origin.y = min(max(origin.y, 6), max(size.height - h - 6, 6))
        let box = CGRect(origin: origin, size: CGSize(width: w, height: h))

        ctx.fill(Path(roundedRect: box, cornerRadius: DS.Radius.r2), with: .color(palette.overlay))
        ctx.stroke(Path(roundedRect: box, cornerRadius: DS.Radius.r2),
                   with: .color(live ? palette.warn : palette.border), lineWidth: 1)
        ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.minY + padding + summarySize.height / 2))
        if let resolvedNote {
            ctx.draw(resolvedNote,
                     at: CGPoint(x: box.midX, y: box.minY + padding + summarySize.height + 1 + noteSize.height / 2))
        }
    }
}
