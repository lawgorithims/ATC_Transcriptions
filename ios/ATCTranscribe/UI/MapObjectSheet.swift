import SwiftUI

/// The tap-to-identify sheet: what the pilot tapped on the map, its details, and the route actions
/// (add / insert-in-order / Direct-To / set endpoint / remove). When a tap hits several things it opens
/// on a chooser, then drills into the picked object. Read-only for airspace and traffic.
struct MapObjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let result: MapProbeResult
    let resolved: [ResolvedLeg]        // current resolved route, for insert-in-order
    let onCommit: () -> Void           // re-resolve the route + prefetch after an edit

    @State private var picked: IdentifiedObject?
    @State private var confirmDirect: IdentifiedObject?

    /// The object to detail: the pick, else the sole probe hit (a multi-hit probe shows the chooser).
    private var object: IdentifiedObject? { picked ?? (result.objects.count == 1 ? result.objects.first : nil) }

    var body: some View {
        NavigationStack {
            Group {
                if let obj = object { detail(obj) } else { chooser }
            }
            .navigationTitle(object.map(title) ?? "What's here?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .alert("Go direct to \(confirmDirect?.ident ?? "")?", isPresented: directBinding) {
            Button("Go Direct", role: .destructive) { if let o = confirmDirect { model.directTo(o.ident); finish() } }
            Button("Cancel", role: .cancel) { confirmDirect = nil }
        } message: {
            Text("Sets \(confirmDirect?.ident ?? "") as your destination and clears intermediate waypoints. Present-position sequencing comes later.")
        }
    }

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
            actionSection(o)
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

    private func finish() { onCommit(); dismiss() }

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
