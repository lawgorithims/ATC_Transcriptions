import SwiftUI

/// The Satellites page: where the GPS constellation is right now, how good the resulting geometry is,
/// and whether the receiver's own reported accuracy agrees with that geometry.
///
/// READ THIS BEFORE CHANGING ANYTHING HERE. Everything on the sky plot is COMPUTED, not measured. iOS
/// exposes no satellite list, no per-satellite SNR, no satellite count and no raw GNSS measurements —
/// that API exists on Android (`GnssMeasurement`), not on iOS, and there is no entitlement to request.
/// So the page propagates the bundled almanac's orbits for the current time and position, exactly as an
/// aviation RAIM-prediction tool does, and says so on the face of the page. The one genuinely MEASURED
/// number iOS gives us is `horizontalAccuracy`, and it is shown beside the prediction precisely so the
/// two can be compared — because their DISAGREEMENT is the only interference evidence available here:
/// geometry that should give a good fix, paired with an accuracy that is nothing like it, means
/// something is denying the signal. That comparison is what `GPSThreatClassifier` acts on.
struct SatellitesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var visible: [PredictedSatellite] {
        model.predictedSky.filter { $0.elevationDeg >= AppModel.maskDeg }
    }

    var body: some View {
        let p = model.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.almanac.isEmpty {
                    unavailableCard(p)
                } else if model.gpsFix == nil {
                    noFixCard(p)
                } else {
                    skyCard(p)
                    countsCard(p)
                    dopCard(p)
                    crossCheckCard(p)
                }
                provenanceCard(p)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Satellites")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("satellites-view")
    }

    // MARK: - Cards

    private func skyCard(_ p: Palette) -> some View {
        Card(title: "Sky view · predicted") {
            VStack(spacing: 8) {
                SkyPlot(satellites: visible, maskDeg: AppModel.maskDeg, palette: p)
                    .frame(maxWidth: 340)
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityIdentifier("sky-plot")
                Text("Computed from the bundled almanac for your position and the current time. "
                     + "North is up; the outer ring is the horizon and the centre is straight overhead.")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func countsCard(_ p: Palette) -> some View {
        let healthy = visible.filter(\.healthy).count
        let unhealthy = visible.count - healthy
        return Card(title: "In view") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    statTile("USABLE", "\(healthy)", healthy >= 5 ? p.good : p.warn, p)
                    statTile("MASK", "\(Int(AppModel.maskDeg))°", p.textDim, p)
                    if unhealthy > 0 { statTile("UNHEALTHY", "\(unhealthy)", p.warn, p) }
                }
                // Four satellites is the arithmetic minimum for a 3-D fix (three coordinates plus the
                // receiver clock). Five gives the redundancy a receiver needs to detect a bad one at
                // all, which is why that — not four — is the line where this page stops looking calm.
                Text(healthy >= 5
                     ? "Enough satellites for a redundant solution."
                     : (healthy >= 4
                        ? "Bare minimum for a 3-D fix — no redundancy to catch a faulty satellite."
                        : "Fewer than four usable satellites: a 3-D position is not possible from this geometry."))
                    .font(.caption2).foregroundStyle(healthy >= 5 ? p.textDim : p.warn)
            }
        }
    }

    private func dopCard(_ p: Palette) -> some View {
        Card(title: "Geometry · predicted DOP") {
            if let d = model.predictedDOP {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        statTile("PDOP", String(format: "%.1f", d.pdop), dopColor(d.pdop, p), p)
                        statTile("HDOP", String(format: "%.1f", d.hdop), dopColor(d.hdop, p), p)
                        statTile("VDOP", String(format: "%.1f", d.vdop), dopColor(d.vdop, p), p)
                    }
                    // The number pilots are used to seeing on a panel-mount receiver, explained: DOP is
                    // a multiplier on ranging error, so it says how much the SHAPE of the constellation
                    // amplifies whatever error the signals already carry — not how accurate the fix is.
                    Text("Dilution of precision multiplies ranging error: satellites spread across the sky "
                         + "give a low number, satellites clustered together give a high one. Vertical is "
                         + "always worse than horizontal because every satellite is above you.")
                        .font(.caption2).foregroundStyle(p.textDim)
                }
            } else {
                Text("Not enough satellites above the mask to compute geometry.")
                    .font(.caption).foregroundStyle(p.warn)
            }
        }
    }

    private func crossCheckCard(_ p: Palette) -> some View {
        let t = model.gpsThreat
        let measured = model.gpsIntegrity.horizontalAccuracyM
        return Card(title: "Predicted vs measured") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    statTile("GEOMETRY", t.geometry.label.uppercased(), geometryColor(t.geometry, p), p)
                    statTile("REPORTED ±", measured.map { "\(Int($0.rounded())) m" } ?? "—", p.text, p)
                }
                Text(t.advisory).font(.caption).foregroundStyle(t.warrantsAlert ? p.bad : p.textDim)
                Text("The left number is computed from orbits. The right one is the only satellite-related "
                     + "figure iOS actually measures. When good geometry is paired with a poor reported "
                     + "accuracy, geometry does not explain it — that is the interference signature.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
    }

    private func provenanceCard(_ p: Palette) -> some View {
        Card(title: "Where this comes from") {
            VStack(alignment: .leading, spacing: 6) {
                Text("iOS does not report satellites. There is no measured satellite list, signal strength, "
                     + "satellite count or DOP available to any iPhone or iPad app, so every satellite on "
                     + "this page is computed from published orbital elements — never observed.")
                    .font(.caption2).foregroundStyle(p.textDim)
                if let first = model.almanac.first {
                    let age = GPSAlmanac.ageDays(first, at: Date())
                    Text(String(format: "Almanac: %d satellites, GPS week %d, %.0f days old.",
                                model.almanac.count, first.week, abs(age)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(abs(age) > 90 ? p.warn : p.textDim)
                    if abs(age) > 90 {
                        Text("This almanac is old enough that the predicted positions have drifted. "
                             + "Update the app to refresh it.")
                            .font(.caption2).foregroundStyle(p.warn)
                    }
                }
                Text("Awareness only. Not for navigation, and not a substitute for a certified receiver.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
    }

    private func unavailableCard(_ p: Palette) -> some View {
        Card(title: "Satellites") {
            Text("No almanac is bundled with this build, so predicted satellite geometry is unavailable. "
                 + "GPS itself is unaffected — only this page's prediction is.")
                .font(.caption).foregroundStyle(p.textDim)
        }
    }

    private func noFixCard(_ p: Palette) -> some View {
        Card(title: "Satellites") {
            Text("Waiting for a GPS fix. Satellite positions depend on where you are, so the sky view "
                 + "appears once the device has a position.")
                .font(.caption).foregroundStyle(p.textDim)
        }
    }

    // MARK: - Bits

    private func statTile(_ label: String, _ value: String, _ tint: Color, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.textDim).tracking(0.5)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(p.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 0.5))
    }

    /// The conventional aviation reading of DOP: under 2 is good, 2-5 is usable, above 5 is poor.
    private func dopColor(_ v: Double, _ p: Palette) -> Color {
        v < 2 ? p.good : (v <= 5 ? p.warn : p.bad)
    }

    private func geometryColor(_ g: GPSGeometryVerdict, _ p: Palette) -> Color {
        switch g {
        case .good:    return p.good
        case .fair:    return p.warn
        case .poor:    return p.bad
        case .unknown: return p.textDim
        }
    }
}

/// A polar sky plot: azimuth around, elevation as radius (horizon at the rim, zenith at the centre).
/// Pure geometry over a value array — no state, no timers; it redraws when the prediction changes.
struct SkyPlot: View {
    let satellites: [PredictedSatellite]
    let maskDeg: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: side / 2, y: side / 2)
            let r = side / 2 - 10
            ZStack {
                ringsAndSpokes(center: c, radius: r)
                ForEach(satellites.prefix(64), id: \.prn) { s in            // bounded (rule 2)
                    let pt = Self.point(az: s.azimuthDeg, el: s.elevationDeg, center: c, radius: r)
                    ZStack {
                        Circle()
                            .fill(s.healthy ? palette.accent : palette.warn)
                            .frame(width: 22, height: 22)
                        Text("\(s.prn)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .position(pt)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Sky plot with \(satellites.count) predicted satellites above the mask angle")
    }

    private func ringsAndSpokes(center c: CGPoint, radius r: CGFloat) -> some View {
        ZStack {
            // Elevation rings at 0/30/60 degrees, plus the mask ring the count card refers to.
            ForEach([0.0, 30.0, 60.0], id: \.self) { el in
                Circle()
                    .stroke(palette.border, lineWidth: el == 0 ? 1.2 : 0.5)
                    .frame(width: 2 * r * CGFloat(1 - el / 90), height: 2 * r * CGFloat(1 - el / 90))
                    .position(c)
            }
            Circle()
                .stroke(palette.warn.opacity(0.55), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .frame(width: 2 * r * CGFloat(1 - maskDeg / 90), height: 2 * r * CGFloat(1 - maskDeg / 90))
                .position(c)
            ForEach(Self.cardinals, id: \.name) { card in
                Text(card.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textDim)
                    .position(Self.point(az: card.az, el: -6, center: c, radius: r))
            }
        }
    }

    /// The four cardinal labels around the rim, as data so the ForEach has a concrete element type.
    static let cardinals: [(name: String, az: Double)] =
        [("N", 0), ("E", 90), ("S", 180), ("W", 270)]

    /// Azimuth is clockwise from north and elevation shrinks the radius, so a satellite overhead lands
    /// in the centre and one on the horizon lands on the rim — the standard GPS sky-view convention.
    static func point(az: Double, el: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let rr = radius * CGFloat(1 - max(min(el, 90), -10) / 90)
        let a = (az - 90) * .pi / 180                       // 0° = north = up
        return CGPoint(x: center.x + rr * CGFloat(cos(a)), y: center.y + rr * CGFloat(sin(a)))
    }
}
