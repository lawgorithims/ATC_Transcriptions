import SwiftUI

/// Tap-to-identify content: what the pilot tapped, its details, and the route actions (add /
/// insert-in-order / Direct-To / set endpoint / remove). Chromeless so it can be hosted either in the
/// home-map **side panel** (a floating widget on regular width) or in the compact **bottom sheet**
/// (`MapObjectSheet`). When a tap hits several things it opens on a chooser, then drills in. Read-only
/// for airspace and traffic.
struct MapObjectView: View {
    @EnvironmentObject var model: AppModel
    let result: MapProbeResult
    var onCommit: () -> Void = {}      // called after an edit (the flight-plan change also redraws the map)
    var onClose: () -> Void = {}       // dismiss the panel/sheet after an action

    @State private var picked: IdentifiedObject?
    @State private var confirmDirect: IdentifiedObject?
    @State private var plate: AirportProcedure?    // the FAA plate being viewed full-screen
    @State private var climateTarget: ClimateTarget?
    // ForeFlight-style airport card: top tab + the Procedure sub-tab, plus which plates are mid-download
    // for the inline "Map" (send-to-map) button.
    @State private var airportTab: AirportTab = .info
    @State private var procTab: ProcTab = .approach
    @State private var sendingToMap: Set<String> = []

    /// Top-level airport-card tabs (matches ForeFlight's Info / Weather / Runway / Procedure / NOTAM).
    private enum AirportTab: String, CaseIterable, Identifiable {
        case info, weather, runway, procedure, notam
        var id: String { rawValue }
        var label: String {
            switch self {
            case .info: return "Info"; case .weather: return "Weather"; case .runway: return "Runway"
            case .procedure: return "Procedure"; case .notam: return "NOTAM"
            }
        }
    }
    /// Procedure sub-tabs, each mapping to an `AirportProcedure.Category` of PLATE charts: Airport (field
    /// diagrams), Departure (DPs), Arrival (STARs), Approach, and Other (DVA / hot spots / takeoff &
    /// alternate minimums / LAHSO). Coded-procedure loading onto the route lives in the voice EFB, not here.
    private enum ProcTab: String, CaseIterable, Identifiable {
        case airport, departure, arrival, approach, other
        var id: String { rawValue }
        var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        var category: AirportProcedure.Category {
            switch self {
            case .airport: return .airport; case .departure: return .departure
            case .arrival: return .arrival; case .approach: return .approach; case .other: return .other
            }
        }
    }

    /// Sheet payload for the Airport Climate card (`.sheet(item:)` works in both hosts — the
    /// floating side panel and the compact bottom sheet).
    private struct ClimateTarget: Identifiable {
        let ident: String
        let coord: Coord
        var id: String { ident }
    }

    /// The object to detail: the pick, else the sole probe hit (a multi-hit probe shows the chooser).
    private var object: IdentifiedObject? { picked ?? (result.objects.count == 1 ? result.objects.first : nil) }

    var body: some View {
        Group {
            if let obj = object { detail(obj) } else { chooser }
        }
        .navigationTitle(object.map(title) ?? "What's here?")
        .navigationBarTitleDisplayMode(.inline)
        .tint(model.palette.accent)
        .alert("Go direct to \(confirmDirect?.ident ?? "")?", isPresented: directBinding) {
            Button("Go Direct", role: .destructive) { if let o = confirmDirect { model.directTo(o.ident); finish() } }
            Button("Cancel", role: .cancel) { confirmDirect = nil }
        } message: {
            Text("Sets \(confirmDirect?.ident ?? "") as your destination and clears intermediate waypoints. Present-position sequencing comes later.")
        }
        // The full approach/departure plate opens over the whole screen (its own "tab"), with the
        // frequencies, altitudes, minimums, and profile the coded waypoints can't show.
        .fullScreenCover(item: $plate) { proc in
            PlateViewer(procedure: proc, airport: plateAirport, palette: model.palette, deviceLocation: model.deviceLocation,
                        onSendToMap: { url in
                            model.overlayPlate(proc, airport: plateAirport, pdf: url)
                            plate = nil; onClose()   // dismiss viewer + panel so the map (with the plate) is visible
                        },
                        onClose: { plate = nil })
                .environmentObject(model)
        }
        .sheet(item: $climateTarget) { target in
            // Pass the palette by value (not the whole model) so the climate sheet isn't re-rendered
            // by every live-data publish while it's open.
            AirportClimateView(palette: model.palette, ident: target.ident, coord: target.coord)
        }
    }

