import SwiftUI

/// The "Airports" bottom tab (next to Plates): a ForeFlight-style airport directory. Each row shows the
/// airport-diagram thumbnail plus a pilot caption — flight category (VFR/MVFR/IFR/LIFR) + latest weather,
/// key frequencies, approach types, and elevation / pattern altitude. Defaults to your route + nearby
/// fields; search finds any airport. Tapping a row opens that field's plates binder.
struct AirportsTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var metars: MetarStore
    @State private var query = ""
    @State private var searchActive = false

    var body: some View {
        Group {
            if model.selectedTab == .airports { content } else { Color.clear }
        }
        .onChange(of: model.selectedTab) { _, tab in
            if tab == .airports { model.deviceLocation.start(); refreshWeather() }
            else { searchActive = false }
        }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if !query.isEmpty { searchResults } else { directory }
            }
            .navigationTitle("Airports")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searchActive,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Airport — KBOS, or “Logan”")
        }
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .onAppear { model.deviceLocation.start(); refreshWeather() }
        // Defer to the next main-actor hop: @Published fires in willSet, so reading `coord` synchronously
        // here would see the PRE-update (nil) value — the deferred read sees the committed fix.
        .onReceive(model.deviceLocation.$coord) { _ in Task { @MainActor in refreshWeather() } }
    }

    // MARK: default directory (route + nearby)

    private var directory: some View {
        let p = model.palette
        let route = routeIdents
        let nearby = nearbyIdents.filter { !route.contains($0) }
        return List {
            if route.isEmpty && nearby.isEmpty {
                Text("Search for an airport, or file a flight plan to see your route’s fields here.")
                    .foregroundStyle(p.textDim)
            }
            if !route.isEmpty {
                Section("On your route") { ForEach(route, id: \.self) { row($0) } }
            }
            if !nearby.isEmpty {
                Section("Nearby") { ForEach(nearby, id: \.self) { row($0) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var searchResults: some View {
        let p = model.palette
        let hits = MapSearch.results(query, limit: 200)
            .filter { $0.kind == .airport && NavMeta.airport($0.ident) != nil }
            .prefix(30).map(\.ident)
        return List {
            if hits.isEmpty {
                Text("No airports match “\(query)”.").foregroundStyle(p.textDim)
            } else {
                ForEach(Array(hits), id: \.self) { row($0) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onAppear { metars.ensure(Array(hits)) }
    }

    // MARK: one airport row

    private func row(_ ident: String) -> some View {
        let p = model.palette
        let s = AirportSummary.make(ident)
        let metar = metars.metar(ident)
        return Button {
            model.platesAirport = ident
            model.selectedTab = .plates
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AirportDiagramImage(ident: ident, height: 116).environmentObject(model)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(s.ident).font(.system(.headline, design: .monospaced)).foregroundStyle(p.text)
                        FlightCategoryChip(metar: metar)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                    }
                    if let name = s.name {
                        Text(name).font(.caption).foregroundStyle(p.textDim).lineLimit(1)
                    }
                    Text(metar?.summary ?? "Latest weather unavailable")
                        .font(.caption).foregroundStyle(metar == nil ? p.textDim : p.text).lineLimit(1)
                    if !s.keyFreqs.isEmpty {
                        Text(s.keyFreqs.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  "))
                            .font(.caption2.monospaced()).foregroundStyle(p.accent).lineLimit(1)
                    }
                    Text(detailLine(s)).font(.caption2).foregroundStyle(p.textDim).lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("airport-row")
    }

    /// Procedures · field elevation · pattern altitude — the bottom caption line (spelled out, per feedback).
    private func detailLine(_ s: AirportSummary) -> String {
        var parts: [String] = []
        if !s.procedureTypes.isEmpty { parts.append(s.procedureTypes.joined(separator: " · ")) }
        if let e = s.elevationFt { parts.append("Field elevation \(e.grouped)′") }
        if let tpa = s.patternAltFt { parts.append("Pattern altitude \(tpa.grouped)′ (est)") }
        return parts.joined(separator: "   ·   ")
    }

    // MARK: relevant airports

    private var routeIdents: [String] {
        guard let fp = model.flightPlan else { return [] }
        return [fp.departure, fp.destination, fp.alternate]
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && NavMeta.airport($0) != nil }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }   // dedupe, keep order
    }

    private var nearbyIdents: [String] {
        guard let c = model.stratuxGPS?.coordinate ?? model.deviceLocation.coord else { return [] }
        let dLat = 60.0 / 60.0                                    // ~60 NM box
        let dLon = dLat / max(cos(c.lat * .pi / 180), 0.1)
        let box = BBox(minLat: c.lat - dLat, minLon: c.lon - dLon, maxLat: c.lat + dLat, maxLon: c.lon + dLon)
        func d2(_ p: Coord) -> Double { let a = p.lat - c.lat, b = (p.lon - c.lon) * cos(c.lat * .pi / 180); return a * a + b * b }
        return NavDatabase.nearby(box, types: [0], limit: 120)
            .filter { !Procedures.forAirport($0.ident).isEmpty }
            .sorted { d2($0.coord) < d2($1.coord) }
            .prefix(10).map(\.ident)
    }

    private func refreshWeather() { metars.ensure(routeIdents + nearbyIdents) }
}
