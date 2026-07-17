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
    @State private var nearbyCache: [String] = []    // cached nearby scan (never recomputed per render)
    @State private var lastNearbyCoord: Coord?       // movement gate for the (off-main) nearby scan
    @State private var infoProbe: MapProbeResult?    // ⓘ → the full airport card (weather + 7-day outlook)

    var body: some View {
        Group {
            if model.selectedTab == .airports { content } else { Color.clear }
        }
        .onChange(of: model.selectedTab) { _, tab in
            if tab == .airports { model.deviceLocation.start(); refreshNearby(); refreshWeather() }
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
        .sheet(item: $infoProbe) { probe in
            MapObjectSheet(result: probe).environmentObject(model)   // full card: weather tab + 7-day outlook
        }
        .onAppear { model.deviceLocation.start(); refreshNearby(); refreshWeather() }
        // Defer to the next main-actor hop: @Published fires in willSet, so reading `coord` synchronously
        // here would see the PRE-update (nil) value — the deferred read sees the committed fix.
        .onReceive(model.deviceLocation.$coord) { _ in Task { @MainActor in refreshNearby(); refreshWeather() } }
    }

    // MARK: default directory (route + nearby)

    private var directory: some View {
        let p = model.palette
        let favorites = model.favoriteAirports.filter { NavMeta.airport($0) != nil }
        let recents = model.recentAirports.filter { !favorites.contains($0) && NavMeta.airport($0) != nil }
        let route = routeIdents.filter { !favorites.contains($0) && !recents.contains($0) }
        let nearby = nearbyCache.filter { !favorites.contains($0) && !recents.contains($0) && !route.contains($0) }
        return List {
            if favorites.isEmpty && recents.isEmpty && route.isEmpty && nearby.isEmpty {
                Text("Search for an airport, or file a flight plan to see your route’s fields here.")
                    .foregroundStyle(p.textDim)
            }
            if !favorites.isEmpty {
                Section("Favorites") { ForEach(favorites, id: \.self) { row($0) } }
            }
            if !recents.isEmpty {
                Section("Recent") { ForEach(recents, id: \.self) { row($0) } }
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
        .onAppear { metars.ensure(favorites + recents) }   // weather for the personal sections too
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
            model.noteAirportViewed(ident)
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
                        Button { Haptics.impact(.light); model.toggleFavoriteAirport(ident) } label: {
                            Image(systemName: model.isFavoriteAirport(ident) ? "star.fill" : "star")
                                .font(.callout)
                                .foregroundStyle(model.isFavoriteAirport(ident) ? Color.hex(0xF5C451) : p.textDim)
                                .frame(width: 32, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plainHaptic)
                        .accessibilityIdentifier("airport-favorite")
                        .accessibilityLabel(model.isFavoriteAirport(ident) ? "Remove favorite" : "Add favorite")
                        // ⓘ opens the FULL airport card (Info/Weather incl. the 7-day outlook/Runway/…)
                        // without leaving the directory; the row itself still opens the plates binder.
                        Button {
                            Haptics.impact(.light)
                            // Resolve against the FULL nav database (AirportCoordinates only carries ~78
                            // major fields, so it left the button dead for almost every airport — H4).
                            let near = model.stratuxGPS?.coordinate ?? model.deviceLocation.coord
                            if let c = NavDatabase.resolve(ident, near: near) {
                                model.noteAirportViewed(ident)
                                infoProbe = MapProbeResult(id: ident,
                                                           objects: [IdentifiedObject(kind: .airport, ident: ident,
                                                                                      coord: c, onRoute: false)])
                            }
                        } label: {
                            Image(systemName: "info.circle").font(.callout).foregroundStyle(p.accent)
                                .frame(width: 32, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plainHaptic)
                        .accessibilityIdentifier("airport-info")
                        .accessibilityLabel("Airport details")
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

    /// Recompute the cached nearby list — gated on ~0.5 NM of movement and run OFF the main actor (the
    /// NavDatabase scan walks the full ~90k-ident table, so it must never run per SwiftUI render or GPS tick).
    private func refreshNearby() {
        guard let c = model.stratuxGPS?.coordinate ?? model.deviceLocation.coord else { return }
        if let last = lastNearbyCoord, PlatesTabView.distanceNM(last, c) < 0.5 { return }   // movement gate
        lastNearbyCoord = c
        Task { @MainActor in
            let near = await Task.detached { AirportSummary.nearbyCharted(lat: c.lat, lon: c.lon, limit: 10) }.value
            if near != nearbyCache { nearbyCache = near; refreshWeather() }
        }
    }

    private func refreshWeather() { metars.ensure(routeIdents + nearbyCache) }
}