    /// The airport ident whose plate is open (the detailed airport object).
    private var plateAirport: String { object?.ident ?? "" }

    private func title(_ o: IdentifiedObject) -> String {
        if o.kind == .userPoint { return UserPoint.label(o.ident) }
        return o.ident.isEmpty ? o.kind.label : o.ident
    }
    private var directBinding: Binding<Bool> {
        Binding(get: { confirmDirect != nil }, set: { if !$0 { confirmDirect = nil } })
    }

    // MARK: Disambiguation chooser

    private var chooser: some View {
        List {
            Section {
                ForEach(result.objects) { o in
                    Button { picked = o } label: {
                        HStack(spacing: 10) {
                            badge(o.kind)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(o))
                                    .font(.system(.body, design: .monospaced)).foregroundStyle(model.palette.text)
                                if let sub = subtitle(o) {
                                    Text(sub).font(.caption).foregroundStyle(model.palette.textDim)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(model.palette.textDim)
                        }
                    }
                }
            } footer: { Text("Several things are here — pick one.") }
        }
        .scrollContentBackground(.hidden)
    }

    private func subtitle(_ o: IdentifiedObject) -> String? {
        switch o.kind {
        case .airport:   return NavMeta.airport(o.ident)?.name ?? "Airport"
        case .vor:       return NavMeta.navaid(o.ident)?.typeLabel ?? "Navaid"
        case .fix:       return "Fix"
        case .airspace:  return o.airspace.map { Self.airspaceTypeName($0.cls) }
        case .traffic:   return "Traffic"
        case .userPoint: return "Dropped point"
        case .hazard:    return o.hazard?.category.label ?? "Hazard"
        }
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ o: IdentifiedObject) -> some View {
        if o.kind == .airport {
            airportCard(o)
        } else {
            nonAirportDetail(o)
        }
    }

