import SwiftUI

/// On-screen GPS readout — signal quality, altitude (ft MSL), ground speed (kt) and track (°) — merged from
/// the Stratux fix (preferred, richer) or the on-device CoreLocation fix (the contingency for pilots with NO
/// Stratux), else "no fix". A floating widget (enable it from the Widgets menu). Reads only; never a 2nd GPS.
struct GPSReadoutCard: View {
    @EnvironmentObject var model: AppModel
    // The device fix is bridged from the nested DeviceLocation object — a nested ObservableObject doesn't
    // republish its parent (AppModel), so we subscribe to its publisher directly (mirrors MapHostView).
    @State private var deviceFix: DeviceFix?

    var body: some View {
        let r = GPSReadout.merge(stratux: model.stratuxGPS, device: deviceFix)
        Card(title: "GPS") {
            signal(r)
            KV("Altitude", r.altitudeFtMSL.map { "\(Int($0.rounded())) ft" } ?? "—")
            KV("Ground speed", r.groundSpeedKt.map { "\(Int($0.rounded())) kt" } ?? "—")
            KV("Track", r.trackDeg.map { String(format: "%03.0f°", $0) } ?? "—")
        }
        .accessibilityIdentifier("gps-card")
        .onReceive(model.deviceLocation.$fix) { deviceFix = $0 }
    }

    /// 4-bar quality indicator + a source-specific quality string + a source badge (STRATUX / DEVICE GPS /
    /// ACQUIRING…) so the pilot always knows which fix is being shown.
    @ViewBuilder private func signal(_ r: GPSReadout) -> some View {
        let p = model.palette
        HStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < r.fixQuality.bars ? Self.qualityColor(r.fixQuality) : p.textDim.opacity(0.25))
                        .frame(width: 4, height: 6 + CGFloat(i) * 4)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(qualityText(r)).font(.caption.weight(.semibold)).foregroundStyle(p.text)
                Text(sourceLabel(r.source)).font(.caption2).foregroundStyle(p.textDim).tracking(0.6)
            }
            Spacer()
        }
    }

    private func qualityText(_ r: GPSReadout) -> String {
        switch r.source {
        case .stratux:
            let sats = r.satellites.map { " · \($0) sat" } ?? ""
            return (model.stratuxGPS?.fixLabel ?? r.fixQuality.label) + sats     // "3D GPS · 11 sat" / "WAAS · …"
        case .device:
            return r.horizontalAccuracyM.map { "\(r.fixQuality.label) · ±\(Int($0.rounded())) m" } ?? r.fixQuality.label
        case .none:
            return "No fix"
        }
    }

    private func sourceLabel(_ s: GPSReadout.Source) -> String {
        switch s {
        case .stratux: return "STRATUX"
        case .device:  return "DEVICE GPS"
        case .none:    return "ACQUIRING…"
        }
    }

    private static func qualityColor(_ q: FixQuality) -> Color {
        switch q {
        case .none:            return .gray
        case .poor:            return .orange
        case .fair:            return .yellow
        case .good, .excellent: return .green
        }
    }
}
