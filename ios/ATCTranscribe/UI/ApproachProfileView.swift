import SwiftUI

/// The profile view: the final segment seen from the side, with the aircraft in it.
///
/// This is the half of an approach chart a pilot cannot get from the plan view — the answer to *am I on
/// the path, or above it, or below it?* On a paper plate that question is answered by cross-referencing
/// a DME distance against a printed altitude while flying an approach; here the aircraft is simply drawn
/// where it is. Reading left to right in the direction of flight, exactly as the chart does.
///
/// WHAT IT WILL NOT SAY. Decision altitudes and minimum descent altitudes are chart-only data — they do
/// not exist in the coded procedure — so this draws the published path and the published constraints and
/// never prints a minimum. The plate remains the authority for minima, and the caption says so, because a
/// profile that quietly omitted the one number the segment ends at would read as though there wasn't one.
struct ApproachProfileView: View {
    @EnvironmentObject var model: AppModel
    let profile: ApproachProfile
    /// Live aircraft position in the profile, or nil when it is not on this segment.
    let position: ApproachProfile.Position?
    /// Terrain under the final segment, sampled outermost → threshold, for the shaded ground.
    let terrain: [ApproachTerrainSample]
    /// ITEM 32: "not authorised" annotations, each at the station where the limitation begins. Empty is
    /// the normal case — see `ApproachProfile.naAnnotations`, which states one only when the condition
    /// is KNOWN to apply.
    var annotations: [ApproachProfile.NAAnnotation] = []