    /// The original flat layout, kept for non-airport objects (fixes, navaids, airspace, traffic…).
    @ViewBuilder private func nonAirportDetail(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        List {
            Section {
                HStack(spacing: 12) {
                    badge(o.kind, large: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(o))
                            .font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(p.text)
                        if let name = displayName(o) { Text(name).font(.subheadline).foregroundStyle(p.textDim) }
                    }
                    Spacer()
                }
            }
            infoSection(o)
            if o.kind == .hazard { hazardFooter }
            actionSection(o)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Airport card (ForeFlight-style tabs)

    @ViewBuilder private func airportCard(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        List {
            Section {
                HStack(spacing: 12) {
                    badge(o.kind, large: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(o))
                            .font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(p.text)
                        if let name = displayName(o) { Text(name).font(.subheadline).foregroundStyle(p.textDim) }
                    }
                    Spacer()
                }
                airportQuickActions(o)
            }
            Section {
                Picker("View", selection: $airportTab) {
                    ForEach(AirportTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
            switch airportTab {
            case .info:      infoSection(o)
            case .weather:   weatherTab(o)
            case .runway:    runwayTab(o.ident)
            case .procedure: procedureTab(o.ident)
            case .notam:     notamTab(o.ident)
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// The compact action strip under the header (Direct-To / route endpoints), mirroring ForeFlight's
    /// "Direct To / Add to Route" buttons.
    private func airportQuickActions(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        return HStack(spacing: 8) {
            quickAction("Direct-To", "location.north.line") { confirmDirect = o }
            quickAction("Add", "plus.circle") { model.addToRoute(o.ident); finish() }
            quickAction("Dep", "airplane.departure") { model.setDeparture(o.ident); finish() }
            quickAction("Dest", "airplane.arrival") { model.setDestination(o.ident); finish() }
        }
        .padding(.top, 2)
        .foregroundStyle(p.accent)
    }

    private func quickAction(_ label: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); act() } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Airport-card tabs

    /// Weather = NASA POWER climatology (opens the Climate card) + nearby EONET satellite hazards. No
    /// live METAR/TAF/NOTAM source is bundled, so that's stated honestly rather than faked.
    @ViewBuilder private func weatherTab(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        climateSection(o)
        let near = model.hazardEvents
            .map { ($0, Geo.nmBetween(o.coord, $0.point)) }
            .filter { $0.1 <= 200 }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
        if !near.isEmpty {
            Section("Hazards nearby (NASA EONET)") {
                ForEach(Array(near), id: \.0.id) { ev, nm in
                    HStack(spacing: 10) {
                        Image(systemName: ev.category.glyph).foregroundStyle(Color.hex(0xF97316))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ev.title).font(.caption).foregroundStyle(p.text).lineLimit(1)
                            Text(ev.category.label).font(.caption2).foregroundStyle(p.textDim)
                        }
                        Spacer()
                        Text(String(format: "%.0f nm", nm)).font(.caption2).foregroundStyle(p.textDim)
                    }
                }
            }
        }
        Section {} footer: {
            Text("Live METAR/TAF are not available offline. Airport Climate shows NASA POWER historical winds & density altitude; hazards are satellite-observed (NASA EONET) — not a substitute for an official weather briefing.")
                .font(.caption2).foregroundStyle(p.textDim)
        }
    }

    /// Runway = coded runway pairs (CIFP) with true headings + lengths. Surface type isn't in the data.
    @ViewBuilder private func runwayTab(_ ident: String) -> some View {
        let p = model.palette
        let pairs = RunwayGeometry.pairs(from: CIFP.runways(airport: ident))
        if pairs.isEmpty {
            Section { emptyRow("No runway data", "No coded runways for \(ident) in this cycle.") }
        } else {
            Section("Runways (\(pairs.count))") {
                ForEach(pairs) { pair in
                    HStack(spacing: 10) {
                        Image(systemName: "airplane")
                            .rotationEffect(.degrees(pair.a.trueHeadingDeg - 90)).foregroundStyle(p.accent).font(.callout)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(RunwayGeometry.label(pair.a.designator)) / \(RunwayGeometry.label(pair.b.designator))")
                                .font(.callout.weight(.semibold)).foregroundStyle(p.text)
                            Text(String(format: "%03.0f°T / %03.0f°T", pair.a.trueHeadingDeg, pair.b.trueHeadingDeg))
                                .font(.caption2).foregroundStyle(p.textDim)
                        }
                        Spacer()
                        if let l = pair.lengthFt { Text("\(l) ft").font(.caption).foregroundStyle(p.textDim) }
                    }
                }
            }
        }
    }

    /// Procedure = ForeFlight-style sub-tabs. Airport/Departure/Arrival/Approach map to plate categories
    /// (each row shows saved state + a "Map" send-to-map button + tap-to-open). Other = the misc plate
    /// charts (DVA, hot spots, takeoff/alternate minimums, LAHSO).
    @ViewBuilder private func procedureTab(_ ident: String) -> some View {
        Section {
            Picker("Procedure", selection: $procTab) {
                ForEach(ProcTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        }
        let items = Procedures.forAirport(ident).filter { $0.category == procTab.category }
        if items.isEmpty {
            Section { emptyRow("No charts", "No \(procTab.label.lowercased()) charts for \(ident) this cycle.") }
        } else {
            Section("\(items.count) chart\(items.count == 1 ? "" : "s")") {
                ForEach(items) { procedurePlateRow($0, ident: ident) }
            }
        }
    }

    /// One plate row with the inline "Map" (send-to-map) button + saved/auto-align state. Tap the name
    /// to open the full page; tap Map to overlay it on the map (downloading first if needed).
    private func procedurePlateRow(_ proc: AirportProcedure, ident: String) -> some View {
        let p = model.palette
        let cached = PlateStore.isCached(proc)
        let auto = PlateGeoref.lookup(pdf: proc.pdf) != nil
        let sending = sendingToMap.contains(proc.id)   // per-row id, not proc.pdf (siblings can share a filename)
        return HStack(spacing: 8) {
            Button { Haptics.impact(.light); plate = proc } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.richtext").font(.caption).foregroundStyle(p.accent)
                    Text(proc.name).font(.callout).foregroundStyle(p.text).lineLimit(2)
                    if auto { Image(systemName: "scope").font(.caption2).foregroundStyle(p.good) }  // auto-aligns
                    Spacer(minLength: 4)
                    Text(cached ? "SAVED" : "NOT SAVED")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(cached ? p.good : p.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { sendPlateToMap(proc, ident: ident) } label: {
                HStack(spacing: 3) {
                    if sending { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "square.on.square").font(.caption2) }
                    Text("Map").font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(p.accent.opacity(0.16)))
                .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain).disabled(sending)
            .accessibilityIdentifier("plate-send-to-map")
        }
    }

    /// Download the plate if needed, overlay it on the map, then dismiss the panel so the map shows it.
    private func sendPlateToMap(_ proc: AirportProcedure, ident: String) {
        Haptics.impact(.medium)
        if PlateStore.isCached(proc), let url = PlateStore.localURL(proc) {
            model.overlayPlate(proc, airport: ident, pdf: url); onClose(); return
        }
        sendingToMap.insert(proc.id)
        Task { @MainActor in
            let url = await PlateStore.ensureOnDisk(proc)
            sendingToMap.remove(proc.id)
            guard let url else { return }              // offline / fetch failed → leave the panel open
            model.overlayPlate(proc, airport: ident, pdf: url); onClose()
        }
    }

    /// NOTAM = honest placeholder (no offline NOTAM/TFR source bundled).
    @ViewBuilder private func notamTab(_ ident: String) -> some View {
        let p = model.palette
        Section {
            VStack(spacing: 10) {
                Image(systemName: "bell.slash").font(.system(size: 30)).foregroundStyle(p.textDim.opacity(0.7))
                Text("NOTAMs need a connection").font(.callout).foregroundStyle(p.text)
                Text("Offline NOTAM/TFR data isn't bundled yet. Check an official source before flight.")
                    .font(.caption2).foregroundStyle(p.textDim).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private func emptyRow(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(model.palette.text)
            Text(sub).font(.caption2).foregroundStyle(model.palette.textDim)
        }
    }

    /// Historical winds + density altitude for an airport (NASA POWER climatology) — one row that
    /// opens the Airport Climate sheet. Fetched on first open, cached forever.
    private func climateSection(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        return Section("Climate") {
            Button {
                Haptics.impact(.light)
                climateTarget = ClimateTarget(ident: o.ident, coord: o.coord)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wind").foregroundStyle(p.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Airport Climate").font(.callout).foregroundStyle(p.text)
                        Text("Historical winds, runways & density altitude")
                            .font(.caption2).foregroundStyle(p.textDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                }
            }
            .buttonStyle(.plain).accessibilityIdentifier("airport-climate")
        }
    }

    private func displayName(_ o: IdentifiedObject) -> String? {
        switch o.kind {
        case .airport:   return NavMeta.airport(o.ident)?.name
        case .vor:       return NavMeta.navaid(o.ident).flatMap { m in [m.name, m.typeLabel].compactMap { $0 }.joined(separator: " · ") }
        case .airspace:  return o.airspace?.name.capitalized(with: .current)
        case .traffic:   return "Live traffic"
        case .fix:       return "Reporting point / RNAV fix"
        case .userPoint: return "Custom point on the map"
        case .hazard:    return "Satellite-observed — NASA EONET"
        }
    }

    @ViewBuilder private func infoSection(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        Section("Details") {
            switch o.kind {
            case .airport:
                if let e = NavMeta.airport(o.ident)?.elevationFt { KV("Elevation", "\(e) ft") }
                KV("Position", coordText(o.coord))
                if let ctx = BundledAirportContextSource.lookup(o.ident) {
                    if !ctx.runways.isEmpty { KV("Runways", ctx.runways.joined(separator: " · ")) }
                    ForEach(freqRows(ctx.frequencies), id: \.label) { row in KV(row.label, row.value) }
                }
                bearingRow(o.coord)
            case .vor:
                if let m = NavMeta.navaid(o.ident) {
                    KV("Type", m.typeLabel)
                    if let f = m.frequencyText { KV("Frequency", f) }
                }
                KV("Position", coordText(o.coord))
                bearingRow(o.coord)
            case .fix, .userPoint:
                KV("Position", coordText(o.coord))
                bearingRow(o.coord)
            case .airspace:
                if let a = o.airspace {
                    KV("Type", Self.airspaceTypeName(a.cls))
                    KV("Floor", Self.altText(a.floorFt))
                    KV("Ceiling", Self.altText(a.ceilingFt))
                }
            case .traffic:
                if let ac = model.aircraft.first(where: { ($0.label ?? $0.callsign) == o.ident }) {
                    if let alt = ac.altBaroFt { KV("Altitude", "\(alt) ft") }
                    if let gs = ac.gsKt { KV("Ground speed", "\(Int(gs)) kt") }
                    if let t = ac.trackDeg { KV("Track", String(format: "%03.0f°T", t)) }
                }
                KV("Position", coordText(o.coord))
            case .hazard:
                if let ev = o.hazard {
                    KV("Category", ev.category.label)
                    if ev.updatedAt > .distantPast {
                        KV("Last updated", Self.relative.localizedString(for: ev.updatedAt, relativeTo: Date()))
                    }
                }
                KV("Position", coordText(o.coord))
                bearingRow(o.coord)
            }
        }
        .foregroundStyle(p.text)
    }

    /// EONET events are satellite observations — awareness context, not a briefing product.
    private var hazardFooter: some View {
        Section {
        } footer: {
            Text("Satellite-observed by NASA EONET. Not a substitute for official NOTAMs, TFRs, or weather briefings.")
                .font(.caption2)
                .foregroundStyle(model.palette.textDim)
        }
    }

    private static let relative = RelativeDateTimeFormatter()

    /// Bearing + distance FROM ownship (Stratux fix) TO the object — omitted when there's no fix.
    @ViewBuilder private func bearingRow(_ c: Coord) -> some View {
        if let own = model.stratuxGPS?.coordinate {
            KV("From you", String(format: "%03.0f°T · %.0f nm", Geo.bearing(own, c), Geo.nmBetween(own, c)))
        }
    }

    // MARK: Actions

    @ViewBuilder private func actionSection(_ o: IdentifiedObject) -> some View {
        if o.kind.isRoutable {
            Section("Flight plan") {
                actionRow("Add to route", "plus.circle") { model.addToRoute(o.ident); finish() }
                actionRow("Insert in order", "arrow.turn.down.right") {
                    let resolved = RouteResolver.resolve(model.flightPlan?.fullRoute ?? []).points
                    model.insertInRoute(o.ident, at: o.coord, resolved: resolved); finish()
                }
                actionRow("Direct-To", "location.north.line") { confirmDirect = o }
                if o.kind == .airport {
                    actionRow("Set as departure", "airplane.departure") { model.setDeparture(o.ident); finish() }
                    actionRow("Set as destination", "airplane.arrival") { model.setDestination(o.ident); finish() }
                }
                if o.onRoute {
                    actionRow("Remove from route", "minus.circle", role: .destructive) { model.removeFromRoute(o.ident); finish() }
                }
            }
        }
    }

    private func actionRow(_ label: String, _ icon: String, role: ButtonRole? = nil, _ act: @escaping () -> Void) -> some View {
        Button(role: role) { Haptics.impact(.medium); act() } label: {
            Label(label, systemImage: icon).font(.callout)
        }
    }

    private func finish() { onCommit(); onClose() }

    // MARK: Bits

    private func coordText(_ c: Coord) -> String { String(format: "%.4f, %.4f", c.lat, c.lon) }

    /// Friendly name for an airspace class/type code (class airspace + special use + TFR).
    static func airspaceTypeName(_ cls: String) -> String {
        switch cls {
        case "B", "C", "D": return "Class \(cls) airspace"
        case "R":   return "Restricted Area"
        case "P":   return "Prohibited Area"
        case "W":   return "Warning Area"
        case "A":   return "Alert Area"
        case "MOA": return "Military Operations Area"
        case "TFR": return "National Defense TFR"
        default:    return "Airspace"
        }
    }
    /// Feet → a readable floor/ceiling (Surface / Unlimited / FLxxx / value).
    static func altText(_ ft: Int?) -> String {
        guard let ft else { return "—" }
        if ft >= 99_999 { return "Unlimited" }
        if ft <= 0 { return "Surface" }
        if ft >= 18_000 { return "FL\(ft / 100)" }
        return "\(ft) ft"
    }

    private struct FreqRow { let label: String; let value: String }
    private func freqRows(_ freqs: [String: [Double]]) -> [FreqRow] {
        let order = ["ATIS", "AWOS", "ASOS", "CTAF", "UNIC", "CLD", "GND", "TWR", "APP", "DEP", "RDO", "GTE", "ARCA", "ATC"]
        let names = ["TWR": "Tower", "GND": "Ground", "APP": "Approach", "DEP": "Departure", "CLD": "Clearance",
                     "ATIS": "ATIS", "CTAF": "CTAF", "UNIC": "UNICOM", "RDO": "Radio", "GTE": "Gate",
                     "ARCA": "Area", "AWOS": "AWOS", "ASOS": "ASOS", "ATC": "ATC"]
        return freqs.keys
            .sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .compactMap { key in
                let vals = freqs[key]!.sorted().map { String(format: "%.3f", $0) }.joined(separator: ", ")
                return vals.isEmpty ? nil : FreqRow(label: names[key] ?? key, value: vals)
            }
    }

    private func badge(_ kind: MapObjectKind, large: Bool = false) -> some View {
        let d: CGFloat = large ? 34 : 26
        return ZStack {
            Circle().fill(kindColor(kind)).frame(width: d, height: d)
            Image(systemName: kindIcon(kind)).font(.system(size: large ? 15 : 12, weight: .bold)).foregroundStyle(.white)
        }
    }

    private func kindColor(_ kind: MapObjectKind) -> Color {
        switch kind {
        case .airport:   return .hex(0xE879F9)
        case .vor:       return .hex(0x34D399)
        case .fix:       return .hex(0x60A5FA)
        case .airspace:  return .hex(0x2F6FED)
        case .traffic:   return .orange
        case .userPoint: return .hex(0xFBBF24)
        case .hazard:    return .hex(0xF97316)
        }
    }

    private func kindIcon(_ kind: MapObjectKind) -> String {
        switch kind {
        case .airport:   return "airplane"
        case .vor:       return "hexagon"
        case .fix:       return "triangle"
        case .airspace:  return "circle.dashed"
        case .traffic:   return "airplane"
        case .userPoint: return "mappin"
        case .hazard:    return "flame"
        }
    }
}
