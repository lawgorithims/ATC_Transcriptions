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

    /// Drawn thicker than a chart line and with a casing under it, because this is read against a
    /// sectional — which is already full of magenta and blue lines of its own.
    private let lineWidth: CGFloat = 2.6
    /// Half-length of the perpendicular bar at each end — a dimension line's terminator.
    private let endBar: CGFloat = 9

    /// ⚠️ GRADUATION SPACING IN POINTS, NOT NAUTICAL MILES, and that is deliberate. These marks
    /// say "this is a measuring instrument"; they are not a scale and must not be read as one — the
    /// distance is in the label, to three significant figures, where it cannot be misread. A
    /// distance-based spacing would vanish at low zoom and carpet the chart at high.
    private let tickSpacing: CGFloat = 13
    /// Bounded (rule 2). A ruler drawn across a zoomed-in chart is thousands of points long, and the
    /// ticks stop rather than the frame rate.
    private let maxTicks = 240

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

        // ⚠️ NOT `palette.accent`, AND THAT IS THE WHOLE POINT OF THE REDESIGN. Accent is FAA
        // sectional blue — the colour of the route line and of half the chart underneath it — so a
        // ruler drawn in it read as a course the pilot had filed. Reported from the air as the ruler
        // being confused with the flight path.
        //
        // `palette.text` on a `palette.bg` casing instead, which inverts correctly in all three
        // themes without a hardcoded colour: white-on-black in the cockpit, black-on-white on the
        // day chart, red-on-black at night. No chart feature and no route is ever drawn this way.
        let ink = live ? palette.warn : palette.text
        ctx.stroke(line, with: .color(palette.bg.opacity(0.85)),
                   style: StrokeStyle(lineWidth: lineWidth + 3.4, lineCap: .round))
        ctx.stroke(line, with: .color(ink),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt,
                                      dash: live ? [7, 4] : []))

        drawGraduations(seg: seg, ink: ink, ctx: &ctx)

        // END BARS, not dots. A dimension line is terminated square across its axis, and that one
        // detail is what makes this read as a measurement at a glance rather than as a leg with
        // waypoints at the ends — which is exactly what two round caps on a coloured line look like.
        let (ux, uy) = unit(seg)
        for end in [seg.a, seg.b] {
            var bar = Path()
            bar.move(to: CGPoint(x: end.x - uy * endBar, y: end.y + ux * endBar))
            bar.addLine(to: CGPoint(x: end.x + uy * endBar, y: end.y - ux * endBar))
            ctx.stroke(bar, with: .color(palette.bg.opacity(0.85)),
                       style: StrokeStyle(lineWidth: lineWidth + 3.4, lineCap: .round))
            ctx.stroke(bar, with: .color(ink),
                       style: StrokeStyle(lineWidth: lineWidth + 0.6, lineCap: .round))
        }

        let readout = MapRulerMath.readout(ruler, groundSpeedKt: groundSpeedKt,
                                           cruiseKt: cruiseKt, variation: MagneticVariation.at)
        drawLabel(readout, seg: seg, live: live, ctx: &ctx, size: size)
    }

    /// The rule's graduations: short perpendicular ticks along the span, every fifth one longer.
    /// Drawn in the ink only — no casing — because they sit on top of a line that already has one.
    private func drawGraduations(seg: MapRulerStore.ScreenSegment, ink: Color,
                                 ctx: inout GraphicsContext) {
        let dx = seg.b.x - seg.a.x, dy = seg.b.y - seg.a.y
        let len = hypot(dx, dy)
        guard len > tickSpacing * 2 else { return }      // too short to graduate; the bars say enough
        let (ux, uy) = unit(seg)
        let count = min(Int(len / tickSpacing), maxTicks)
        guard count > 0 else { return }
        var ticks = Path()
        for i in 1..<max(count, 2) {                     // bounded by `maxTicks` (rule 2)
            let d = CGFloat(i) * tickSpacing
            guard d < len else { break }
            let h: CGFloat = i % 5 == 0 ? 6 : 3.5
            let p = CGPoint(x: seg.a.x + ux * d, y: seg.a.y + uy * d)
            ticks.move(to: CGPoint(x: p.x - uy * h, y: p.y + ux * h))
            ticks.addLine(to: CGPoint(x: p.x + uy * h, y: p.y - ux * h))
        }
        ctx.stroke(ticks, with: .color(ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .butt))
    }

    /// Unit vector along the segment. Guarded: a zero-length ruler would divide by zero and put NaN
    /// into every tick and bar, which Core Graphics draws as nothing at all.
    private func unit(_ seg: MapRulerStore.ScreenSegment) -> (CGFloat, CGFloat) {
        let dx = seg.b.x - seg.a.x, dy = seg.b.y - seg.a.y
        let len = max(hypot(dx, dy), 0.001)
        return (dx / len, dy / len)
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
