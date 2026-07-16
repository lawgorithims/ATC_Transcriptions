import SwiftUI

/// The "Plates" tab, organised as BINDERS (one per airport, ForeFlight-style): the top level is a list
/// of airport binders (your route + nearby fields, plus search); opening a binder shows its FAA charts as
/// LARGE thumbnails you can eyeball, grouped by category (approaches by runway). Tap a thumbnail to open
/// the plate full-page or send it to the map as a georeferenced overlay.
struct PlatesTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var airport: String?             // the OPEN binder's airport (nil = the binder list)
    @State private var plate: AirportProcedure?     // the plate open full-screen
    @State private var userPinned = false           // the pilot opened a specific binder (from search/handoff)
    @State private var searchActive = false         // drives `.searchable` focus so we can dismiss it on tab-leave
    @State private var showFlightBag = false
    @State private var nearbyBinders: [String] = []  // nearest charted fields, recomputed as the GPS fix moves

    /// The nearest airport that publishes plates within `withinNM` of a position — reuses the bundled
    /// nav DB's airport index (no new spatial data). nil when none is close.
    static func nearestPlateAirport(lat: Double, lon: Double, withinNM: Double = 60) -> String? {
        assert((-90...90).contains(lat) && (-180...180).contains(lon), "nearestPlateAirport: fix out of range")
        assert(withinNM > 0, "nearestPlateAirport: search radius must be positive")
        let dLat = withinNM / 60.0
        let dLon = dLat / max(cos(lat * .pi / 180), 0.1)
        let box = BBox(minLat: lat - dLat, minLon: lon - dLon, maxLat: lat + dLat, maxLon: lon + dLon)
        func d2(_ p: Coord) -> Double { let a = p.lat - lat, b = (p.lon - lon) * cos(lat * .pi / 180); return a * a + b * b }
        return NavDatabase.nearby(box, types: [0], limit: 120)     // type 0 = airports
            .filter { !Procedures.forAirport($0.ident).isEmpty }
            .min { d2($0.coord) < d2($1.coord) }?.ident
    }

    /// Great-circle-ish distance in nautical miles between two fixes (flat-earth good enough at the sub-NM
    /// scale this gates on). 1° latitude = 60 NM; longitude scaled by cos(mean latitude).
    static func distanceNM(_ a: Coord, _ b: Coord) -> Double {
        let dLat = (b.lat - a.lat) * 60.0
        let dLon = (b.lon - a.lon) * 60.0 * cos((a.lat + b.lat) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
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
                model.deviceLocation.start(); refreshNearby()   // get a fix so "Nearby" binders resolve
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
                    binderDetail(apt)
                } else {
                    binderList
                }
            }
            .navigationTitle(query.isEmpty ? (airport ?? "Binders") : "Search")
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
                        Button { airport = nil; userPinned = true } label: { Label("Binders", systemImage: "books.vertical") }
                            .accessibilityIdentifier("plate-change-airport")
                    }
                }
            }
            .sheet(isPresented: $showFlightBag) {
                FlightBagView(bag: model.plateBag, currentAirport: airport).environmentObject(model)
            }
        }
        .tint(model.palette.accent)
        // A georef'd plate's viewer stops the SHARED DeviceLocation on close; re-arm it here (after the
        // viewer's onDisappear) so the tab's nearest-field follow keeps working. start() is idempotent.
        .fullScreenCover(item: $plate, onDismiss: {
            if model.selectedTab == .plates { model.deviceLocation.start() }
        }) { proc in
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
            model.deviceLocation.start(); refreshNearby()               // start GPS so "Nearby" binders resolve
            applyHandoff()
            if model.showFlightBagOnLaunch { showFlightBag = true; model.showFlightBagOnLaunch = false }
            if let pdf = model.previewPlatePdf, let apt = airport,
               let proc = Procedures.forAirport(apt).first(where: { $0.pdf == pdf }) {
                plate = proc; model.previewPlatePdf = nil               // QA: auto-open the full-page viewer
            }
        }
        // Recompute the "Nearby" binder list as the GPS fix moves. Deferred to the next main-actor hop:
        // @Published fires in willSet, so a synchronous read of `coord` here would see the pre-update value.
        .onReceive(model.deviceLocation.$coord) { _ in Task { @MainActor in refreshNearby() } }
        .onChange(of: model.platesAirport) { _, _ in applyHandoff() }
    }

    /// Open the binder named by a map/QA hand-off (`platesAirport`) if present. The one-shot is cleared
    /// UNCONDITIONALLY — even for a chartless airport — so it can't linger and mis-fire later.
    private func applyHandoff() {
        guard let want = model.platesAirport else { return }
        model.platesAirport = nil
        if !Procedures.forAirport(want).isEmpty { airport = want; userPinned = true; query = "" }
    }

    /// Nearest charted fields for the "Nearby" binder section — gated on ~0.25 NM of movement so a parked
    /// aircraft's GPS jitter doesn't churn the list (or the off-main spatial query) every tick.
    private func refreshNearby() {
        guard let c = model.stratuxGPS?.coordinate ?? model.deviceLocation.coord else { return }
        let dLat = 1.0                                            // ~60 NM box
        let dLon = dLat / max(cos(c.lat * .pi / 180), 0.1)
        let box = BBox(minLat: c.lat - dLat, minLon: c.lon - dLon, maxLat: c.lat + dLat, maxLon: c.lon + dLon)
        func d2(_ p: Coord) -> Double { let a = p.lat - c.lat, b = (p.lon - c.lon) * cos(c.lat * .pi / 180); return a * a + b * b }
        let near = NavDatabase.nearby(box, types: [0], limit: 120)
            .filter { !Procedures.forAirport($0.ident).isEmpty }
            .sorted { d2($0.coord) < d2($1.coord) }
            .prefix(12).map(\.ident)
        if Array(near) != nearbyBinders { nearbyBinders = Array(near) }
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

    // MARK: binder detail — a field's charts as LARGE thumbnails

    private func binderDetail(_ ident: String) -> some View {
        let p = model.palette
        let plates = Procedures.forAirport(ident)
        let approaches = plates.filter { $0.category == .approach }
        let circling = "Circling / other"
        let byRunway = Dictionary(grouping: approaches) { Self.runway(of: $0.name) ?? circling }
        let runwayKeys = byRunway.keys.sorted { Self.runwaySortKey($0) < Self.runwaySortKey($1) }
        let otherGroups: [(AirportProcedure.Category, String)] = [
            (.airport, "Airport"), (.departure, "Departures (DPs)"),
            (.arrival, "Arrivals (STARs)"), (.other, "Other"),
        ]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let name = NavMeta.airport(ident)?.name {
                    Text(name).font(.subheadline).foregroundStyle(p.textDim).padding(.horizontal, 4)
                }
                if plates.isEmpty {
                    Text("No published charts for \(ident) in this cycle.")
                        .foregroundStyle(p.textDim).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                // Approaches first (what the pilot reaches for most), grouped by runway; then the airport
                // diagram, DPs, STARs, and everything else.
                if !approaches.isEmpty {
                    sectionHeader("Approaches", approaches.count)
                    ForEach(runwayKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(key == circling ? key : "Runway \(key)")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(p.text).padding(.horizontal, 4)
                            thumbGrid(byRunway[key] ?? [])
                        }
                    }
                }
                ForEach(otherGroups, id: \.0) { cat, heading in
                    let items = plates.filter { $0.category == cat }
                    if !items.isEmpty { chartGroup(heading, count: items.count, items: items) }
                }
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func chartGroup(_ heading: String, count: Int, items: [AirportProcedure]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(heading, count)
            thumbGrid(items)
        }
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        let p = model.palette
        return HStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(p.text)
            Text("\(count)").font(.caption).foregroundStyle(p.textDim)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.top, 6)
    }

    /// A lazily-rendered grid of large plate thumbnails (only visible cells download + render, so a big
    /// binder never renders 70 PDFs at once).
    private func thumbGrid(_ items: [AirportProcedure]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(items) { proc in
                PlateThumb(proc: proc) { plate = proc }.environmentObject(model)
            }
        }
    }

    /// Extract the runway designator from an approach name ("ILS OR LOC RWY 04R" → "04R", "RNAV (GPS)
    /// RWY 22L" → "22L", "VOR RWY 15" → "15"). nil for circling-only approaches (e.g. "VOR-A").
    static func runway(of name: String) -> String? {
        let up = name.uppercased()
        guard let r = up.range(of: "RWY ") else { return nil }
        var digits = "", suffix = ""
        for ch in up[r.upperBound...].prefix(3) {          // bounded (Power-of-10 rule 2): ≤2 digits + 1 side
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

    // MARK: binder list (the top level)

    private var binderList: some View {
        let p = model.palette
        let route = routeIdents
        let nearby = nearbyBinders.filter { !route.contains($0) }
        return List {
            if route.isEmpty && nearby.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical").font(.system(size: 40)).foregroundStyle(p.textDim.opacity(0.7))
                    Text("Search an airport to open its binder").foregroundStyle(p.textDim)
                    Text("Your route's fields and nearby airports appear here as binders.")
                        .font(.caption).foregroundStyle(p.textDim.opacity(0.8)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 60).listRowSeparator(.hidden)
            }
            if !route.isEmpty { Section("On your route") { ForEach(route, id: \.self) { binderRow($0) } } }
            if !nearby.isEmpty { Section("Nearby") { ForEach(nearby, id: \.self) { binderRow($0) } } }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func binderRow(_ ident: String) -> some View {
        let p = model.palette
        let count = Procedures.forAirport(ident).count
        return Button { airport = ident; userPinned = true } label: {
            HStack(spacing: 12) {
                AirportDiagramImage(ident: ident, height: 84).environmentObject(model)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ident).font(.system(.headline, design: .monospaced)).foregroundStyle(p.text)
                    if let n = NavMeta.airport(ident)?.name {
                        Text(n).font(.caption).foregroundStyle(p.textDim).lineLimit(1)
                    }
                    Text("\(count) chart\(count == 1 ? "" : "s")").font(.caption2.weight(.semibold)).foregroundStyle(p.accent)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(p.textDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic).accessibilityIdentifier("plate-binder")
    }

    /// The flight plan's airports (departure, destination, alternate) that publish charts — deduped, order
    /// preserved. These head the binder list as "On your route".
    private var routeIdents: [String] {
        guard let fp = model.flightPlan else { return [] }
        return [fp.departure, fp.destination, fp.alternate]
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && !Procedures.forAirport($0).isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
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

/// One large plate thumbnail in a binder: the chart's first page rendered on white, its name beneath, and
/// the georef/downloaded badges. Renders off the main actor and cancels on scroll-away (only visible cells
/// in the LazyVGrid ever download + render, so a 70-chart binder never renders all at once). Tap → open.
struct PlateThumb: View {
    @EnvironmentObject var model: AppModel
    let proc: AirportProcedure
    var onTap: () -> Void

    @State private var image: UIImage?
    @State private var phase: Phase = .loading
    private enum Phase { case loading, ready, none }

    var body: some View {
        let p = model.palette
        Button { onTap() } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.white)
                    if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding(2)
                    } else if phase == .loading {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.gray)
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        if PlateGeoref.lookup(pdf: proc.pdf) != nil { Image(systemName: "scope").foregroundStyle(p.good) }
                        if PlateStore.isCached(proc) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(p.good) }
                    }
                    .font(.caption2).padding(5)
                }
                Text(proc.name).font(.caption2).foregroundStyle(p.text).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("plate-thumb")
        .accessibilityLabel(proc.name)
        .task(id: proc.pdf) { await load() }
    }

    private func load() async {
        image = nil; phase = .loading
        guard let url = await PlateStore.ensureOnDisk(proc) else { phase = .none; return }
        let rendered = await Task.detached(priority: .utility) {
            PlateImageRenderer.firstPageImage(pdfURL: url, maxDimension: 500)
        }.value
        guard !Task.isCancelled else { return }
        if let rendered { image = rendered; phase = .ready } else { phase = .none }
    }
}
