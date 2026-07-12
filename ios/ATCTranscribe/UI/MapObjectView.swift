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
            PlateViewer(procedure: proc, airport: plateAirport, palette: model.palette,
                        onSendToMap: { url in
                            model.overlayPlate(proc, airport: plateAirport, pdf: url)
                            plate = nil; onClose()   // dismiss viewer + panel so the map (with the plate) is visible
                        },
                        onClose: { plate = nil })
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
        case .airspace:  return o.airspace.map { "Class \($0.cls)" }
        case .traffic:   return "Traffic"
        case .userPoint: return "Dropped point"
        }
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ o: IdentifiedObject) -> some View {
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
            if o.kind == .airport { platesSection(o.ident) }
            if o.kind == .airport { proceduresSection(o.ident) }
            actionSection(o)
        }
        .scrollContentBackground(.hidden)
    }

    /// The FAA terminal-procedure PLATES (the actual charts, from the bundled d-TPP index) — the
    /// approach/departure/arrival PDFs with frequencies, altitudes, minimums, and profiles the coded
    /// waypoints can't show. Tapping one opens the full plate. Grouped by category.
    @ViewBuilder private func platesSection(_ ident: String) -> some View {
        let p = model.palette
        let plates = Procedures.forAirport(ident)
        let groups: [(AirportProcedure.Category, String)] = [
            (.approach, "Approach plates"), (.departure, "Departures (DPs)"),
            (.arrival, "Arrivals (STARs)"), (.diagram, "Airport diagram"),
        ]
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
                                if PlateStore.isCached(proc) {
                                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(p.good)
                                }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("plate-row")
                    }
                }
            }
        }
    }

    /// Coded procedures (CIFP) for an airport, grouped by kind; tapping one draws it on the map as a
    /// georeferenced overlay. One row per procedure identifier (transitions collapsed).
    @ViewBuilder private func proceduresSection(_ ident: String) -> some View {
        let procs = CIFP.procedures(airport: ident)
        let groups: [(String, String)] = [("IAP", "Approaches"), ("SID", "Departures"), ("STAR", "Arrivals")]
        ForEach(groups, id: \.0) { kind, heading in
            let items = distinct(procs.filter { $0.kind == kind })
            if !items.isEmpty {
                Section("\(heading) (\(items.count))") {
                    ForEach(items) { proc in procedureRow(proc) }
                }
            }
        }
    }

    private func procedureRow(_ proc: CIFPProcedure) -> some View {
        let p = model.palette
        return HStack(spacing: 8) {
            // Tap the name to PREVIEW it (a non-committal cyan overlay)…
            Button {
                Haptics.impact(.light); model.previewedProcedure = proc; onClose()
            } label: {
                HStack(spacing: 6) {
                    Text(proc.name).font(.callout).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "eye").font(.caption2).foregroundStyle(p.textDim)
                }
            }
            .buttonStyle(.plain)
            // …or LOAD it into the flight plan (its legs join the active route + ground the corrector).
            Button {
                Haptics.impact(.medium); model.loadProcedure(proc); onClose()
            } label: {
                Text("Load").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.plain).accessibilityIdentifier("load-procedure")
        }
    }

    /// One entry per procedure identifier (the FAA lists each enroute transition as its own record).
    private func distinct(_ procs: [CIFPProcedure]) -> [CIFPProcedure] {
        var seen = Set<String>()
        return procs.filter { seen.insert($0.ident).inserted }
    }

    private func displayName(_ o: IdentifiedObject) -> String? {
        switch o.kind {
        case .airport:   return NavMeta.airport(o.ident)?.name
        case .vor:       return NavMeta.navaid(o.ident).flatMap { m in [m.name, m.typeLabel].compactMap { $0 }.joined(separator: " · ") }
        case .airspace:  return o.airspace?.name.capitalized(with: .current)
        case .traffic:   return "Live traffic"
        case .fix:       return "Reporting point / RNAV fix"
        case .userPoint: return "Custom point on the map"
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
                    KV("Class", "Class \(a.cls)")
                    KV("Floor", a.floorFt.map { $0 == 0 ? "Surface" : "\($0) ft" } ?? "—")
                    KV("Ceiling", a.ceilingFt.map { "\($0) ft" } ?? "—")
                }
            case .traffic:
                if let ac = model.aircraft.first(where: { ($0.label ?? $0.callsign) == o.ident }) {
                    if let alt = ac.altBaroFt { KV("Altitude", "\(alt) ft") }
                    if let gs = ac.gsKt { KV("Ground speed", "\(Int(gs)) kt") }
                    if let t = ac.trackDeg { KV("Track", String(format: "%03.0f°T", t)) }
                }
                KV("Position", coordText(o.coord))
            }
        }
        .foregroundStyle(p.text)
    }

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
        }
    }
}
