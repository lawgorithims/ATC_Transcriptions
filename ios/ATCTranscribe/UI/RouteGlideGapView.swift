import SwiftUI

/// The detail behind the flight-plan strip's OUT OF GLIDE cell: how much of the route has no runway
/// in reach, where the gaps are, and what altitude would close the worst of them.
///
/// Preflight on purpose. This is the one use of the reach model that costs no head-down time: the
/// altitude a pilot files decides most of their exposure, and it is decided on the ground.
struct RouteGlideGapView: View {
    @EnvironmentObject var model: AppModel

    private var p: Palette { model.palette }
    private var tas: Double? { model.selectedAircraft?.cruiseKts.map(Double.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Out of glide of any runway").font(.dsHeadline).foregroundStyle(p.text)
            if let r = model.routeGlideExposure {
                summary(r)
                suggestion(r)
                if !r.gaps.isEmpty { gapList(r) }
            } else {
                Text("File a route with a cruise altitude to see where it leaves glide range of every runway.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
            }
            Text(Self.caveat)
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 300, maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .contain)     // or this id shadows the summary's own
        .accessibilityIdentifier("glide-gap-detail")
    }

    static let caveat = "Runways only — off-field ground is not counted. Uses your glide ratio, a 1,000 ft "
        + "arrival reserve, the turn onto each airport from the leg's course, and any forecast headwind "
        + "(a tailwind is never credited). The route as filed, direct between its points."

    private func summary(_ r: RouteGlideExposure.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("At \(Int(r.altitudeFtMSL).formatted()) ft: \(Self.percent(r.exposedFraction)) of "
                 + "\(Int(r.routeNm.rounded())) NM")
                .font(.dsLabelBold).foregroundStyle(p.text)
            Text("Longest gap \(Self.gapText(r, tas: tas))\(r.usedWind ? " · forecast headwinds applied" : " · still air")")
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
        .accessibilityIdentifier("glide-gap-summary")
    }

    @ViewBuilder private func suggestion(_ r: RouteGlideExposure.Result) -> some View {
        if let s = model.routeGlideSuggestion, s.altitudeFtMSL > r.altitudeFtMSL {
            Label("At \(Int(s.altitudeFtMSL).formatted()) ft the longest gap is \(Self.gapText(s, tas: tas)) "
                  + "(\(Self.percent(s.exposedFraction)) of the route)",
                  systemImage: "arrow.up.circle.fill")
                .font(.dsLabel).foregroundStyle(p.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("glide-gap-suggestion")
        } else if r.longestGapNm > 0 {
            Text("No altitude up to \(Int(RouteGlideExposure.maxSuggestedAltitudeFt).formatted()) ft brings the "
                 + "longest gap under \(Int(AppModel.glideGapTargetMinutes)) minutes on this route.")
                .font(.dsLabelS).foregroundStyle(p.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gapList(_ r: RouteGlideExposure.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(r.gaps.sorted { $0.lengthNm > $1.lengthNm }.prefix(5).enumerated()), id: \.offset) { _, g in
                Text("NM \(Int(g.fromNm.rounded()))–\(Int(g.toNm.rounded())) along the route · "
                     + "\(Int(g.lengthNm.rounded())) NM\(tas.map { " · \(Int((g.lengthNm / $0 * 60).rounded())) min" } ?? "")")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(p.text)
            }
        }
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    static func gapText(_ r: RouteGlideExposure.Result, tas: Double?) -> String {
        if let m = r.longestGapMinutes(tasKt: tas) { return "\(Int(m.rounded())) min" }
        return "\(Int(r.longestGapNm.rounded())) NM"
    }

    /// The strip cell's value: "58% · 20 min", or "–" before there is anything to say.
    static func cellText(_ r: RouteGlideExposure.Result?, tas: Double?) -> String {
        guard let r else { return "–" }
        return "\(percent(r.exposedFraction)) · \(gapText(r, tas: tas))"
    }
}
