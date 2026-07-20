import SwiftUI

/// The "Plates" tab, organised as BINDERS (one per airport, ForeFlight-style): the top level is a list
/// of airport binders (your route + nearby fields, plus search); opening a binder shows its FAA charts as
/// LARGE thumbnails you can eyeball, grouped by category (approaches by runway). Tap a thumbnail to open
/// the plate full-page or send it to the map as a georeferenced overlay.
struct PlatesTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    // Airport binders are PUSHED onto this path (one ident) so iOS gives a native back button AND the
    // interactive edge-swipe-back for free — the binder used to be a manual state-swap with neither.
    @State private var navPath: [String] = []
    private var airport: String? { navPath.last }   // the OPEN binder's airport (nil = the binder list)
    @State private var plate: AirportProcedure?     // the plate open full-screen
    @State private var searchActive = false         // drives `.searchable` focus so we can dismiss it on tab-leave
    @State private var showFlightBag = false
    @State private var nearbyBinders: [String] = []  // nearest charted fields, recomputed as the GPS fix moves
    @State private var lastNearbyCoord: Coord?       // movement gate for the (off-main) nearby scan
    // Thumbnail min-width (persisted). ~340 yields 2 columns in iPad portrait / 3 in landscape from the
    // adaptive grid; the lower-right slider lets the pilot trade columns for size (Word's zoom slider).
    @AppStorage("atc.plates.thumbSize") private var thumbSize: Double = 340
    private static let thumbMin = 210.0, thumbMax = 560.0

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
            // GPS is owned by the always-mounted map (MapHostView) + scene phase — this tab just READS
            // deviceLocation.coord, so it no longer starts/stops the shared session (that used to freeze
            // the map's ownship). Refresh the nearest-field list when the tab becomes active.
            if tab == .plates { refreshNearby() }
            else { searchActive = false }             // drop keyboard focus when leaving (hardware-kbd EFB)
        }
    }

    private var content: some View {
        NavigationStack(path: $navPath) {
            Group {
                if !query.isEmpty { airportPicker } else { binderList }
            }
            .navigationTitle("Binders")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searchActive,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Airport — KBOS, or “Logan”")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    FlightBagButton(bag: model.plateBag, accent: model.palette.accent) { showFlightBag = true }
                }
            }
            // The binder is a PUSHED destination → automatic "‹ Binders" back button + edge-swipe-back.
            .navigationDestination(for: String.self) { apt in
                binderDetail(apt)
                    .navigationTitle(apt)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {           // keep the Flight Bag reachable inside a binder (native back takes leading)
                        ToolbarItem(placement: .topBarTrailing) {
                            FlightBagButton(bag: model.plateBag, accent: model.palette.accent) { showFlightBag = true }
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
            refreshNearby()               // GPS is owned by the map; just read the current fix for "Nearby"
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
        if !Procedures.forAirport(want).isEmpty {
            navPath = [want]; query = ""
            model.noteAirportViewed(want)
        }
    }

    /// Nearest charted fields for the "Nearby" binder section. Gated on ~0.5 NM of movement (a parked
    /// aircraft's GPS jitter must not churn the list) AND run OFF the main actor — `NavDatabase.nearby`
    /// walks the full ~90k-ident table, so it must never run on the main thread per GPS tick.
    private func refreshNearby() {
        guard let c = model.stratuxGPS?.coordinate ?? model.deviceLocation.coord else { return }
        if let last = lastNearbyCoord, PlatesTabView.distanceNM(last, c) < 0.5 { return }   // movement gate
        lastNearbyCoord = c
        Task { @MainActor in
            let near = await Task.detached { AirportSummary.nearbyCharted(lat: c.lat, lon: c.lon) }.value
            if near != nearbyBinders { nearbyBinders = near }
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
                        query = ""; navPath = [o.ident]; model.noteAirportViewed(o.ident)
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
        // A Word-style zoom slider pinned to the lower-right corner: resize the plate thumbnails live
        // (fewer, bigger columns ⇄ more, smaller). Persisted via `thumbSize`.
        .overlay(alignment: .bottomTrailing) { thumbZoomControl }
    }

    /// The lower-right thumbnail-size slider (flanked by small/large glyphs), floating over the binder.
    private var thumbZoomControl: some View {
        let p = model.palette
        return HStack(spacing: 8) {
            Image(systemName: "minus.magnifyingglass").font(.caption2).foregroundStyle(p.textDim)
            Slider(value: $thumbSize, in: Self.thumbMin...Self.thumbMax).frame(width: 130).tint(p.accent)
                .accessibilityIdentifier("plate-thumb-size")
            Image(systemName: "plus.magnifyingglass").font(.callout).foregroundStyle(p.textDim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(p.border, lineWidth: 0.5))
        .shadow(radius: 4)
        .padding(.trailing, 14).padding(.bottom, 14)
        .accessibilityLabel("Resize plate thumbnails")
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
        // ~340pt minimum → 2 columns in iPad portrait, 3 in landscape; the lower-right slider (thumbSize)
        // trades columns for size. Each thumbnail sizes itself to the plate's own aspect ratio, so there is
        // no letterbox/whitespace around the chart.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 12)], alignment: .leading, spacing: 12) {
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
        return Button { navPath.append(ident); model.noteAirportViewed(ident) } label: {
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
    @State private var aspect: CGFloat = 0.773        // w/h; FAA plate portrait default until the image loads
    @State private var phase: Phase = .loading
    private enum Phase { case loading, ready, none }

    var body: some View {
        let p = model.palette
        return Button { onTap() } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Color.white
                    if let image {
                        // The cell takes the plate's own aspect ratio, so the chart fills it edge-to-edge with
                        // NO letterbox/whitespace around it (the old fixed-height cell letterboxed a portrait
                        // plate inside a white card).
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if phase == .loading {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.gray)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        if PlateGeoref.lookup(pdf: proc.pdf) != nil { Image(systemName: "scope").foregroundStyle(p.good) }
                        if PlateStore.isCached(proc) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(p.good) }
                    }
                    .font(.caption2).padding(5)
                    .background(.ultraThinMaterial, in: Capsule()).padding(4)   // legible over the chart, not floating on white
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
        // Render generously (800px) so a thumbnail stays crisp at the largest 2-column slider size without
        // re-rendering when the pilot resizes. LazyVGrid renders only visible cells, so memory stays bounded.
        let rendered = await Task.detached(priority: .utility) {
            PlateImageRenderer.firstPageImage(pdfURL: url, maxDimension: 800)
        }.value
        guard !Task.isCancelled else { return }
        if let rendered {
            image = rendered
            if rendered.size.height > 0 {                  // match the cell to the plate so there's no whitespace
                aspect = max(0.4, min(rendered.size.width / rendered.size.height, 2.2))
            }
            phase = .ready
        } else { phase = .none }
    }
}
