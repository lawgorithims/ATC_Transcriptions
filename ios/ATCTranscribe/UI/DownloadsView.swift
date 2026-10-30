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
    @State private var staleUpdateDeclined = false
    @EnvironmentObject var model: AppModel
    @ObservedObject var library = ChartLibrary.shared
    @ObservedObject var lzLibrary = LZPackLibrary.shared
    @ObservedObject var navLibrary = NavDataLibrary.shared
    @ObservedObject var avoidLibrary = AvoidMapLibrary.shared
    @ObservedObject var policy = DownloadPolicy.shared
    @ObservedObject var bag: PlateBag

    @State private var warming = true
    @State private var plateStatus: [String: PlateRegionStatus] = [:]
    @State private var scanningPlates = false
    @State private var confirmRegion: String?
    @State private var confirmBulkLayer: ChartLayer?
    @State private var confirmRemoveCharts = false
    @State private var confirmRemovePlates = false
    @State private var confirmLZRegion: LZPackCatalog.Region?
    /// A download the Wi-Fi-only setting is holding back, and the pilot may release anyway.
    @State private var meteredPack: ChartCatalog.Entry?
    @State private var meteredReason: String = ""
    @State private var confirmDropStaged = false
    @State private var meteredLZCell: LZPackCatalog.Cell?
    @State private var meteredLZReason: String = ""

    /// Downloaded-vs-total plate count for a region (computed off-main — a region is hundreds of airports).
    struct PlateRegionStatus: Equatable { var total: Int; var downloaded: Int }

    /// The three downloadable raster layers, in display order (Apple base-map layers aren't downloadable).
    private static let rasterLayers: [ChartLayer] = [.sectional, .ifrLow, .ifrHigh]

    var body: some View {
        let p = model.palette
        List {
            chartsSection
            downloadSettingsSection
            ForEach(Self.rasterLayers, id: \.self) { chartLayerSection($0) }
            avoidSection
            landabilitySection
            platesSection
            navDataSection
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
            await navLibrary.refresh()
            warming = false
            await refreshPlateStatus()
            // Opening this screen is the pilot asking about their offline kit, which makes it the
            // right moment to top up the next cycle — and the only moment they will see it happen.
            await library.precacheNextCycle()
            await navLibrary.precacheNext()
        }
        .modifier(NextCycleDialogs(library: library,
                                   lzLibrary: lzLibrary,
                                   meteredPack: $meteredPack,
                                   meteredReason: meteredReason,
                                   meteredLZCell: $meteredLZCell,
                                   meteredLZReason: meteredLZReason,
                                   confirmDropStaged: $confirmDropStaged,
                                   size: size))
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
                library.startBulkDownload(layers: [layer], allowMetered: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { layer in
            Text("You're not on Wi-Fi. Downloading every \(layer.title) region "
                 + "(\(size(library.remainingBytes([layer])))) may use your mobile data. "
                 + "This override applies to this download only.")
        }
        .confirmationDialog("Download over cellular?",
                            isPresented: Binding(get: { confirmLZRegion != nil },
                                                 set: { if !$0 { confirmLZRegion = nil } }),
                            presenting: confirmLZRegion) { region in
            let cells = lzLibrary.catalog?.cells(in: region) ?? []
            Button("Download \(region.title) — \(size(lzLibrary.remainingBytes(cells)))") {
                for c in cells where !lzLibrary.isInstalled(c.id) {
                    lzLibrary.download(c, allowMetered: true)
                }
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
            // ⚠️ NOT GATED ON isExpired, AND THAT IS THE POINT. On a cycle roll the newly adopted
            // catalog is perfectly CURRENT, so every expiry-gated control below hides itself — at
            // exactly the moment the pilot's downloaded packs have gone stale and need re-fetching.
            // This row is the only thing that surfaces that state, so it keys off what is actually on
            // disk (ChartLibrary.stalePackCount) rather than off the catalog's dates.
            //
            // The map is still drawing these packs rather than blanking (ChartLibrary.readableURL), so
            // the wording says "older cycle", not "missing" — the pilot has charts, just not this
            // cycle's.
            if library.stalePackCount > 0 {
                let n = library.stalePackCount
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(p.warn)
                        Text("\(n) pack\(n == 1 ? "" : "s") from an older cycle")
                            .font(.callout.weight(.semibold)).foregroundStyle(p.text)
                    }
                    Text("The map is drawing these from your last download so you are not left without a "
                         + "chart. They do not match cycle \(library.cycle) — re-download when you have "
                         + "a connection you are happy to use.")
                        .font(.caption2).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Haptics.impact(.medium)
                        Task {
                            // `updateInstalledPacks` carries the metered-connection guard every bulk
                            // path in this screen uses; a multi-gigabyte re-download over a cockpit
                            // hotspot is exactly what it exists to refuse. It returns false when it
                            // declined, which is reported below rather than failing silently.
                            staleUpdateDeclined = !(await library.updateInstalledPacks(
                                library.installedPackIDs()))
                        }
                    } label: {
                        Text("Re-download \(n) pack\(n == 1 ? "" : "s")")
                            .font(.dsLabelBold).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(p.accent))
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("charts-redownload-stale")
                    if staleUpdateDeclined {
                        Label("Skipped — you are on a metered connection. Reconnect to Wi-Fi and tap "
                              + "again. Your older-cycle charts stay on the map until then.",
                              systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption2).foregroundStyle(p.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
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
                // The policy, not a bare cellular test: with Wi-Fi-only on, a metered path is a
                // refusal the pilot has already asked for, and the dialog is how they release it.
                if (await DownloadPolicy.shared.verdict(.userInitiated)).isAllowed {
                    library.startBulkDownload(layers: [layer])
                } else {
                    confirmBulkLayer = layer
                }
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
                Button {
                    Task {
                        // Ask the policy BEFORE starting, so a refusal becomes an explained dialog with
                        // an override instead of a button that does nothing. `download` enforces it
                        // again as a backstop.
                        let verdict = await DownloadPolicy.shared.verdict(.userInitiated)
                        if verdict.isAllowed {
                            await library.download(e)
                        } else {
                            meteredReason = verdict.explanation ?? ""
                            meteredPack = e
                        }
                    }
                } label: {
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
    /// Procedures and airports — the two datasets that could previously only be refreshed by an App
    /// Store release.
    ///
    /// They are the reason the currency banner said "3 datasets have expired" with nowhere to go:
    /// `NavDataUpdate` could verify and install a new cycle, and `CIFP`/`AirportData` already read
    /// through it, but nothing could ever DELIVER one — no manifest, no URL, no downloader, and no row
    /// here. Measured 2026-10-19, both were three cycles behind while the FAA had published three
    /// newer ones.
    ///
    /// Shown even when there is nothing to download, unlike the chart rows. What is current is a fact
    /// a pilot checks BEFORE a flight, and a section that appears only when something is wrong cannot
    /// answer "am I current?" — it can only interrupt.
    @ViewBuilder private var navDataSection: some View {
        let p = model.palette
        let updates = navLibrary.available()
        Section {
            ForEach(NavDataUpdate.Dataset.allCases, id: \.rawValue) { d in
                let serving = NavDataUpdate.activeURL(d).map { NavDataUpdate.meta($0) } ?? [:]
                let update = updates.first { $0.dataset == d }?.entry
                // The live update state wins; the pre-load state is what the row says when there is
                // no update to offer, so a staged cycle is visible rather than silent.
                let state = navLibrary.states[d.rawValue] ?? navLibrary.staging[d.rawValue]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(d.displayName,
                              systemImage: d == .cifp ? "point.topleft.down.curvedto.point.bottomright.up"
                                                      : "building.2")
                            .font(.callout).foregroundStyle(p.text)
                        Spacer()
                        navStateView(d, state: state, update: update, p: p)
                    }
                    // Always name the cycle being SERVED, and say plainly whether it came down or
                    // shipped with the app — "up to date" with no provenance is what let three stale
                    // cycles go unnoticed.
                    Text(navCycleLine(d, serving: serving))
                        .font(.caption2).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("downloads-nav-\(d.rawValue)")
            }
        } header: {
            Text("Procedures & airports · 28-day")
        } footer: {
            Text("Coded approaches, departures and arrivals, plus runway geometry and published "
                 + "frequencies. These update over the air — you no longer need an app update to fly "
                 + "a current cycle. A new cycle is only offered once it has taken effect; the FAA "
                 + "publishes them weeks early.")
        }
    }

    @ViewBuilder
    private func navStateView(_ d: NavDataUpdate.Dataset,
                              state: NavDataLibrary.State?,
                              update: NavDataLibrary.Catalog.Entry?,
                              p: Palette) -> some View {
        switch state {
        case .checking, .verifying:
            ProgressView().controlSize(.mini)
        case .downloading:
            ProgressView().controlSize(.mini)
        case .installed(let cycle):
            Label("Cycle \(cycle) — restart to use", systemImage: "checkmark.circle.fill")
                .font(.dsLabelS).foregroundStyle(p.good)
        case .staged(let cycle):
            // NOT "installed", and the wording has to carry that. Nothing is being read from this
            // file: it is downloaded, fully verified, and deliberately not in use until its effective
            // date — a row that claimed otherwise would have a pilot believe they are briefing off a
            // cycle the app is pointedly ignoring.
            Label("Cycle \(cycle) pre-loaded — starts on its effective date",
                  systemImage: "calendar.badge.checkmark")
                .font(.dsLabelS).foregroundStyle(p.good)
        case .failed(let why):
            // A dead end before: the label rendered and nothing ever cleared `states`, so a download
            // that failed once could not be retried without relaunching the app. On a cockpit
            // connection a first attempt failing is ordinary, not terminal.
            HStack(spacing: 6) {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsLabelS).foregroundStyle(p.bad)
                Button {
                    Haptics.impact(.light)
                    navLibrary.retry(d)
                } label: {
                    Text("Retry").font(.dsLabelBold).foregroundStyle(p.accent)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("nav-retry-\(d.rawValue)")
            }
        case .idle, .none:
            if let u = update {
                Button {
                    Haptics.impact(.medium)
                    navLibrary.update(d)
                } label: {
                    Text("Update to \(u.cycle)")
                        .font(.dsLabelBold).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("nav-update-\(d.rawValue)")
            } else if navLibrary.catalog == nil {
                // ⚠️ NOT A TICK. `available()` returns [] both when we are current AND when the
                // manifest could not be fetched (refresh() swallows offline deliberately, because an
                // EFB is offline all the time and that is not an error). Rendering both as a green
                // check told a pilot "your procedures are current" on the strength of a request that
                // never completed — the one claim this section exists to make, made without evidence.
                Label("Could not check", systemImage: "wifi.slash")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.dsLabelS).foregroundStyle(p.good)
            }
        }
    }

    /// "Cycle 2610, expires 29 Oct · downloaded" — or why we cannot say.
    private func navCycleLine(_ d: NavDataUpdate.Dataset, serving: [String: String]) -> String {
        let cycle = serving["cycle"] ?? ""
        guard !cycle.isEmpty else { return "No provenance — this data cannot be dated." }
        let source = NavDataUpdate.isOverridden(d) ? "downloaded" : "built into this app version"
        var line = "Cycle \(cycle)"
        if let exp = serving["expires"], !exp.isEmpty {
            line += ", expires \(exp)"
        }
        return line + " · " + source
    }

    /// Developer-only since build 110 (see `AppModel.showLZRisk`). A pilot who downloaded packs while
    /// the layer was public gets a way to take the storage back instead of a section that vanished
    /// with hundreds of MB still on the device.
    /// The national "where not to go" map: one file, offered, never fetched on its own.
    private var avoidSection: some View {
        let p = model.palette
        return Section("Where not to go — contiguous US") {
            Text("Power lines, towers, wind turbines, solar farms, orchards and steep ground, with trees, "
                 + "water and built-up areas optional. It only ever shows where NOT to put the aeroplane "
                 + "down. Distribution wires, fences, ditches and crops are not mapped anywhere public, so "
                 + "unshaded ground is not safe ground.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            switch avoidLibrary.state {
            case .downloading(let f):
                HStack {
                    ProgressView(value: f).tint(p.accent)
                    Button("Cancel") { avoidLibrary.cancel() }.accessibilityIdentifier("downloads-avoid-cancel")
                }
            case .verifying:
                Label("Checking the download…", systemImage: "checkmark.shield").font(.dsLabelS)
            case .installed:
                if let info = avoidLibrary.store.info {
                    Text("Installed · built \(String(info.builtAt.prefix(10)))")
                        .font(.dsLabelS).foregroundStyle(p.text)
                        .accessibilityIdentifier("downloads-avoid-installed")
                }
                if avoidLibrary.updateAvailable {
                    Button { avoidLibrary.download() } label: { Label("Update", systemImage: "arrow.down.circle") }
                        .accessibilityIdentifier("downloads-avoid-update")
                }
                Button(role: .destructive) { avoidLibrary.remove() } label: {
                    Label("Remove", systemImage: "trash")
                }
                .accessibilityIdentifier("downloads-avoid-remove")
            case .failed(let why):
                Text(why).font(.dsLabelS).foregroundStyle(p.warn).fixedSize(horizontal: false, vertical: true)
                avoidDownloadButtons(p, offerMetered: true)
            case .idle:
                avoidDownloadButtons(p, offerMetered: false)
            }
        }
        .task { await avoidLibrary.refresh() }
    }

    /// The cellular override is offered only after the download policy has held one back: on Wi-Fi it
    /// would be a second button that does the same thing.
    @ViewBuilder private func avoidDownloadButtons(_ p: Palette, offerMetered: Bool) -> some View {
        if let c = avoidLibrary.catalog {
            Button { avoidLibrary.download() } label: {
                Label("Download · \(byteStr(Int64(c.map.bytes)))", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("downloads-avoid-download")
            if offerMetered {
                Button { avoidLibrary.download(allowMetered: true) } label: {
                    Label("Download on cellular anyway", systemImage: "antenna.radiowaves.left.and.right")
                }
                .font(.dsLabelS)
                .accessibilityIdentifier("downloads-avoid-download-metered")
            }
        } else {
            Text("The map list could not be reached. Connect to the internet to download it.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
    }

    @ViewBuilder private var landabilitySection: some View {
        if model.offFieldLayerAvailable {
            landabilityCatalogSection
        } else if lzLibrary.installedBytes > 0 {
            landabilityPausedSection
        }
    }

    private var landabilityPausedSection: some View {
        let p = model.palette
        return Section("Off-field landability") {
            Text("Paused while it is reworked. A ground-truth test found the shading offering solar "
                 + "farms, orchards and ground under power lines as landing candidates, so it is now a "
                 + "developer preview. The packs on this device feed nothing you can see. The glide "
                 + "range bands do not need them.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("downloads-lz-paused")
            Button(role: .destructive) {
                Haptics.impact(.medium)
                lzLibrary.removeAllInstalled()
            } label: {
                Label("Remove \(lzLibrary.installedIDs.count) pack(s) · \(byteStr(lzLibrary.installedBytes))",
                      systemImage: "trash")
            }
            .accessibilityIdentifier("downloads-lz-remove-all")
        }
    }

    @ViewBuilder private var landabilityCatalogSection: some View {
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
                // The pilot's own setting, not a fixed cellular test. `NetPath.isExpensive()` is a
                // weaker, older question: it ignores "Wi-Fi only" entirely and misses a constrained
                // (Low Data Mode) path that is not technically expensive. A region is several
                // hundred megabytes; it should obey the same switch every other download does.
                if (await DownloadPolicy.shared.verdict(.userInitiated)).isAllowed {
                    for c in cells where !lzLibrary.isInstalled(c.id) { lzLibrary.download(c) }
                } else {
                    confirmLZRegion = region
                }
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
                    Button("Retry") { startLZ(cell) }
                        .font(.dsLabelSBold).foregroundStyle(p.accent)
                        .buttonStyle(.plainHaptic)
                }
                .accessibilityIdentifier("downloads-lz-failed-\(cell.id)")
            case .notDownloaded:
                Button { startLZ(cell) } label: {
                    Image(systemName: "arrow.down.circle").font(.body).foregroundStyle(p.accent)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("downloads-lz-\(cell.id)")
            }
        }
    }

    /// The pilot's two standing answers about network use, and what pre-caching is currently doing.
    ///
    /// Deliberately ABOVE the per-layer download sections rather than buried at the bottom: these two
    /// switches govern every button below them, and a pilot who taps "Download IFR-low — 1.2 GB" and
    /// gets "Waiting for Wi-Fi" should have already seen why.
    private var downloadSettingsSection: some View {
        let p = model.palette
        return Section {
            Toggle(isOn: $policy.wifiOnly) {
                Label("Download over Wi-Fi only", systemImage: "wifi")
            }
            .tint(p.accent)
            .accessibilityIdentifier("downloads-wifi-only-toggle")

            Toggle(isOn: $policy.precacheNextCycle) {
                Label("Pre-load the next cycle", systemImage: "calendar.badge.clock")
            }
            .tint(p.accent)
            .accessibilityIdentifier("downloads-precache-toggle")
            .onChange(of: policy.precacheNextCycle) { _, on in
                // Turning it ON acts immediately — a setting that waits for the next launch to do
                // anything reads as broken. Turning it OFF only stops future work; the staged packs
                // are the pilot's to drop, below, because deleting a gigabyte on a toggle flip is
                // not a decision a switch should make silently.
                if on { Task { await library.precacheNextCycle(); await navLibrary.precacheNext() } }
                else { library.cancelPrecache() }
            }

            precacheStatusRow

            if library.stagedBytes > 0 {
                Button("Remove pre-loaded cycle (\(size(library.stagedBytes)))", role: .destructive) {
                    Haptics.impact(.light); confirmDropStaged = true
                }
                .accessibilityIdentifier("downloads-drop-staged")
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text(downloadSettingsFooter)
        }
    }

    private var downloadSettingsFooter: String {
        var out = policy.wifiOnly
            ? "Chart and database downloads wait for Wi-Fi. A personal hotspot counts as cellular, "
              + "because the data comes off your phone's plan. You can still override any single "
              + "download when you need it."
            : "Downloads may use cellular data. Full chart coverage is several gigabytes."
        out += policy.precacheNextCycle
            ? " The FAA publishes each cycle weeks early, so the charts and databases you already have "
              + "are downloaded ahead of time and switch over by themselves on the effective date — "
              + "no download on cycle-change day, in the air or at the field."
            : " Next cycle will be downloaded only after it takes effect, which can mean a large "
              + "download on the day it changes."
        return out
    }

    @ViewBuilder
    private var precacheStatusRow: some View {
        let p = model.palette
        switch library.precache {
        case .running(let done, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Pre-loading next cycle — \(done) of \(total)")
                    .font(.caption).foregroundStyle(p.textDim)
                Spacer()
                Button("Stop") { library.cancelPrecache() }
                    .font(.dsLabelSBold).foregroundStyle(p.accent)
                    .buttonStyle(.plainHaptic)
            }
            .accessibilityIdentifier("precache-running")
        case .ready(let cycle, let packs):
            Label("Cycle \(cycle) ready — \(packs) pack\(packs == 1 ? "" : "s") waiting",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(p.good)
                .accessibilityIdentifier("precache-ready")
        case .partial(let cycle, let have, let want):
            Label("Cycle \(cycle) — \(have) of \(want) pre-loaded, will finish on Wi-Fi",
                  systemImage: "clock.badge.checkmark")
                .font(.caption).foregroundStyle(p.textDim)
                .accessibilityIdentifier("precache-partial")
        case .waiting(let why):
            Label(why, systemImage: "clock")
                .font(.caption).foregroundStyle(p.textDim)
                .accessibilityIdentifier("precache-waiting")
        case .off, .idle:
            // Nothing staged by the publisher is the ordinary state for 4 of every 8 weeks, and a row
            // announcing it would be noise. The staged nav cycles ARE worth naming, because the
            // databases roll on a different (28-day) clock than the charts.
            if !navLibrary.stagedReady().isEmpty {
                let names = navLibrary.stagedReady().map { "\($0.dataset.displayName) \($0.cycle)" }
                Label("Ready for the next cycle: \(names.joined(separator: ", "))",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(p.good)
                    .accessibilityIdentifier("precache-nav-ready")
            }
        }
    }

    /// Start one landability pack, asking the download policy first so a refusal becomes an
    /// explained dialog with an override rather than a button that silently does nothing. This row
    /// was previously ungated altogether — the only one of its size in the app.
    private func startLZ(_ cell: LZPackCatalog.Cell) {
        Task {
            let verdict = await DownloadPolicy.shared.verdict(.userInitiated)
            if verdict.isAllowed {
                lzLibrary.download(cell)
            } else {
                meteredLZReason = verdict.explanation ?? ""
                meteredLZCell = cell
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
            // Pre-caching can roughly DOUBLE an offline kit's footprint for up to 56 days, holding two
            // cycles of the same packs. That is the right trade for a pilot who wants a seamless roll
            // and the wrong one for a 64 GB iPad, so it is named rather than folded into the total.
            if library.stagedBytes > 0, let next = library.stagedCycle {
                HStack {
                    Text("· of that, next cycle (\(next))").foregroundStyle(p.textDim)
                    Spacer()
                    Text(size(library.stagedBytes)).font(.caption.monospaced()).foregroundStyle(p.textDim)
                }
                .accessibilityIdentifier("storage-staged-bytes")
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

/// The two next-cycle dialogs, as a `ViewModifier` rather than two more links in `DownloadsView`'s
/// modifier chain.
///
/// Not a style choice: adding them inline pushed the chain past what the type checker will solve
/// ("unable to type-check this expression in reasonable time" — it fails on the LZ dialog's `Binding`,
/// twelve modifiers earlier, which is what makes this class of error so misleading to read). Each
/// `.confirmationDialog` wraps the whole accumulated generic type, so the cost is super-linear in
/// chain length; a modifier type-checks its own body in isolation.
private struct NextCycleDialogs: ViewModifier {
    @ObservedObject var library: ChartLibrary
    @ObservedObject var lzLibrary: LZPackLibrary
    @Binding var meteredPack: ChartCatalog.Entry?
    var meteredReason: String
    @Binding var meteredLZCell: LZPackCatalog.Cell?
    var meteredLZReason: String
    @Binding var confirmDropStaged: Bool
    let size: (Int) -> String

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Download without Wi-Fi?",
                                isPresented: Binding(get: { meteredPack != nil },
                                                     set: { if !$0 { meteredPack = nil } }),
                                presenting: meteredPack) { e in
                Button("Download \(e.id) — \(size(e.bytes))") {
                    Task { await library.download(e, allowMetered: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { e in
                Text(meteredReason + " " + e.id + " is " + size(e.bytes)
                     + ". Downloading it now may use your mobile data.")
            }
            .confirmationDialog("Download without Wi-Fi?",
                                isPresented: Binding(get: { meteredLZCell != nil },
                                                     set: { if !$0 { meteredLZCell = nil } }),
                                presenting: meteredLZCell) { cell in
                Button("Download " + cell.id + " — " + size(cell.bytes)) {
                    lzLibrary.download(cell, allowMetered: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: { cell in
                Text(meteredLZReason + " " + cell.id + " is " + size(cell.bytes)
                     + ". Downloading it now may use your mobile data.")
            }
            .confirmationDialog("Remove the pre-loaded next cycle?",
                                isPresented: $confirmDropStaged, titleVisibility: .visible) {
                Button("Remove " + size(library.stagedBytes), role: .destructive) {
                    library.removeStagedPacks()
                    for d in NavDataUpdate.Dataset.allCases { NavDataUpdate.removeStaged(d) }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Frees the space now. The next cycle will then have to be downloaded after it "
                     + "takes effect, which may be a large download on the day it changes.")
            }
    }
}
