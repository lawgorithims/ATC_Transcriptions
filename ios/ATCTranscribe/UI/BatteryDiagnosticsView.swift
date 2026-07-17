import SwiftUI

/// Settings → General → Battery diagnostics. Turns the on-device sampler on/off, shows the current
/// battery/thermal/discharge state, the most recent samples tagged with what the app was doing, and the
/// latest MetricKit daily payload — with a Copy button to send the whole log to a dev machine.
struct BatteryDiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var battery: BatteryDiagnostics
    @State private var copied = false

    var body: some View {
        let p = model.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Collect battery data") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $battery.enabled) {
                            Text("Sample battery every minute").font(.caption).foregroundStyle(p.text)
                        }
                        .accessibilityIdentifier("battery-diag-toggle")
                        Text("Records battery level, thermal state, and what the app is doing (transcription, map layer, Stratux, GPS) once a minute while open, so a drain spike can be traced to a cause. Off costs nothing. Fly a normal session with it on, then Copy the log.")
                            .font(.caption2).foregroundStyle(p.textDim)
                    }
                }

                Card(title: "Now") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let s = battery.samples.last {
                            KV("Battery", s.level >= 0 ? "\(Int(s.level * 100))%\(s.charging ? " (charging)" : "")" : "n/a (Simulator)")
                            KV("Thermal", Self.thermalLabel(s.thermal))
                            KV("Doing", s.activity)
                        } else {
                            Text("No samples yet — enable collection above and leave the app open a couple of minutes.")
                                .font(.caption).foregroundStyle(p.textDim)
                        }
                        if let rate = battery.dischargeRate {
                            KV("Discharge", String(format: "%.1f %%/hr (recent avg)", rate))
                        } else if (battery.samples.last?.charging ?? false) {
                            KV("Discharge", "charging")
                        }
                    }
                }

                if let m = battery.metricSummary {
                    Card(title: "MetricKit (daily)") {
                        Text(m).font(.caption2.monospaced()).foregroundStyle(p.textDim)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !battery.samples.isEmpty {
                    Card(title: "Recent samples (\(battery.samples.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(battery.samples.suffix(24).reversed()) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Self.clock.string(from: s.at))
                                        .font(.caption2.monospaced()).foregroundStyle(p.textDim)
                                    Text(s.level >= 0 ? "\(Int(s.level * 100))%" : "—%")
                                        .font(.caption2.monospaced().weight(.semibold))
                                        .foregroundStyle(s.thermal >= 2 ? p.warn : p.text)
                                        .frame(width: 40, alignment: .leading)
                                    if s.charging {
                                        Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(p.accent)
                                            .frame(width: 20, alignment: .leading)
                                    } else { Color.clear.frame(width: 20, height: 1) }
                                    Text(s.activity).font(.caption2).foregroundStyle(p.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = battery.exportText()
                        copied = true; Haptics.impact(.light)
                    } label: {
                        Label(copied ? "Copied" : "Copy log", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("battery-diag-copy")
                    Spacer()
                    Button(role: .destructive) { battery.clear(); copied = false } label: {
                        Label("Clear", systemImage: "trash").font(.callout)
                    }
                    .buttonStyle(.plainHaptic)
                }
                .tint(p.accent)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Battery diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func thermalLabel(_ raw: Int) -> String {
        switch raw { case 0: return "Nominal"; case 1: return "Fair"; case 2: return "Serious"; default: return "Critical" }
    }
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
