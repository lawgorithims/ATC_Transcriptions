import SwiftUI

/// The Flight Bag: manage downloaded plates. Shows the chart-cycle validity (with an expiry badge),
/// downloads the filed route's plates ("pack the bag"), the current airport's plates, or a whole
/// region bundle, and reports/clears the on-disk cache. All downloads run in the background via
/// `PlateBag` with a cancellable progress bar.
struct FlightBagView: View {
    @EnvironmentObject var model: AppModel
    var currentAirport: String?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRegion: String?

    private var bag: PlateBag { model.plateBag }

    var body: some View {
        NavigationStack {
            List {
                cycleSection
                if bag.isRunning { progressSection }
                routeSection
                if let apt = currentAirport, !Procedures.forAirport(apt).isEmpty { airportSection(apt) }
                regionSection
                cacheSection
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Flight Bag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { bag.refreshCacheStats() }
        }
        .tint(model.palette.accent)
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
            Text("Downloads every plate for \(Procedures.airports(inRegion: r).count) airports in \(r). This can use significant data and storage; it runs in the background and can be cancelled.")
        }
    }

    // MARK: cycle

    private var cycleSection: some View {
        let p = model.palette
        return Section("Chart cycle") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cycle \(Procedures.cycle.isEmpty ? "—" : Procedures.cycle)")
                        .font(.callout).foregroundStyle(p.text)
                    if let eff = Procedures.effectiveDate, let exp = Procedures.expiryDate {
                        Text("\(Self.df.string(from: eff)) – \(Self.df.string(from: exp))")
                            .font(.caption2).foregroundStyle(p.textDim)
                    }
                }
                Spacer()
                cycleBadge
            }
        }
    }

    private var cycleBadge: some View {
        let p = model.palette
        let (text, color): (String, Color) = {
            if Procedures.isExpired() { return ("EXPIRED", .red) }
            if let d = Procedures.daysUntilExpiry(), d <= 7 { return ("\(max(d, 0))d left", .orange) }
            return ("Current", p.good)
        }()
        return Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(color))
    }

    // MARK: progress

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(bag.job.label).font(.caption).foregroundStyle(model.palette.text).lineLimit(1)
                HStack(spacing: 8) {
                    ProgressView(value: Double(bag.job.done), total: Double(max(bag.job.total, 1)))
                    Text("\(bag.job.done)/\(bag.job.total)").font(.caption2).monospacedDigit()
                        .foregroundStyle(model.palette.textDim)
                }
                Button("Cancel", role: .destructive) { bag.cancel() }.font(.caption)
            }
        }
    }

    // MARK: route

    private var routeSection: some View {
        let airports = PlateBag.routeAirports(model.flightPlan)
        return Section("Your route") {
            Toggle("Auto-pack when I file a flight plan", isOn: $model.autoPackFlightBag)
            if airports.isEmpty {
                Text("File a flight plan and its airports' plates download automatically.")
                    .font(.caption).foregroundStyle(model.palette.textDim)
            } else {
                Button {
                    bag.download(airports: airports, label: "Route · \(airports.count) airports")
                } label: {
                    Label("Pack \(airports.joined(separator: ", ")) · \(totalPlates(airports)) charts", systemImage: "arrow.down.circle")
                }
                .disabled(bag.isRunning)
            }
        }
    }

    // MARK: this airport

    private func airportSection(_ apt: String) -> some View {
        let plates = Procedures.forAirport(apt)
        let cached = plates.filter { PlateStore.isCached($0) }.count
        return Section("This airport · \(apt)") {
            Button {
                bag.download(airports: [apt], label: "\(apt) · \(plates.count) charts")
            } label: {
                Label("Download all \(plates.count) charts", systemImage: "arrow.down.circle")
            }
            .disabled(bag.isRunning || cached == plates.count)
            if cached == plates.count { Text("All \(plates.count) charts downloaded.").font(.caption2).foregroundStyle(model.palette.good) }
            else { Text("\(cached) of \(plates.count) downloaded.").font(.caption2).foregroundStyle(model.palette.textDim) }
        }
    }

    // MARK: regions

    private var regionSection: some View {
        Section {
            ForEach(Procedures.regionNames, id: \.self) { r in
                Button { confirmRegion = r } label: {
                    HStack {
                        Text(r).foregroundStyle(model.palette.text)
                        Spacer()
                        Text("\(Procedures.airports(inRegion: r).count) airports")
                            .font(.caption2).foregroundStyle(model.palette.textDim)
                        Image(systemName: "arrow.down.circle").font(.caption).foregroundStyle(model.palette.accent)
                    }
                }
                .buttonStyle(.plain).disabled(bag.isRunning)
            }
        } header: { Text("Region bundles") } footer: {
            Text("Region bundles cover hundreds of airports — large downloads, best done on Wi-Fi.")
        }
    }

    // MARK: cache

    private var cacheSection: some View {
        Section("Storage") {
            HStack {
                Text("Downloaded plates").foregroundStyle(model.palette.text)
                Spacer()
                Text("\(bag.cachedCount) · \(Self.byteStr(bag.cachedBytes))").foregroundStyle(model.palette.textDim)
            }
            Button("Clear all downloaded plates", role: .destructive) { bag.clearCache() }
                .disabled(bag.isRunning || bag.cachedCount == 0)
        }
    }

    // MARK: helpers

    private func totalPlates(_ airports: [String]) -> Int {
        airports.reduce(0) { $0 + Procedures.forAirport($1).count }
    }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")   // cycle dates are UTC — show them as-is, not shifted local
        return f
    }()
    private static func byteStr(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
