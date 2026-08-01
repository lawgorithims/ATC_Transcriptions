import SwiftUI

/// The VECTOR chart (items 1–7, 9): a published procedure drawn from its coded geometry, scalable,
/// with progressive disclosure and multi-colour typography.
///
/// Renders through `Canvas` rather than MapLibre on purpose. This is a CHART, not a map: it frames the
/// procedure to itself, has no basemap, no tiles and no network, and must draw identically offline at
/// any zoom. Putting it on the map engine would inherit a camera, a tile pipeline and a projection it
/// does not want, for nothing.
///
/// ⚠️ IT SAYS WHAT IT IS NOT. MSA rings and circling protected areas are absent because the data is not
/// in the bundle — see `VectorProcedureChart` — and a chart that silently omitted them would look
/// complete. The footer names the plate as the authority instead.
struct VectorProcedureView: View {
    let chart: VectorProcedureChart
    let palette: Palette
    let theme: MapTheme
    /// The field, used to frame a departure or arrival on its terminal end. nil frames whole.
    var field: Coord? = nil

    @State private var zoom: Double = 1
    @State private var committedZoom: Double = 1

    var body: some View {
        GeometryReader { geo in
            // A SID or STAR opens on its terminal end — see VectorProcedureChart.Framing for why
            // fitting one to its whole 200 NM extent produces a chart with no readable detail.
            let framed = chart.extent(.default(for: chart.kind), field: field)
            let base = VectorChartGeometry.fitting(framed, in: geo.size)
            if let base {
                let g = base.zoomed(zoom)
                let detail = ChartDetail.forScale(nmAcross: g.nmPerPoint * Double(g.size.width))
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(chart, g: g, detail: detail, ctx: &ctx) }
                        .background(Color(theme.sea))
                    header(g, detail: detail)
                    VStack { Spacer(); footer(detail) }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { zoom = committedZoom * $0 }
                        .onEnded { _ in
                            // Bounded: past these the chart is either a dot or a single fix filling the
                            // screen, and neither is a chart.
                            committedZoom = min(max(zoom, 0.5), 12)
                            zoom = committedZoom
                        })
                .accessibilityIdentifier("vector-procedure")
            } else {
                // No geometry to draw. Say so — an empty canvas reads as "this procedure is simple".
                Text("This procedure publishes no plottable geometry.")
                    .font(.dsLabel).foregroundStyle(palette.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: drawing

    private func draw(_ chart: VectorProcedureChart, g: VectorChartGeometry,
                      detail: ChartDetail, ctx: inout GraphicsContext) {
        for p in chart.visible(at: detail) {                             // bounded by primitive cap
            switch p {
            case .track(let coords):
                guard coords.count >= 2 else { continue }
                var path = Path()
                path.move(to: g.point(coords[0]))
                for c in coords.dropFirst() { path.addLine(to: g.point(c)) }
                ctx.stroke(path, with: .color(Color(theme.route)), lineWidth: 2.2)

            case .runway(let a, let b, let designator):
                var path = Path()
                path.move(to: g.point(a)); path.addLine(to: g.point(b))
                // TO SCALE (item 9): the runway is drawn from its own thresholds, so its length on
                // screen is its real length. A fixed-size runway glyph would be a lie about distance.
                ctx.stroke(path, with: .color(.white), lineWidth: 3.5)
                if detail >= .idents {
                    label(designator, at: g.point(b), ctx: &ctx, color: .white, size: 9)
                }

            case .fix(let f):
                let pt = g.point(f.coord)
                // MULTI-COLOUR TYPOGRAPHY (item 7): the mark and its text carry the same meaning the
                // moving map gives them — role by hue, restriction by the sublabel's colour — so a
                // pilot reads one vocabulary in both places.
                let tint = Color(roleColor(f.role))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)),
                         with: .color(tint))
                if chart.showsIdent(f, at: detail) {
                    label(f.ident, at: CGPoint(x: pt.x + 6, y: pt.y - 8), ctx: &ctx,
                          color: tint, size: 10, weight: .semibold)
                }
                if chart.showsRestriction(f, at: detail),
                   let alt = SmartRouteLabel.altText(f.constraint) {
                    label(alt, at: CGPoint(x: pt.x + 6, y: pt.y + 3), ctx: &ctx,
                          color: Color(theme.routeWptAlt), size: 9)
                }
                if detail >= .restrictions, let spd = SmartRouteLabel.speedText(f.constraint) {
                    label(spd, at: CGPoint(x: pt.x + 6, y: pt.y + 13), ctx: &ctx,
                          color: Color(theme.routeWptSpeed), size: 9)
                }

            case .unplacedLeg(let from, let courseMag, let text):
                // A leg with no endpoint is drawn as a DASHED ray in its published direction, stopping
                // short — it must not look like a path to a fix, because there is no fix.
                let a = g.point(from)
                let brg = (courseMag ?? 0) * .pi / 180
                let b = CGPoint(x: a.x + sin(brg) * 46, y: a.y - cos(brg) * 46)
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(Color(theme.route).opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                label(text, at: CGPoint(x: b.x + 4, y: b.y), ctx: &ctx,
                      color: Color(theme.routeWptText).opacity(0.85), size: 9)
            }
        }
    }

    private func roleColor(_ r: LegRole) -> UIColor {
        switch r {
        case .initialApproachFix:   return theme.routeWptIAF
        case .finalApproachFix:     return theme.routeWptFAF
        case .missedApproachPoint:  return theme.routeWptMAP
        default:                    return theme.routeWptText
        }
    }

    private func label(_ s: String, at p: CGPoint, ctx: inout GraphicsContext,
                       color: Color, size: CGFloat, weight: Font.Weight = .regular) {
        ctx.draw(Text(s).font(.system(size: size, weight: weight)).foregroundColor(color),
                 at: p, anchor: .topLeading)
    }

    // MARK: chrome

    @ViewBuilder private func header(_ g: VectorChartGeometry, detail: ChartDetail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(chart.procedureName).font(.dsLabelBold).foregroundStyle(palette.text)
            // The chart STATES its scale rather than implying one — the point of drawing to scale.
            Text("\(chart.airport)  ·  \(g.scaleLabel)")
                .font(.dsLabelS).foregroundStyle(palette.textDim)
        }
        .padding(8)
    }

    @ViewBuilder private func footer(_ detail: ChartDetail) -> some View {
        HStack {
            if detail < .restrictions {
                Text("zoom in for crossing restrictions")
                    .font(.system(size: 9)).foregroundStyle(palette.textDim)
            }
            Spacer()
            // Naming what is absent is the honest half of drawing from coded data.
            Text("no MSA or circling area — see the plate")
                .font(.system(size: 9)).foregroundStyle(palette.textDim)
        }
        .padding(8)
    }
}
