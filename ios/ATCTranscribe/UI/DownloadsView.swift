import SwiftUI

/// The Downloads page — one place to manage all offline content, grouped by content type with regions
/// nested, each row showing whether it's downloaded and (via the FAA cycle stamped into every cached
/// file) whether it's up to date:
///
///  • CHARTS — the FAA raster tile packs the moving map draws: VFR sectional, IFR low, IFR high. Each
///    pack IS a region; `ChartLibrary` downloads/pins per pack (56-day cycle). A cached file always
///    carries the current cycle (old-cycle files are pruned), so "downloaded" == "up to date".
///  • PLATES — approach charts, grouped into the FAA's US regions (`Procedures.regionNames`), fetched on
///    demand from the FAA via `PlateBag` (28-day d-TPP cycle) with a Current / expiring / EXPIRED badge.
struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library = ChartLibrary.shared
    @ObservedObject var bag: PlateBag

    @State private var warming = true
    @State private var plateStatus: [String: PlateRegionStatus] = [:]
    @State private var scanningPlates = false
    @State private var confirmRegion: String?
    @State private var confirmBulkLayer: ChartLayer?
    @State private var confirmRemoveCharts = false
    @State private var confirmRemovePlates = false

    /// Downloaded-vs-total plate count for a region (computed off-main — a region is hundreds of airports).
    struct PlateRegionStatus: Equatable { var total: Int; var downloaded: Int }

    /// The three downloadable raster layers, in display order (Apple base-map layers aren't downloadable).
    private static let rasterLayers: [ChartLayer] = [.sectional, .ifrLow, .ifrHigh]

    var body: some View {
        let p = model.palette
        List {
            chartsSection
            ForEach(Self.rasterLayers, id: \.self) { chartLayerSection($0) }
            platesSection
            storageSection
            Section {
                Toggle(isOn: $model.chartCompatRendering) {
                    Label("Compatibility chart rendering", systemImage: "wrench.adjustable")
                }
                .tint(p.accent)
                .accessibilityIdentifier("chart-compat-toggle")
            } footer: {
                Text("Only turn this on if FAA chart tiles ever render blank. It uses the slower per-tile conversion path, which costs battery.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(p.bg)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .tint(p.accent)
        .task {
            warming = true
            _ = await library.warm()
            library.refreshCachedBytes()
            warming = false
            await refreshPlateStatus()
        }
        .onChange(of: bag.isRunning) { _, running in
            if !running { Task { await refreshPlateStatus() } }   // a plate job finished → refresh region counts
        }
        .confirmationDialog("Download region bundle?",
                            isPresented: Binding(get: { confirmRegion != nil },
                                                 set: { if !$0 { confirmRegion = nil } }),
                            presenting: confirmRegion) { r in
            let n = Procedures.airports(inRegion: r).count
            Button("Download \(r) · \(n) airports") {
                bag.download(airports: Procedures.airports(inRegion: r), label: "\(r) · \(n) airports")
            }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("Downloads every plate for the \(Procedures.airports(inRegion: r).count) airports in \(r). This can use significant data and storage; it runs in the background and can be cancelled.")
        }
        .confirmationDialog("Download over cellular?",
                            isPresented: Binding(get: { confirmBulkLayer != nil },
                                                 set: { if !$0 { confirmBulkLayer = nil } }),
                            presenting: confirmBulkLayer) { layer in
            Button("Download \(layer.title) — \(size(library.remainingBytes([layer])))") {
                library.startBulkDownload(layers: [layer])
            }
            Button("Cancel", role: .cancel) {}
        } message: { layer in
            Text("You're on a cellular connection. Downloading every \(layer.title) region (\(size(library.remainingBytes([layer])))) may use your mobile data.")
        }
        .confirmationDialog("Remove all downloaded charts?", isPresented: $confirmRemoveCharts, titleVisibility: .visible) {
            Button("Remove \(size(library.cachedBytes)) of charts", role: .destructive) {
                library.removeAllCachedCharts()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Deletes every downloaded chart pack, including pinned offline downloads. You'll need a connection to get them back — do this only on the ground.")
        }
        .confirmationDialog("Clear all downloaded plates?", isPresented: $confirmRemovePlates, titleVisibility: .visible) {
            Button("Clear \(bag.cachedCount) plates", role: .destructive) {
                bag.clearCache(); Task { await refreshPlateStatus() }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Deletes every downloaded approach plate. You'll need a connection to get them back — do this only on the ground.")
        }
    }

    // MARK: Charts — header + per-layer sections

    private var chartsSection: some View {
        let p = model.palette
        return Section {
            HStack {
                Text("Cycle \(library.cycle.isEmpty ? "—" : library.cycle)").font(.callout).foregroundStyle(p.text)
                Spacer()
                Text("56-day").font(.caption2).foregroundStyle(p.textDim)
            }
            if case .running(let done, let total) = library.bulk {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).tint(p.accent)
                    HStack {
                        Text("Downloading \(done) of \(total) packs…").font(.caption2).foregroundStyle(p.textDim)
                        Spacer()
                        Button("Cancel") { library.cancelBulkDownload() }
                            .font(.caption2.weight(.semibold)).foregroundStyle(p.bad)
                    }
                }
            }
        } header: { Text("Charts · VFR & IFR tile maps") }
        footer: { Text("The FAA raster charts the moving map draws. A cached pack always matches the current 56-day cycle — old cycles are removed automatically, so a re-download is only needed when a new cycle lands.") }
    }

    private func chartLayerSection(_ layer: ChartLayer) -> some View {
        let entries = layer.entries(library.catalog)
        let cached = entries.filter { library.isCached($0) }.count
        return Section {
            DisclosureGroup {
                if entries.isEmpty {
                    Text(warming ? "Loading chart index…" : "No charts available.")
                        .font(.caption2).foregroundStyle(model.palette.textDim)
                } else {
                    bulkRow(layer, entries: entries, cached: cached)
                    ForEach(entries, id: \.id) { chartRow($0) }
                }
            } label: {
                layerLabel(layer, cached: cached, total: entries.count)
            }
        }
    }

    private func layerLabel(_ layer: ChartLayer, cached: Int, total: Int) -> some View {
        let p = model.palette
        return HStack {
            Text(layer.title).font(.callout.weight(.semibold)).foregroundStyle(p.text)
            Spacer()
            if total > 0 {
                if cached == total {
                    Label("All", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(p.good)
                }
                Text("\(cached)/\(total)").font(.caption2.monospacedDigit()).foregroundStyle(cached == total ? p.good : p.textDim)
            }
        }
    }

    private func bulkRow(_ layer: ChartLayer, entries: [ChartCatalog.Entry], cached: Int) -> some View {
        let p = model.palette
        let remaining = library.remainingBytes([layer])
        let allDone = cached == entries.count
        return Button {
            Haptics.impact(.light)
            Task {
                if await library.isExpensiveConnection() { confirmBulkLayer = layer }
                else { library.startBulkDownload(layers: [layer]) }
            }
        } label: {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(allDone ? p.textDim : p.accent)
                Text(allDone ? "All regions downloaded" : "Download all — \(size(remaining))")
                    .font(.caption.weight(.semibold)).foregroundStyle(allDone ? p.textDim : p.accent)
                Spacer()
            }
        }
        .buttonStyle(.plainHaptic)
        .disabled(allDone || library.bulk.isRunning)
        .accessibilityIdentifier("downloads-\(layer.rawValue)-all")
    }

    private func chartRow(_ e: ChartCatalog.Entry) -> some View {
        let p = model.palette
        let cached = library.isCached(e)
        let downloading = library.downloadingIDs.contains(e.id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.regionLabel(e)).font(.callout).foregroundStyle(p.text)
                Text(size(e.bytes)).font(.caption2).foregroundStyle(p.textDim)
            }
            Spacer()
            if downloading {
                ProgressView().controlSize(.small)
            } else if cached {
                Menu {
                    Button(role: .destructive) { library.remove(e) } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(p.good)
                }
            } else {
                Button { Task { await library.download(e) } } label: {
                    Image(systemName: "arrow.down.circle").font(.body).foregroundStyle(p.accent)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("downloads-chart-\(e.id)")
            }
        }
    }

    // MARK: Plates — by US region

    private var platesSection: some View {
        let p = model.palette
        return Section {
            HStack {
                Text("Cycle \(Procedures.cycle.isEmpty ? "—" : Procedures.cycle)").font(.callout).foregroundStyle(p.text)
                Spacer()
                plateCycleBadge
            }
            if bag.isRunning { plateProgressRow }
            ForEach(Procedures.regionNames, id: \.self) { plateRegionRow($0) }
        } header: { Text("Plates · approach charts (28-day cycle)") }
        footer: { Text("Approach plates download from the FAA on demand. A region covers hundreds of airports — a large download, best done on Wi-Fi.") }
    }

    private var plateCycleBadge: some View {
        let p = model.palette
        let (text, color): (String, Color) = {
            if Procedures.isExpired() { return ("EXPIRED", p.bad) }
            if let d = Procedures.daysUntilExpiry(), d <= 7 { return ("\(max(d, 0))d left", p.warn) }
            return ("Current", p.good)
        }()
        return Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color))
    }

    private var plateProgressRow: some View {
        let p = model.palette
        return VStack(alignment: .leading, spacing: 6) {
            Text(bag.job.label).font(.caption).foregroundStyle(p.text).lineLimit(1)
            HStack(spacing: 8) {
                ProgressView(value: Double(bag.job.done), total: Double(max(bag.job.total, 1))).tint(p.accent)
                Text("\(bag.job.done)/\(bag.job.total)").font(.caption2.monospacedDigit()).foregroundStyle(p.textDim)
            }
            Button("Cancel", role: .destructive) { bag.cancel() }.font(.caption2)
        }
    }

    private func plateRegionRow(_ r: String) -> some View {
        let p = model.palette
        let airports = Procedures.airports(inRegion: r).count
        let st = plateStatus[r]
        let complete = (st?.total ?? 0) > 0 && st?.downloaded == st?.total
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r).font(.callout).foregroundStyle(p.text)
                if let st, st.total > 0 {
                    Text("\(st.downloaded) of \(st.total) plates")
                        .font(.caption2).foregroundStyle(complete ? p.good : p.textDim)
                } else {
                    Text("\(airports) airports\(scanningPlates ? " · scanning…" : "")")
                        .font(.caption2).foregroundStyle(p.textDim)
                }
            }
            Spacer()
            if complete {
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(p.good)
            } else {
                Button { confirmRegion = r } label: {
                    Image(systemName: "arrow.down.circle").font(.body).foregroundStyle(p.accent)
                }
                .buttonStyle(.plainHaptic).disabled(bag.isRunning)
                .accessibilityIdentifier("downloads-plates-\(r)")
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        let p = model.palette
        return Section("Storage") {
            HStack {
                Text("Charts on device").foregroundStyle(p.text)
                Spacer()
                Text(size(library.cachedBytes)).font(.caption.monospaced()).foregroundStyle(p.textDim)
            }
            HStack {
                Text("Plates on device").foregroundStyle(p.text)
                Spacer()
                Text("\(bag.cachedCount) · \(byteStr(bag.cachedBytes))").font(.caption.monospaced()).foregroundStyle(p.textDim)
            }
            // Destructive wipes require a confirm (matching the DOWNLOAD actions above) — one cockpit
            // fat-finger otherwise destroys a multi-GB offline kit that can't be re-downloaded in flight.
            if library.cachedBytes > 0 {
                Button("Remove downloaded charts", role: .destructive) {
                    Haptics.impact(.light); confirmRemoveCharts = true
                }.disabled(library.bulk.isRunning)
            }
            if bag.cachedCount > 0 {
                Button("Clear downloaded plates", role: .destructive) {
                    Haptics.impact(.light); confirmRemovePlates = true
                }.disabled(bag.isRunning)
            }
        }
    }

    // MARK: helpers

    /// Per-region downloaded/total plate counts, computed OFF the main actor (a region scan is thousands
    /// of `fileExists` calls) so the list never janks. Refreshed on appear and after every plate job.
    private func refreshPlateStatus() async {
        guard !Procedures.regionNames.isEmpty else { return }
        scanningPlates = true
        let statuses = await Self.computePlateStatus()
        plateStatus = statuses
        scanningPlates = false
    }

    nonisolated private static func computePlateStatus() async -> [String: PlateRegionStatus] {
        var out: [String: PlateRegionStatus] = [:]
        for r in Procedures.regionNames.prefix(64) {
            assert(out.count < 64, "computePlateStatus: region bound")
            var total = 0, downloaded = 0
            for icao in Procedures.airports(inRegion: r).prefix(20_000) {
                for pl in Procedures.forAirport(icao) {
                    total += 1
                    if PlateStore.isCached(pl) { downloaded += 1 }
                }
            }
            out[r] = PlateRegionStatus(total: total, downloaded: downloaded)
        }
        return out
    }

    /// A pack id → human region label: "New_York_SEC" → "New York"; "ENR_L01" → "L01"; "ENR_H03" → "H03".
    static func regionLabel(_ e: ChartCatalog.Entry) -> String {
        var s = e.id
        if s.hasSuffix("_SEC") { s = String(s.dropLast(4)) }
        if s.hasPrefix("ENR_") { s = String(s.dropFirst(4)) }
        return s.replacingOccurrences(of: "_", with: " ")
    }

    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    private func byteStr(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
