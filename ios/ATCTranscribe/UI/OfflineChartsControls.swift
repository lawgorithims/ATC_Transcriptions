import SwiftUI

/// Settings → Offline charts: download the entire US VFR / IFR chart set for offline use, with a live
/// size estimate, progress, a cellular-data confirmation, and a way to reclaim the space. Backed by the
/// shared `ChartLibrary`, which pins bulk-downloaded packs so the free-pan LRU cap never evicts them.
struct OfflineChartsControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var library = ChartLibrary.shared

    @State private var scope: Scope = .both
    @State private var warming = true
    @State private var confirmCellular = false

    /// What to store offline. The whole lower-48 is ~1.4 GB VFR + ~0.5 GB IFR ≈ 1.9 GB together.
    enum Scope: String, CaseIterable, Identifiable {
        case vfr = "VFR", ifr = "IFR", both = "Both"
        var id: String { rawValue }
        var layers: [ChartLayer] {
            switch self {
            case .vfr:  return [.sectional]
            case .ifr:  return [.ifrLow, .ifrHigh]
            case .both: return [.sectional, .ifrLow, .ifrHigh]
            }
        }
        var noun: String {
            switch self { case .vfr: return "VFR sectional"; case .ifr: return "IFR low + high"; case .both: return "VFR + IFR" }
        }
    }

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 10) {
            KV("Stored on device", library.cachedBytes > 0 ? size(library.cachedBytes) : "None")

            Picker("Charts", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(isDownloading)
            .accessibilityIdentifier("offline-charts-scope")

            switch library.bulk {
            case .running(let done, let total):
                VStack(spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(p.accent)
                    HStack {
                        Text("Downloading \(done) of \(total) packs…").font(.caption2).foregroundStyle(p.textDim)
                        Spacer()
                        Button("Cancel") { library.cancelBulkDownload() }
                            .font(.caption2.weight(.semibold)).foregroundStyle(p.bad)
                    }
                }
            default:
                Button { downloadTapped() } label: {
                    Text(downloadLabel)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(canDownload ? p.accent : p.surfaceAlt)
                        .foregroundStyle(canDownload ? p.bg : p.textDim)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canDownload)
                .accessibilityIdentifier("offline-charts-download")
            }

            if library.cachedBytes > 0 {
                Button(role: .destructive) { Haptics.impact(.light); library.removeAllCachedCharts() } label: {
                    Text("Remove downloaded charts").font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(p.surfaceAlt).foregroundStyle(p.bad)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            }

            Text("Downloads every US \(scope.noun) chart so the map works fully offline in the cockpit. Charts refresh on a 56-day cycle — re-download when a new cycle lands. Stored in the app cache; iOS may reclaim it under storage pressure.")
                .font(.caption2).foregroundStyle(p.textDim)
        }
        .task {
            warming = true
            _ = await library.warm()
            library.refreshCachedBytes()
            warming = false
        }
        .alert("Download over cellular?", isPresented: $confirmCellular) {
            Button("Download") { library.startBulkDownload(layers: scope.layers) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're on a cellular connection. Downloading \(size(library.remainingBytes(scope.layers))) of charts may use your mobile data.")
        }
    }

    // MARK: state

    private var isDownloading: Bool { if case .running = library.bulk { return true }; return false }
    private var ready: Bool { !warming && library.catalog != nil }
    private var remaining: Int { library.remainingBytes(scope.layers) }
    private var canDownload: Bool { ready && remaining > 0 }

    private var downloadLabel: String {
        guard ready else { return "Loading chart index…" }
        if remaining == 0 { return "All \(scope.rawValue) charts downloaded" }
        return "Download \(scope.rawValue) — \(size(remaining))"
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func downloadTapped() {
        Haptics.impact(.light)
        Task {
            if await library.isExpensiveConnection() {
                confirmCellular = true
            } else {
                library.startBulkDownload(layers: scope.layers)
            }
        }
    }
}
