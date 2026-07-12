import SwiftUI

/// The "Plates" tab: search an airport, browse its FAA approach/departure/arrival charts, open one
/// full-page, or send it to the map as a georeferenced overlay. Defaults to the filed flight plan's
/// destination so the plate you need is one tap away, and FOLLOWS a live flight-plan amendment (e.g.
/// ATC re-clears the destination) unless the pilot has explicitly pinned an airport.
struct PlatesTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var airport: String?             // the airport whose plates are shown
    @State private var plate: AirportProcedure?     // the plate open full-screen
    @State private var userPinned = false           // the pilot chose an airport → stop auto-following the plan
    @State private var searchActive = false         // drives `.searchable` focus so we can dismiss it on tab-leave

    private var defaultAirport: String? {
        // Derived purely from the filed flight plan; the explicit map/QA hand-off is applied separately
        // (consumed via `platesAirport`), so it isn't re-read here.
        guard let fp = model.flightPlan else { return nil }
        let d = fp.destination.trimmingCharacters(in: .whitespaces).uppercased()
        let o = fp.departure.trimmingCharacters(in: .whitespaces).uppercased()
        if !d.isEmpty, !Procedures.forAirport(d).isEmpty { return d }
        if !o.isEmpty, !Procedures.forAirport(o).isEmpty { return o }
        return nil
    }

    var body: some View {
        // The tab is always in the hierarchy (opacity switch, not teardown), so cost NOTHING while the
        // Map tab is up — otherwise `plateList` would hit the filesystem per row on every transcript
        // publish during a live session (F3). @State survives the switch; the cover only opens here.
        Group {
            if model.selectedTab == .plates {
                content
            } else {
                Color.clear
            }
        }
        .onChange(of: model.selectedTab) { _, tab in
            if tab != .plates { searchActive = false }   // drop keyboard focus when leaving (hardware-kbd EFB)
        }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if !query.isEmpty {
                    airportPicker
                } else if let apt = airport {
                    plateList(apt)
                } else {
                    emptyState
                }
            }
            .navigationTitle(query.isEmpty ? (airport ?? "Plates") : "Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searchActive,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Airport — KBOS, or “Logan”")
            .toolbar {
                if airport != nil, query.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change") { airport = nil; userPinned = true }
                            .accessibilityIdentifier("plate-change-airport")
                    }
                }
            }
        }
        .tint(model.palette.accent)
        .fullScreenCover(item: $plate) { proc in
            PlateViewer(procedure: proc, airport: airport ?? "", palette: model.palette,
                        onSendToMap: { url in
                            model.overlayPlate(proc, airport: airport ?? "", pdf: url)
                            model.selectedTab = .map          // jump to the map so the overlay is visible
                            plate = nil
                        },
                        onClose: { plate = nil })
        }
        .onAppear { applyPendingOrDefault() }
        .onChange(of: model.platesAirport) { _, _ in applyPendingOrDefault() }
        .onChange(of: model.flightPlan) { _, _ in
            // Follow a live plan amendment (the app's core flow) unless the pilot pinned an airport.
            if !userPinned { airport = defaultAirport }
        }
    }

    /// Consume a pending map/QA hand-off (`platesAirport`) if present; otherwise seed the default
    /// airport once. Clears `platesAirport` so a repeat hand-off to the same airport re-fires.
    private func applyPendingOrDefault() {
        if let want = model.platesAirport, !Procedures.forAirport(want).isEmpty {
            airport = want; userPinned = true; query = ""
            model.platesAirport = nil        // one-shot consumed
        } else if airport == nil {
            airport = defaultAirport
        }
    }

    // MARK: airport search

    private var airportPicker: some View {
        // Filter to airports that actually publish plates, THEN cap — capping the raw ranked list first
        // (navaids/fixes included) could push a genuine match past the limit (F5).
        let hits = MapSearch.results(query, limit: 200)
            .filter { $0.kind == .airport && !Procedures.forAirport($0.ident).isEmpty }
            .prefix(40)
        return List {
            if hits.isEmpty {
                Text("No airports with charts match “\(query)”.").foregroundStyle(model.palette.textDim)
            } else {
                ForEach(Array(hits)) { o in
                    Button {
                        airport = o.ident; userPinned = true; query = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "airplane.circle.fill").foregroundStyle(model.palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.ident).font(.system(.body, design: .monospaced)).foregroundStyle(model.palette.text)
                                if let n = NavMeta.airport(o.ident)?.name {
                                    Text(n).font(.caption).foregroundStyle(model.palette.textDim)
                                }
                            }
                            Spacer()
                            Text("\(Procedures.forAirport(o.ident).count) charts").font(.caption2).foregroundStyle(model.palette.textDim)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: plate list for an airport

    private func plateList(_ ident: String) -> some View {
        let p = model.palette
        let plates = Procedures.forAirport(ident)
        let groups: [(AirportProcedure.Category, String)] = [
            (.approach, "Approaches"), (.departure, "Departures (DPs)"),
            (.arrival, "Arrivals (STARs)"), (.diagram, "Airport diagram"),
        ]
        return List {
            if let name = NavMeta.airport(ident)?.name {
                Section { Text(name).font(.subheadline).foregroundStyle(p.textDim) }
            }
            ForEach(groups, id: \.0) { cat, heading in
                let items = plates.filter { $0.category == cat }
                if !items.isEmpty {
                    Section("\(heading) (\(items.count))") {
                        ForEach(items) { proc in
                            Button { Haptics.impact(.light); plate = proc } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.richtext").font(.caption).foregroundStyle(p.accent)
                                    Text(proc.name).font(.callout).foregroundStyle(p.text).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if PlateGeoref.lookup(pdf: proc.pdf) != nil {
                                        Image(systemName: "scope").font(.caption2).foregroundStyle(p.good)   // auto-aligns on the map
                                    }
                                    if PlateStore.isCached(proc) {
                                        Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(p.good)
                                    }
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                                }
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("plate-row")
                        }
                    }
                }
            }
            if plates.isEmpty {
                Text("No published charts for \(ident) in this cycle.").foregroundStyle(p.textDim)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(model.palette.textDim.opacity(0.7))
            Text("Search an airport to see its charts").foregroundStyle(model.palette.textDim)
            Text("Or file a flight plan and your destination's plates appear here.")
                .font(.caption).foregroundStyle(model.palette.textDim.opacity(0.8)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}
