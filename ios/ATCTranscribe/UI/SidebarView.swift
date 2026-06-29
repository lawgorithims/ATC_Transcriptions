import SwiftUI
import UniformTypeIdentifiers

/// A customizable sidebar card. The user picks which of these appear and in what order
/// (long-press to edit → add / remove / drag-reorder), so the layout can be trimmed for
/// iPad Split View / Slide Over. Order is the default layout; persisted in `AppModel`.
enum SidebarWidget: String, CaseIterable, Identifiable {
    case latency, proofOfLife, host, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .latency: return "Latency"
        case .proofOfLife: return "Performance check"
        case .host: return "Host"
        case .diagnostics: return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .latency: return "gauge.with.needle"
        case .proofOfLife: return "checkmark.seal"
        case .host: return "cpu"
        case .diagnostics: return "thermometer.medium"
        }
    }

    @ViewBuilder var card: some View {
        switch self {
        case .latency: LatencyCard()
        case .proofOfLife: ProofOfLifeCard()
        case .host: HostCard()
        case .diagnostics: DiagnosticsCard()
        }
    }
}

/// The right-hand column: a user-customizable stack of widget cards. Long-press any card for a
/// menu to remove that widget, add one that isn't shown (dropdown), or "Rearrange widgets" — which
/// enters a drag-to-reorder edit mode (remove controls + Add tile + "Done"). Every widget is
/// removable; emptying the sidebar hides the whole column so the transcript expands (see
/// `ConsoleView.mainArea`), and widgets are re-added from the "+" in the transcript header.
struct SidebarColumn: View {
    @EnvironmentObject var model: AppModel
    @State private var dragging: SidebarWidget?

    var body: some View {
        let p = model.palette
        VStack(spacing: 14) {
            ForEach(model.widgets) { widget in
                widgetCell(widget)
            }
            if model.editingWidgets {
                if !model.availableWidgets.isEmpty { AddWidgetTile() }
                Button { withAnimation { model.editingWidgets = false } } label: {
                    Text("Done").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(p.accent).foregroundStyle(p.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("widgets-done")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.widgets)
        .animation(.easeInOut(duration: 0.2), value: model.editingWidgets)
    }

    @ViewBuilder private func widgetCell(_ widget: SidebarWidget) -> some View {
        let card = widget.card
            .overlay(alignment: .topTrailing) {
                if model.editingWidgets {
                    Button { withAnimation { model.removeWidget(widget) } } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3).symbolRenderingMode(.palette)
                            .foregroundStyle(model.palette.bg, model.palette.bad)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                    .accessibilityIdentifier("widget-remove-\(widget.rawValue)")
                }
            }
            .overlay {
                if model.editingWidgets {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(model.palette.accent.opacity(0.7))
                }
            }

        if model.editingWidgets {
            card
                .opacity(dragging == widget ? 0.4 : 1)
                .onDrag {
                    dragging = widget
                    return NSItemProvider(object: widget.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate:
                    WidgetDropDelegate(item: widget, model: model, dragging: $dragging))
        } else {
            // Long-press any widget to open its menu: remove the touched widget, add one that isn't
            // shown yet (dropdown), or enter drag-to-reorder. Every sidebar widget is removable
            // (the transcript isn't a sidebar widget, so it always stays).
            card.contextMenu {
                Button(role: .destructive) {
                    withAnimation { model.removeWidget(widget) }
                } label: { Label("Remove \(widget.title)", systemImage: "minus.circle") }

                if !model.availableWidgets.isEmpty {
                    Menu {
                        ForEach(model.availableWidgets) { w in
                            Button { withAnimation { model.addWidget(w) } } label: {
                                Label(w.title, systemImage: w.symbol)
                            }
                        }
                    } label: { Label("Add widget", systemImage: "plus.circle") }
                }

                Button {
                    withAnimation { model.editingWidgets = true }
                } label: { Label("Rearrange widgets", systemImage: "arrow.up.arrow.down") }
            }
        }
    }
}

/// Dashed tile shown in edit mode; tapping opens a menu of widgets not currently on the sidebar.
struct AddWidgetTile: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        Menu {
            ForEach(model.availableWidgets) { w in
                Button { withAnimation { model.addWidget(w) } } label: {
                    Label(w.title, systemImage: w.symbol)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("Add widget").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(p.accent)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(p.border))
        }
        .accessibilityIdentifier("widget-add")
    }
}

/// Live drag-reorder: as the dragged card hovers over another, move it there. Runs on the main
/// actor (SwiftUI delivers drop callbacks on main); `assumeIsolated` lets us touch the model.
struct WidgetDropDelegate: DropDelegate {
    let item: SidebarWidget
    let model: AppModel
    @Binding var dragging: SidebarWidget?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging, dragging != item else { return }
            withAnimation { model.moveWidget(dragging, before: item) }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct LatencyCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Latency") {
            let ct = model.stats.captureToTextSummary
            let tr = model.stats.transcribeSummary
            let rtf = model.stats.realTimeFactorSummary
            let speed = rtf.flatMap { $0.mean > 0 ? 1.0 / $0.mean : nil }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatCell(value: "\(model.stats.count)", key: "transmissions")
                StatCell(value: ct.map { "\(Int($0.p50.rounded())) ms" } ?? "—", key: "capture→text p50")
                StatCell(value: tr.map { "\(Int($0.p50.rounded())) ms" } ?? "—", key: "transcribe p50")
                StatCell(value: speed.map { String(format: "%.1f×", $0) } ?? "—",
                         key: "speed (real-time)",
                         color: speed.map { model.palette.speedColor(realtime: $0) })
            }
        }
    }
}