    private var p: Palette { model.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    terrainShape(geo.size)
                    pathShape(geo.size)
                    constraintMarks(geo.size)
                    naMarks(geo.size)
                    if let position { ownship(geo.size, position) }
                }
            }
            .frame(height: 132)
            .background(p.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(p.border, lineWidth: DS.Stroke.hairline))
            caption
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approach-profile")
    }

    // MARK: geometry

    /// Along-track NM covered by the drawing, outermost station out to the threshold.
    private var spanNm: Double { max(profile.stations.first?.distanceToThresholdNm ?? 10, 1) }
    /// Altitude window, padded so the path and the terrain both sit inside it.
    private var altRange: (lo: Double, hi: Double) {
        var lo = profile.thresholdElevFt ?? 0
        var hi = profile.thresholdCrossingAltFt ?? 1000
        for s in profile.stations { if let f = s.floorFt { hi = max(hi, f) } }   // bounded by stations
        for t in terrain { lo = min(lo, t.elevationFt); hi = max(hi, t.elevationFt) }
        if let position { hi = max(hi, position.altitudeFtMSL); lo = min(lo, position.altitudeFtMSL) }
        let pad = max((hi - lo) * 0.12, 200)
        return (lo - pad * 0.35, hi + pad)
    }

    /// Distance-from-threshold → x. The THRESHOLD is on the right, because that is the direction of
    /// flight and the direction every profile view on every plate is drawn in.
    private func x(_ nm: Double, _ size: CGSize) -> CGFloat {
        CGFloat(1 - min(max(nm / spanNm, 0), 1)) * size.width
    }
    private func y(_ ft: Double, _ size: CGSize) -> CGFloat {
        let r = altRange
        let span = max(r.hi - r.lo, 1)
        return CGFloat(1 - min(max((ft - r.lo) / span, 0), 1)) * size.height
    }

    // MARK: layers

    /// The ground, filled. Terrain in a profile is not decoration: the reason the vertical picture exists
    /// is that a glide path clears obstacles by a margin the plan view cannot show.
    @ViewBuilder private func terrainShape(_ size: CGSize) -> some View {
        if terrain.count >= 2 {
            Path { path in
                path.move(to: CGPoint(x: x(terrain[0].distanceNm, size), y: size.height))
                for t in terrain.prefix(256) {                          // bounded (rule 2)
                    path.addLine(to: CGPoint(x: x(t.distanceNm, size), y: y(t.elevationFt, size)))
                }
                path.addLine(to: CGPoint(x: x(terrain[terrain.count - 1].distanceNm, size), y: size.height))
                path.closeSubpath()
            }
            .fill(p.textDim.opacity(0.28))
        }
    }

    /// The published path. A glidepath is a straight descending line to the threshold; a non-precision
    /// procedure is a STAIRCASE of floors — drawing the second as the first would invent guidance the
    /// procedure does not provide.
    @ViewBuilder private func pathShape(_ size: CGSize) -> some View {
        if profile.descentAngleDeg != nil, profile.hasVerticalGuidance {
            Path { path in
                let start = profile.stations.first?.distanceToThresholdNm ?? spanNm
                if let a0 = profile.pathAltitudeFt(atNm: start), let a1 = profile.pathAltitudeFt(atNm: 0) {
                    path.move(to: CGPoint(x: x(start, size), y: y(a0, size)))
                    path.addLine(to: CGPoint(x: x(0, size), y: y(a1, size)))
                }
            }
            .stroke(p.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        } else {
            // Advisory / non-precision: the floors, joined. Dashed, because it is a set of limits the
            // pilot descends WITHIN, not a beam they track.
            Path { path in
                var started = false
                for s in profile.stations.prefix(256) where s.floorFt != nil {   // bounded (rule 2)
                    let pt = CGPoint(x: x(s.distanceToThresholdNm, size), y: y(s.floorFt!, size))
                    if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
                }
            }
            .stroke(p.accent, style: StrokeStyle(lineWidth: 2.0, dash: [5, 3]))
        }
    }

    /// Fix ticks with their published crossing altitudes, plus the FAF and MAP called out by name.
    @ViewBuilder private func constraintMarks(_ size: CGSize) -> some View {
        ForEach(profile.stations.prefix(24)) { s in                     // bounded (rule 2)
            let px = x(s.distanceToThresholdNm, size)
            Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) }
                .stroke(p.border.opacity(s.isFAF || s.isMAP ? 0.9 : 0.35),
                        style: StrokeStyle(lineWidth: s.isFAF || s.isMAP ? 1.2 : 0.7,
                                           dash: s.isFAF || s.isMAP ? [] : [2, 3]))
            VStack(alignment: .leading, spacing: 0) {
                Text(label(for: s)).font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(s.isFAF || s.isMAP ? p.accent : p.textDim)
                if let f = s.floorFt {
                    Text("\(Int(f))").font(.system(size: 8)).foregroundStyle(p.textDim)
                }
            }
            .fixedSize()
            .position(x: px + 16, y: 12)
        }
    }

    /// ITEM 32: a NOT-AUTHORISED band drawn AT the station the limitation starts from, not as a caption.
    ///
    /// A Baro-VNAV temperature limit does not apply to the whole approach — it applies from the final
    /// approach fix inward, which is a place on this drawing. Putting it there says which part of the
    /// descent is unavailable; putting it in a footnote would only say that something is.
    @ViewBuilder private func naMarks(_ size: CGSize) -> some View {
        ForEach(Array(annotations.enumerated()), id: \.offset) { _, a in
            let px = x(a.atNm, size)
            Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height)) }
                .stroke(self.p.bad.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
            // Inward of the fix is the part that is unavailable, so the shading runs to the threshold.
            Rectangle()
                .fill(self.p.bad.opacity(0.10))
                .frame(width: max(0, size.width - px), height: size.height)
                .offset(x: px)
            Text(a.text)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(self.p.bad)
                .padding(.horizontal, 3)
                .background(self.p.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                .offset(x: min(px + 3, size.width - 96), y: 3)
                .accessibilityIdentifier("profile-na")
        }
    }

    private func label(for s: ApproachProfile.Station) -> String {
        if s.isFAF { return "FAF \(s.fix)" }
        if s.isMAP { return "MAP" }
        return CIFP.isRunwayPseudoFix(s.fix) ? "THR" : s.fix
    }

    /// The aircraft, at its along-track distance and its altitude. This is the whole point of the view.
    @ViewBuilder private func ownship(_ size: CGSize, _ pos: ApproachProfile.Position) -> some View {
        let px = x(pos.distanceNm, size), py = y(pos.altitudeFtMSL, size)
        Image(systemName: "airplane")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(deviationColor(pos))
            .rotationEffect(.degrees(180))          // nose left→right along the direction of flight
            .position(x: px, y: py)
            .accessibilityHidden(true)
    }

    /// Green on the path, amber off it, red well off it — but ONLY where a path exists to be off.
    /// With no published guidance every altitude inside the floors is equally legal, and colouring one of
    /// them "wrong" would be inventing a target.
    private func deviationColor(_ pos: ApproachProfile.Position) -> Color {
        guard profile.hasVerticalGuidance, let d = pos.deviationFt else { return p.text }
        if abs(d) <= 100 { return p.good }
        if abs(d) <= 300 { return p.warn }
        return p.bad
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: 6) {
            Text("PROFILE").font(.dsLabelSBold).foregroundStyle(p.textDim)
            Text(profile.approachName).font(.dsLabelS).foregroundStyle(p.text).lineLimit(1)
            Spacer(minLength: 0)
            if let a = profile.descentAngleDeg {
                Text(String(format: profile.hasVerticalGuidance ? "GP %.2f°" : "VDA %.2f°", a))
                    .font(.dsLabelS).foregroundStyle(p.accent)
            }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pos = position, let dev = pos.deviationFt, profile.hasVerticalGuidance {
                Text(String(format: "%.1f NM to threshold · %@ %d ft",
                            pos.distanceNm, dev >= 0 ? "above path" : "below path", Int(abs(dev))))
                    .font(.dsLabelS).foregroundStyle(p.text)
            } else if let pos = position {
                Text(String(format: "%.1f NM to threshold · %d ft MSL", pos.distanceNm, Int(pos.altitudeFtMSL)))
                    .font(.dsLabelS).foregroundStyle(p.text)
            }
            if let vs = verticalSpeedAdvice {
                Text(vs).font(.dsLabelS).foregroundStyle(p.textDim)
            }
            // The one thing this view is not allowed to imply it knows.
            Text(profile.hasVerticalGuidance
                 ? "Published path and crossing altitudes. DA and visibility are on the plate — they are not in the coded procedure."
                 : "Published crossing altitudes — a descent angle here is ADVISORY and is not obstacle-assessed below MDA. MDA and visibility are on the plate.")
                .font(.system(size: 9)).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The rate that holds the path at the current groundspeed — the number the chart's inside-cover
    /// table exists to look up.
    private var verticalSpeedAdvice: String? {
        let merged = GPSReadout.merge(stratux: model.freshStratuxGPS, device: model.deviceLocation.fix)
        guard let gs = merged.groundSpeedKt, gs > 30,
              let fpm = profile.requiredVerticalSpeedFpm(groundSpeedKt: gs) else { return nil }
        return String(format: "%.0f kt GS → %d fpm to hold the path", gs, Int(fpm.rounded()))
    }
}

/// One terrain sample under the final segment.
struct ApproachTerrainSample: Equatable {
    let distanceNm: Double
    let elevationFt: Double
}
