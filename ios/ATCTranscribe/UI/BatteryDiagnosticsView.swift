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
                            KV("CPU", String(format: "%.0f%% of a core", s.cpu))
                            KV("Map", String(format: "%.1f fps%@", s.mapFPS, s.engine == "maplibre" ? "" : " (classic)"))
                            KV("Whisper", String(format: "%.0f%% of last min", s.whisperPct))
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

                if battery.samples.count >= 3 {
                    Card(title: "By activity (averages)") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Isolates the drain: compare CPU (Whisper/ANE) and map fps (idle redraw) across what the app was doing.")
                                .font(.caption2).foregroundStyle(p.textDim)
                            ForEach(Self.byActivity(battery.samples), id: \.tag) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.tag).font(.caption2.weight(.semibold)).foregroundStyle(p.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(String(format: "CPU %.0f%% · map %.1f fps · whisper %.0f%% · %d min",
                                                row.cpu, row.fps, row.whisper, row.count))
                                        .font(.caption2.monospaced()).foregroundStyle(p.textDim)
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

    struct ActivityRow { let tag: String; let cpu: Double; let fps: Double; let whisper: Double; let count: Int }
    /// Average CPU / map-fps / whisper% grouped by the activity tag, busiest groups first. Bounded loops.
    private static func byActivity(_ samples: [BatteryDiagnostics.Sample]) -> [ActivityRow] {
        var g: [String: (cpu: Double, fps: Double, whisper: Double, n: Int)] = [:]
        for s in samples.suffix(720) {                                // bounded by the ring (rule 2)
            var v = g[s.activity] ?? (0, 0, 0, 0)
            v.cpu += s.cpu; v.fps += s.mapFPS; v.whisper += s.whisperPct; v.n += 1
            g[s.activity] = v
        }
        assert(g.count <= 720, "activity grouping overflow")
        let rows = g.map { (k, v) -> ActivityRow in
            let n = Double(max(v.n, 1))
            return ActivityRow(tag: k, cpu: v.cpu / n, fps: v.fps / n, whisper: v.whisper / n, count: v.n)
        }
        return Array(rows.sorted { $0.count > $1.count }.prefix(12))   // bounded display
    }
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