struct StatCell: View {
    @EnvironmentObject var model: AppModel
    let value: String
    let key: String
    var color: Color? = nil
    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color ?? p.text)
            Text(key).font(.caption2).foregroundStyle(p.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProofOfLifeCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        Card(title: "Performance check") {
            if let pol = model.proofOfLife {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: pol.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(pol.passed ? p.good : p.bad)
                        Text(pol.passed ? "PASS" : "FAIL").font(.subheadline.weight(.bold))
                            .foregroundStyle(pol.passed ? p.good : p.bad)
                    }
                    if let wer = pol.meanWER {
                        KV("mean WER", String(format: "%.1f%%", wer * 100))
                    }
                    if let rt = pol.realtimeSpeed {
                        KV("speed", String(format: "%.1f× real-time", rt))
                    }
                    KV("model", pol.activeModel.map(ModelCatalog.shortLabel(forID:)) ?? "—")
                }
            } else {
                Text("Not checked yet.").font(.callout).foregroundStyle(p.textDim)
            }
            Button {
                model.runProofOfLife()
            } label: {
                Group {
                    if model.polRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).tint(p.text)
                            Text("Running…").font(.caption.weight(.semibold))
                        }
                    } else {
                        Label("Run performance check", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(p.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
            }
            .buttonStyle(.plain).foregroundStyle(p.text)
            .disabled(model.polRunning)
            .accessibilityIdentifier("proof-of-life-button")
            .padding(.top, 2)
        }
    }
}

struct HostCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Host") {
            VStack(spacing: 8) {
                KV("Device", model.deviceLabel)
                KV("Model", model.activeModelLabel)
                KV("Platform", "iOS / iPadOS")
            }
        }
    }
}

/// Live CPU / memory / thermal readouts for chasing down heat. Polls ~every 1.5 s, only while the
/// widget is on screen. iOS exposes no GPU/Neural-Engine % — thermal state is the proxy for that.
struct DiagnosticsCard: View {
    @EnvironmentObject var model: AppModel
    @State private var cpu = 0.0
    @State private var mem = 0.0
    @State private var thermal: ProcessInfo.ThermalState = .nominal
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = model.palette
        Card(title: "Diagnostics") {
            VStack(spacing: 8) {
                KV("CPU (app)", String(format: "%.0f%%", cpu))
                KV("Memory", String(format: "%.0f MB", mem))
                HStack {
                    Text("Thermal").font(.caption).foregroundStyle(p.textDim)
                    Spacer()
                    Text(thermal.label).font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(thermalColor(p))
                }
                Text("GPU / Neural Engine load isn't exposed by iOS — thermal state is the signal.")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        guard !model.standby else { return }   // don't poll device load while paused in standby
        cpu = DeviceLoad.cpuPercent()
        mem = DeviceLoad.memoryMB()
        thermal = DeviceLoad.thermalState()
    }

    private func thermalColor(_ p: Palette) -> Color {
        switch thermal {
        case .nominal: return p.good
        case .fair: return p.warn
        case .serious, .critical: return p.bad
        @unknown default: return p.text
        }
    }
}

/// A key/value row used inside the sidebar cards.
struct KV: View {
    @EnvironmentObject var model: AppModel
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    var body: some View {
        let p = model.palette
        HStack {
            Text(key).font(.caption).foregroundStyle(p.textDim)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(p.text)
        }
    }
}
