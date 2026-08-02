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
    @State private var checkingForCycle = false
    @State private var cycleCheck: ChartLibrary.CycleCheck?
    @State private var cycleUpdateDeclined = false
    @EnvironmentObject var model: AppModel
    @ObservedObject var library = ChartLibrary.shared
    @ObservedObject var lzLibrary = LZPackLibrary.shared
    @ObservedObject var bag: PlateBag

    @State private var warming = true
    @State private var plateStatus: [String: PlateRegionStatus] = [:]
    @State private var scanningPlates = false
    @State private var confirmRegion: String?
    @State private var confirmBulkLayer: ChartLayer?
    @State private var confirmRemoveCharts = false
    @State private var confirmRemovePlates = false
    @State private var confirmLZRegion: LZPackCatalog.Region?

    /// Downloaded-vs-total plate count for a region (computed off-main — a region is hundreds of airports).
    struct PlateRegionStatus: Equatable { var total: Int; var downloaded: Int }

    /// The three downloadable raster layers, in display order (Apple base-map layers aren't downloadable).
    private static let rasterLayers: [ChartLayer] = [.sectional, .ifrLow, .ifrHigh]

    var body: some View {
        let p = model.palette
        List {
            chartsSection
            ForEach(Self.rasterLayers, id: \.self) { chartLayerSection($0) }
            landabilitySection
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
            await lzLibrary.warm()
            lzLibrary.refreshInstalled()
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
        .confirmationDialog("Download over cellular?",
                            isPresented: Binding(get: { confirmLZRegion != nil },
                                                 set: { if !$0 { confirmLZRegion = nil } }),
                            presenting: confirmLZRegion) { region in
            let cells = lzLibrary.catalog?.cells(in: region) ?? []
            Button("Download \(region.title) — \(size(lzLibrary.remainingBytes(cells)))") {
                for c in cells where !lzLibrary.isInstalled(c.id) { lzLibrary.download(c) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { region in
            let cells = lzLibrary.catalog?.cells(in: region) ?? []
            Text("You're on a cellular connection. \(region.title) is \(size(lzLibrary.remainingBytes(cells))) across \(cells.count) pack(s) and may use your mobile data.")
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

    /// When the expired catalog's cycle ended, for the banner copy.
    private var expiryText: String {
        guard let e = library.chartProvenance.expires else { return "recently" }
        return DataProvenance.iso(e)
    }

    private var chartsSection: some View {
        let p = model.palette
        return Section {
            HStack {
                Text("Cycle \(library.cycle.isEmpty ? "—" : library.cycle)").font(.callout).foregroundStyle(p.text)
                DataCurrencyBadge(sources: [library.chartProvenance], compact: false).environmentObject(model)
                Spacer()
                Text("56-day").font(.dsLabelS).foregroundStyle(p.textDim)
            }
            // An EXPIRED chart catalog is the one case a pilot must not have to go looking for: the map
            // keeps drawing, and out-of-cycle charts look exactly as authoritative as current ones.
            if library.chartProvenance.currency().isExpired {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.bad)
                        Text("These charts have expired").font(.callout.weight(.semibold)).foregroundStyle(p.text)
                    }
                    Text("Cycle \(library.cycle) ended \(expiryText). Charts drawn from this one may not match current procedures.")
                        .font(.caption2).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Haptics.impact(.medium)
                        checkingForCycle = true
                        Task {
                            let installed = library.installedPackIDs()
                            let result = await library.checkForNewCycle()
                            checkingForCycle = false
                            cycleCheck = result
                            // A newer cycle changes which files the reader opens, so the packs the pilot
                            // already had must be re-fetched or they are left with LESS coverage than
                            // before they tapped. Do it as part of the update, not as a second chore.
                            if case .newCycle = result {
                                cycleUpdateDeclined = !(await library.updateInstalledPacks(installed))
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if checkingForCycle { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise").font(.caption2) }
                            Text(checkingForCycle ? "Checking…" : "Check for a new cycle")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(p.accent.opacity(0.18)))
                        .foregroundStyle(p.accent)
                    }
                    .buttonStyle(.plainHaptic).disabled(checkingForCycle)
                    .accessibilityIdentifier("charts-check-cycle")
                    if let outcome = cycleCheck {
                        // Saying nothing was the actual defect the pilot hit: the button appeared to do
                        // nothing, whether it had found a new cycle, confirmed the current one, or failed.
                        switch outcome {
                        case _ where cycleUpdateDeclined:
                            Label("A new cycle is available, but downloading it over a metered connection "
                                  + "was skipped. Reconnect to Wi-Fi and check again.",
                                  systemImage: "antenna.radiowaves.left.and.right.slash")
                                .font(.caption2).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        case .upToDate(let c):
                            // Must not contradict the banner above it, which says a newer cycle exists.
                            // That line is an INFERENCE from the 56-day calendar; this one is what the
                            // server actually offers. When they disagree the server is the fact, and the
                            // pilot needs the operational conclusion, not the discrepancy.
                            Label("The chart server still offers only cycle \(c), which is past its date. "
                                  + "A newer cycle is published but has not been posted here yet — use a "
                                  + "current source for anything you rely on.",
                                  systemImage: "exclamationmark.circle")
                                .font(.caption2).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        case .newCycle(let from, let to, let packs):
                            Label(packs > 0
                                  ? "Cycle \(to) found — replacing \(packs) downloaded \(packs == 1 ? "chart" : "charts") (was \(from))."
                                  : "Updated to cycle \(to) (was \(from)).",
                                  systemImage: "checkmark.circle")
                                .font(.caption2).foregroundStyle(p.good)
                                .fixedSize(horizontal: false, vertical: true)
                        case .offline:
                            Label("Couldn't reach the chart server. Try again when you have a connection.",
                                  systemImage: "wifi.slash")
                                .font(.caption2).foregroundStyle(p.bad)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if case .running(let done, let total) = library.bulk {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).tint(p.accent)
                    HStack {
                        Text("Downloading \(done) of \(total) packs…").font(.dsLabelS).foregroundStyle(p.textDim)
                        Spacer()
                        Button("Cancel") { library.cancelBulkDownload() }
                            .font(.dsLabelSBold).foregroundStyle(p.bad)
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
                        .font(.dsLabelS).foregroundStyle(model.palette.textDim)
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
            Text(layer.title).font(.dsHeadline).foregroundStyle(p.text)
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
                    .font(.dsLabelBold).foregroundStyle(allDone ? p.textDim : p.accent)
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
                Text(size(e.bytes)).font(.dsLabelS).foregroundStyle(p.textDim)
            }
            Spacer()
            if downloading {
                ProgressView().controlSize(.small)
            } else if cached {
                Menu {
                    Button(role: .destructive) { library.remove(e) } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .font(.dsLabelSBold).foregroundStyle(p.good)
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
        return Text(text).font(.dsLabelSBold).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color))
    }

    private var plateProgressRow: some View {
        let p = model.palette
        return VStack(alignment: .leading, spacing: 6) {
            Text(bag.job.label).font(.dsLabel).foregroundStyle(p.text).lineLimit(1)
            HStack(spacing: 8) {
                ProgressView(value: Double(bag.job.done), total: Double(max(bag.job.total, 1))).tint(p.accent)
                Text("\(bag.job.done)/\(bag.job.total)").font(.caption2.monospacedDigit()).foregroundStyle(p.textDim)
            }
            Button("Cancel", role: .destructive) { bag.cancel() }.font(.dsLabelS)
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
                        .font(.dsLabelS).foregroundStyle(complete ? p.good : p.textDim)
                } else {
                    Text("\(airports) airports\(scanningPlates ? " · scanning…" : "")")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                }
            }
            Spacer()
            if complete {
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .font(.dsLabelSBold).foregroundStyle(p.good)
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

    // MARK: Off-field landability — by region, one pack per 1x1 degree cell

    /// The landability packs. Structurally the same as `chartLayerSection`, with one real
    /// difference: these rows show BYTE progress. A chart pack is a few megabytes and an
    /// indeterminate spinner is honest for it; a cell is ~88 MB, and a spinner that sits there for
    /// two minutes over a cockpit LTE link is indistinguishable from a stall.
    @ViewBuilder private var landabilitySection: some View {
        let p = model.palette
        if let catalog = lzLibrary.catalog, !catalog.regions.isEmpty {
            ForEach(catalog.regions) { region in
                let cells = catalog.cells(in: region)
                if !cells.isEmpty {
                    let have = cells.filter { lzLibrary.isInstalled($0.id) }.count
                    Section {
                        DisclosureGroup {
                            lzBulkRow(region, cells: cells, have: have)
                            ForEach(cells) { lzRow($0) }
                        } label: {
                            HStack {
                                Label("Off-field landability", systemImage: "square.grid.3x3.square")
                                    .font(.callout).foregroundStyle(p.text)
                                Spacer()
                                Text("\(have)/\(cells.count)")
                                    .font(.dsLabelS).foregroundStyle(p.textDim)
                                if have == cells.count {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.dsLabelS).foregroundStyle(p.good)
                                }
                            }
                        }
                        .accessibilityIdentifier("downloads-lz-\(region.id)")
                    } header: {
                        Text(region.title)
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let note = region.note { Text(note) }
                            // The advisory framing travels with the DOWNLOAD, not only with the map.
                            // This is the screen where a pilot decides to spend 88 MB on it, which
                            // is exactly where the limits belong.
                            Text("Advisory only — scored candidate ground, never a landing "
                                 + "recommendation. Surface condition, fences, livestock and current "
                                 + "obstructions are not modelled.")
                            if cells.count < region.cells.count {
                                Text("\(region.cells.count - cells.count) more cell(s) in this region "
                                     + "are still being built.")
                            }
                            // Counted when the plan was filed. An offer, sitting where the pilot is
                            // already deciding what to put on the aeroplane before a flight.
                            if model.lzRouteCoverageGap > 0 {
                                Text("Your filed route crosses \(model.lzRouteCoverageGap) cell(s) "
                                     + "you have not downloaded.")
                                    .foregroundStyle(p.accent)
                                    .accessibilityIdentifier("downloads-lz-route-gap")
                            }
                        }
                        .accessibilityIdentifier("downloads-lz-note")
                    }
                }
            }
        } else if lzLibrary.warming {
            Section("Off-field landability") {
                HStack { ProgressView().controlSize(.small); Text("Loading coverage…") }
            }
        } else if let problem = lzLibrary.catalogProblem {
            Section("Off-field landability") {
                Text(problem).font(.dsLabelS).foregroundStyle(p.textDim)
                    .accessibilityIdentifier("downloads-lz-problem")
            }
        }
    }

    private func lzBulkRow(_ region: LZPackCatalog.Region,
                           cells: [LZPackCatalog.Cell], have: Int) -> some View {
        let p = model.palette
        let remaining = lzLibrary.remainingBytes(cells)
        let allDone = have == cells.count
        return Button {
            Haptics.impact(.light)
            Task {
                // Gated on the SAME metered check the background chart paths trust. A region is
                // several hundred megabytes; asking first is not a formality.
                if await NetPath.isExpensive() { confirmLZRegion = region }
                else { for c in cells where !lzLibrary.isInstalled(c.id) { lzLibrary.download(c) } }
            }
        } label: {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(allDone ? p.textDim : p.accent)
                Text(allDone ? "Whole region downloaded" : "Download region — \(size(remaining))")
                    .font(.dsLabelBold).foregroundStyle(allDone ? p.textDim : p.accent)
                Spacer()
            }
        }
        .buttonStyle(.plainHaptic)
        .disabled(allDone || lzLibrary.isDownloading)
        .accessibilityIdentifier("downloads-lz-\(region.id)-all")
    }

    private func lzRow(_ cell: LZPackCatalog.Cell) -> some View {
        let p = model.palette
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.id).font(.callout.monospaced()).foregroundStyle(p.text)
                HStack(spacing: 6) {
                    Text(size(cell.bytes))
                    // Say where the fine-detail checks could not run BEFORE the bytes are spent.
                    if let coarse = cell.coarseTerrainTiles, coarse > 0 {
                        Text("· \(coarse) tiles on 10 m elevation")
                    }
                }
                .font(.dsLabelS).foregroundStyle(p.textDim)
            }
            Spacer()
            switch lzLibrary.state(cell.id) {
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 64)
                    Text("\(Int(fraction * 100))%")
                        .font(.dsLabelS.monospaced()).foregroundStyle(p.textDim)
                        .frame(width: 34, alignment: .trailing)
                    Button { lzLibrary.cancel(cell.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(p.textDim)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("downloads-lz-cancel-\(cell.id)")
                }
            case .ready:
                Menu {
                    Button(role: .destructive) { lzLibrary.remove(cell) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.dsLabelSBold).foregroundStyle(p.good)
                }
                .accessibilityIdentifier("downloads-lz-installed-\(cell.id)")
            case .failed(let why):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(why).font(.dsLabelS).foregroundStyle(p.bad)
                    Button("Retry") { lzLibrary.download(cell) }
                        .font(.dsLabelSBold).foregroundStyle(p.accent)
                        .buttonStyle(.plainHaptic)
                }
                .accessibilityIdentifier("downloads-lz-failed-\(cell.id)")
            case .notDownloaded:
                Button { lzLibrary.download(cell) } label: {
                    Image(systemName: "arrow.down.circle").font(.body).foregroundStyle(p.accent)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("downloads-lz-\(cell.id)")
            }
        }
    }

    private var storageSection: some View {
        let p = model.palette
        return Section("Storage") {
            HStack {
                Text("Charts on device").foregroundStyle(p.text)
                Spacer()
                Text(size(library.cachedBytes)).font(.caption.monospaced()).foregroundStyle(p.textDim)
            }
            // Landability packs are pin-only — nothing evicts them but the pilot, so this number is
            // the whole story and needs to be obvious rather than derived from a cache policy.
            if lzLibrary.installedBytes > 0 {
                HStack {
                    Text("Landability packs").foregroundStyle(p.text)
                    Spacer()
                    Text("\(lzLibrary.installedIDs.count) · \(byteStr(lzLibrary.installedBytes))")
                        .font(.caption.monospaced()).foregroundStyle(p.textDim)
                        .accessibilityIdentifier("storage-lz-bytes")
                }
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
