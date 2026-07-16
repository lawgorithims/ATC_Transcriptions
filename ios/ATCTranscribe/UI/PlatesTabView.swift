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
    @State private var showFlightBag = false

    /// The best default airport when the pilot hasn't picked one: WHERE THEY ARE (nearest airport with
    /// plates, from a live GPS/Stratux fix) takes priority over the filed plan — the plate you want is
    /// almost always your current field, and defaulting to a stale filed destination is what left the
    /// tab "stuck" on a far-away airport. Falls back to the filed destination/departure, then nothing.
    /// The explicit map/QA hand-off is applied separately (via `platesAirport`), so it isn't re-read here.
    private var defaultAirport: String? {
        if let c = model.stratuxGPS?.coordinate ?? model.deviceLocation.coord,
           let near = PlatesTabView.nearestPlateAirport(lat: c.lat, lon: c.lon) {
            return near
        }
        guard let fp = model.flightPlan else { return nil }
        let d = fp.destination.trimmingCharacters(in: .whitespaces).uppercased()
        let o = fp.departure.trimmingCharacters(in: .whitespaces).uppercased()
        if !d.isEmpty, !Procedures.forAirport(d).isEmpty { return d }
        if !o.isEmpty, !Procedures.forAirport(o).isEmpty { return o }
        return nil
    }

    /// The nearest airport that publishes plates within `withinNM` of a position — reuses the bundled
    /// nav DB's airport index (no new spatial data). nil when none is close.
    static func nearestPlateAirport(lat: Double, lon: Double, withinNM: Double = 60) -> String? {
        let dLat = withinNM / 60.0
        let dLon = dLat / max(cos(lat * .pi / 180), 0.1)
        let box = BBox(minLat: lat - dLat, minLon: lon - dLon, maxLat: lat + dLat, maxLon: lon + dLon)
        func d2(_ p: Coord) -> Double { let a = p.lat - lat, b = (p.lon - lon) * cos(lat * .pi / 180); return a * a + b * b }
        return NavDatabase.nearby(box, types: [0], limit: 120)     // type 0 = airports
            .filter { !Procedures.forAirport($0.ident).isEmpty }
            .min { d2($0.coord) < d2($1.coord) }?.ident
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
            if tab == .plates {
                model.deviceLocation.start()              // get a fix so the default follows the pilot's position
            } else {
                searchActive = false                      // drop keyboard focus when leaving (hardware-kbd EFB)
                if plate == nil { model.deviceLocation.stop() }   // battery: don't run GPS off-tab (viewer owns it if open)
            }
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
                ToolbarItem(placement: .topBarLeading) {
                    FlightBagButton(bag: model.plateBag, accent: model.palette.accent) { showFlightBag = true }
                }
                if airport != nil, query.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change") { airport = nil; userPinned = true }
                            .accessibilityIdentifier("plate-change-airport")
                    }
                }
            }
            .sheet(isPresented: $showFlightBag) {
                FlightBagView(bag: model.plateBag, currentAirport: airport).environmentObject(model)
            }
        }
        .tint(model.palette.accent)
        .fullScreenCover(item: $plate) { proc in
            PlateViewer(procedure: proc, airport: airport ?? "", palette: model.palette, deviceLocation: model.deviceLocation,
                        onSendToMap: { url in
                            model.overlayPlate(proc, airport: airport ?? "", pdf: url)
                            model.selectedTab = .map          // jump to the map so the overlay is visible
                            plate = nil
                        },
                        onClose: { plate = nil })
                .environmentObject(model)
        }
        .onAppear {
            model.deviceLocation.start()                                // start GPS so the position default resolves
            applyPendingOrDefault()
            if model.showFlightBagOnLaunch { showFlightBag = true; model.showFlightBagOnLaunch = false }
            if let pdf = model.previewPlatePdf, let apt = airport,
               let proc = Procedures.forAirport(apt).first(where: { $0.pdf == pdf }) {
                plate = proc; model.previewPlatePdf = nil               // QA: auto-open the full-page viewer
            }
        }
        // A GPS fix usually arrives AFTER onAppear (async + permission), so re-seed the default when it
        // lands — this is what actually unsticks the tab from a far-away filed destination. Pinning wins.
        .onReceive(model.deviceLocation.$coord) { c in
            guard !userPinned, let c,
                  let near = PlatesTabView.nearestPlateAirport(lat: c.lat, lon: c.lon) else { return }
            if airport != near { airport = near }
        }
        .onChange(of: model.platesAirport) { _, _ in applyPendingOrDefault() }
        .onChange(of: model.flightPlan) { _, _ in
            // Follow a live plan amendment (the app's core flow) unless the pilot pinned an airport.
            if !userPinned { airport = defaultAirport }
        }
    }

    /// Consume a pending map/QA hand-off (`platesAirport`) if present; otherwise seed the default
    /// airport once (unless the pilot has pinned one). The one-shot is cleared UNCONDITIONALLY — even
    /// if it named a chartless airport — so it can't linger and mis-fire later.
    private func applyPendingOrDefault() {
        if let want = model.platesAirport {
            model.platesAirport = nil        // one-shot consumed regardless of whether it has charts
            if !Procedures.forAirport(want).isEmpty {
                airport = want; userPinned = true; query = ""
                return
            }
        }
        // Seed the default only before the pilot has made a choice — otherwise "Change" (airport=nil,
        // userPinned=true) would be silently undone on the next tab re-entry.
        if airport == nil, !userPinned { airport = defaultAirport }
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHaptic)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: plate list for an airport

    private func plateList(_ ident: String) -> some View {
        let p = model.palette
        let plates = Procedures.forAirport(ident)
        let approaches = plates.filter { $0.category == .approach }
        let otherGroups: [(AirportProcedure.Category, String)] = [
            (.departure, "Departures (DPs)"), (.arrival, "Arrivals (STARs)"),
            (.airport, "Airport (diagram, hot spots)"), (.other, "Other"),
        ]
        return List {
            if let name = NavMeta.airport(ident)?.name {
                Section { Text(name).font(.subheadline).foregroundStyle(p.textDim) }
            }
            // Approaches are the long list at a big field — group them by RUNWAY (collapsible), so the
            // pilot jumps straight to the runway in use instead of scanning dozens of rows.
            if !approaches.isEmpty { approachSection(approaches) }
            ForEach(otherGroups, id: \.0) { cat, heading in
                let items = plates.filter { $0.category == cat }
                if !items.isEmpty {
                    Section("\(heading) (\(items.count))") { ForEach(items) { plateRow($0) } }
                }
            }
            if plates.isEmpty {
                Text("No published charts for \(ident) in this cycle.").foregroundStyle(p.textDim)
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// The Approaches section, sub-grouped by runway. A big airport has many IAPs; a pilot looks for
    /// "the RWY 22L approaches", so each runway is its own collapsible group (circling/other last).
    @ViewBuilder private func approachSection(_ approaches: [AirportProcedure]) -> some View {
        let circlingKey = "Circling / other"
        let byRunway = Dictionary(grouping: approaches) { Self.runway(of: $0.name) ?? circlingKey }
        let keys = byRunway.keys.sorted { Self.runwaySortKey($0) < Self.runwaySortKey($1) }
        Section("Approaches (\(approaches.count))") {
            ForEach(keys, id: \.self) { key in
                let items = byRunway[key] ?? []
                DisclosureGroup {
                    ForEach(items) { plateRow($0) }
                } label: {
                    Text(key == circlingKey ? key : "Runway \(key)")
                        .font(.callout.weight(.semibold)).foregroundStyle(model.palette.text)
                    + Text("  (\(items.count))").font(.caption2).foregroundStyle(model.palette.textDim)
                }
            }
        }
    }

    private func plateRow(_ proc: AirportProcedure) -> some View {
        let p = model.palette
        return Button { Haptics.impact(.light); plate = proc } label: {
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
        .buttonStyle(.plainHaptic).accessibilityIdentifier("plate-row")
    }

    /// Extract the runway designator from an approach name ("ILS OR LOC RWY 04R" → "04R", "RNAV (GPS)
    /// RWY 22L" → "22L", "VOR RWY 15" → "15"). nil for circling-only approaches (e.g. "VOR-A").
    static func runway(of name: String) -> String? {
        let up = name.uppercased()
        guard let r = up.range(of: "RWY ") else { return nil }
        var digits = "", suffix = ""
        for ch in up[r.upperBound...] {
            if ch.isNumber, suffix.isEmpty, digits.count < 2 { digits.append(ch) }
            else if "LCR".contains(ch), !digits.isEmpty, suffix.isEmpty { suffix = String(ch); break }
            else { break }
        }
        return digits.isEmpty ? nil : digits + suffix
    }

    /// Sort key so runways order numerically (04 < 15 < 22) with L<C<R, and "Circling / other" last.
    static func runwaySortKey(_ key: String) -> Int {
        let digits = key.prefix { $0.isNumber }
        guard let n = Int(digits) else { return 100_000 }        // circling / other → last
        let side = key.last.map { "LCR".firstIndex(of: $0).map { "LCR".distance(from: "LCR".startIndex, to: $0) } ?? 3 } ?? 3
        return n * 10 + side
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

/// The Flight Bag toolbar button. Observes `PlateBag` DIRECTLY so its "running" indicator (filled icon
/// + accent dot) updates live during a download — a computed `model.plateBag.isRunning` on the parent
/// view would not, since a nested ObservableObject's changes don't republish the parent (C2).
private struct FlightBagButton: View {
    @ObservedObject var bag: PlateBag
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: bag.isRunning ? "briefcase.fill" : "briefcase")
        }
        .accessibilityIdentifier("flight-bag")
        .overlay(alignment: .topTrailing) {
            if bag.isRunning { Circle().fill(accent).frame(width: 7, height: 7).offset(x: 3, y: -2) }
        }
    }
}
