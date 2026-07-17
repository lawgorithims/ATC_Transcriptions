import SwiftUI

/// Tap-to-identify content: what the pilot tapped, its details, and the route actions (add /
/// insert-in-order / Direct-To / set endpoint / remove). Chromeless so it can be hosted either in the
/// home-map **side panel** (a floating widget on regular width) or in the compact **bottom sheet**
/// (`MapObjectSheet`). When a tap hits several things it opens on a chooser, then drills in. Read-only
/// for airspace and traffic.
struct MapObjectView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var metars: MetarStore
    @EnvironmentObject var forecasts: ForecastStore
    @EnvironmentObject var tafs: TafStore
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
    @State private var wxTab: WxTab = .current
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

    /// Weather sub-tabs: live observations (METAR/TAF — not bundled yet) vs. NASA POWER historical
    /// climate (opens the charts). Split so the "current" gap is honest and the historical data is
    /// clearly separate, not mistaken for now.
    private enum WxTab: String, CaseIterable, Identifiable {
        case current, taf, forecast, historical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .current:    return "METAR"
            case .taf:        return "TAF"
            case .forecast:   return "7-Day"
            case .historical: return "History"
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
        case .tfr:       return o.tfr?.type.label ?? "TFR"
        case .airway:    return "Enroute airway"
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
            if o.kind == .tfr { tfrFooter }
            actionSection(o)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Airport card (ForeFlight-style tabs)

    @ViewBuilder private func airportCard(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        let summary = AirportSummary.make(o.ident)
        let metar = metars.metar(o.ident)
        List {
            Section {
                // ForeFlight-style header: the airport-diagram thumbnail (not a generic circle) plus the
                // critical pilot data — flight category, latest weather, key freqs, procedures, altitudes.
                HStack(alignment: .top, spacing: 12) {
                    // Tapping the diagram opens the full plate in the Plates tab (same hand-off as the
                    // Info-tab thumbnail) — the header image is the thing pilots try to tap first.
                    Button {
                        if let apd = Procedures.forAirport(o.ident).first(where: { $0.code == "APD" }) {
                            Haptics.impact(.light)
                            openDiagramInPlatesTab(apd, ident: o.ident)
                        }
                    } label: {
                        AirportDiagramImage(ident: o.ident, height: 96).environmentObject(model)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("airport-header-diagram")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title(o))
                                .font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(p.text)
                            FlightCategoryChip(metar: metar)
                        }
                        if let name = displayName(o) {
                            Text(name).font(.caption).foregroundStyle(p.textDim).lineLimit(1)
                        }
                        Text(metar?.summary ?? "Latest weather unavailable")
                            .font(.caption).foregroundStyle(metar == nil ? p.textDim : p.text).lineLimit(2)
                        if !summary.keyFreqs.isEmpty {
                            Text(summary.keyFreqs.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  "))
                                .font(.caption2.monospaced()).foregroundStyle(p.accent).lineLimit(1)
                        }
                        Text(airportDetailLine(summary))
                            .font(.caption2).foregroundStyle(p.textDim).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .onAppear {
                    metars.ensure([o.ident])             // header + Weather tab share the observation
                    model.noteAirportViewed(o.ident)     // feeds the Airports tab's "Recent" section
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
            case .info:
                // Diagram FIRST so it's visible the moment the card opens (the compact card otherwise
                // buries it below the Details rows, where the pilot never scrolls to find it).
                if o.kind == .airport {
                    AirportDiagramThumbnail(ident: o.ident) { apd in openDiagramInPlatesTab(apd, ident: o.ident) }
                }
                infoSection(o)
            case .weather:   weatherTab(o)
            case .runway:    runwayTab(o.ident)
            case .procedure: procedureTab(o.ident)
            case .notam:     notamTab(o.ident)
            }
        }
        .scrollContentBackground(.hidden)
        // Flush layout (per feedback): kill the tall default gaps between the header caption, the
        // Info/Weather/… tab picker, and each tab's first group.
        .listSectionSpacing(6)
    }

    /// Procedures · field elevation · pattern altitude — the header's bottom caption line.
    private func airportDetailLine(_ s: AirportSummary) -> String {
        var parts: [String] = []
        if !s.procedureTypes.isEmpty { parts.append(s.procedureTypes.joined(separator: " · ")) }
        if let e = s.elevationFt { parts.append("Field elevation \(e.grouped)′") }
        if let tpa = s.patternAltFt { parts.append("Pattern altitude \(tpa.grouped)′ (est)") }
        return parts.isEmpty ? "No published procedures" : parts.joined(separator: "   ·   ")
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
        .buttonStyle(.plainHaptic)
    }

    // MARK: Airport-card tabs

    /// Weather = a Current / Historical split. Current holds live observations (METAR/TAF, not bundled
    /// yet — stated honestly) plus nearby EONET satellite hazards; Historical opens the NASA POWER
    /// climate charts. Nothing live is faked.
    @ViewBuilder private func weatherTab(_ o: IdentifiedObject) -> some View {
        Section {
            Picker("Weather", selection: $wxTab) {
                ForEach(WxTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .accessibilityIdentifier("weather-subtabs")
        }
        switch wxTab {
        case .current:    currentWxSection(o)
        case .taf:        tafSection(o)
        case .forecast:   forecastSection(o)
        case .historical: historicalWxSection(o)
        }
    }

    /// Current observations: the LIVE METAR (same MetarStore the Airports tab uses) — category chip,
    /// decoded summary, and the raw observation — plus nearby EONET satellite-observed hazards.
    @ViewBuilder private func currentWxSection(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        Section("Current observations") {
            if let m = metars.metar(o.ident) {
                HStack(spacing: 10) {
                    FlightCategoryChip(metar: m)
                    Text(m.summary).font(.callout).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("weather-current-metar")
                if let raw = m.rawOb {
                    Text(raw).font(.caption2.monospaced()).foregroundStyle(p.textDim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let t = m.obsEpoch {
                    KV("Observed", Self.relative.localizedString(for: Date(timeIntervalSince1970: TimeInterval(t)), relativeTo: Date()))
                }
            } else {
                switch metars.state(o.ident) {
                case .failed:
                    Label("Weather service unavailable — reopen to retry.", systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(p.textDim)
                        .accessibilityIdentifier("weather-current-failed")
                case .noReport:
                    Label("No current METAR reported at \(o.ident).", systemImage: "cloud")
                        .font(.callout).foregroundStyle(p.textDim)
                        .accessibilityIdentifier("weather-current-none")
                default:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Fetching the latest METAR…").font(.callout).foregroundStyle(p.textDim)
                    }
                    .accessibilityIdentifier("weather-current-loading")
                }
            }
        }
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
            Text("METAR from aviationweather.gov (requires a connection). Hazards are satellite-observed (NASA EONET). Neither substitutes for an official weather briefing.")
                .font(.caption2).foregroundStyle(p.textDim)
        }
    }

    /// TAF (Terminal Aerodrome Forecast) — the airport's own forecast: the raw TAF plus each decoded
    /// forecast period (validity, wind, visibility, sky, weather). From aviationweather.gov.
    @ViewBuilder private func tafSection(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        Section("Terminal Aerodrome Forecast") {
            if let taf = tafs.taf(o.ident) {
                if let raw = taf.rawText, !raw.isEmpty {
                    Text(raw).font(.caption2.monospaced()).foregroundStyle(p.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("weather-taf-raw")
                }
                if let issued = taf.issued {
                    KV("Issued", Self.relative.localizedString(for: issued, relativeTo: Date()))
                }
            } else {
                switch tafs.state(o.ident) {
                case .failed:
                    Label("TAF service unavailable — reopen to retry.", systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(p.textDim)
                case .noReport:
                    Label("No TAF issued for \(o.ident) (not all fields publish one).", systemImage: "cloud")
                        .font(.callout).foregroundStyle(p.textDim)
                default:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Fetching the TAF…").font(.callout).foregroundStyle(p.textDim)
                    }
                }
            }
        }
        if let periods = tafs.taf(o.ident)?.periods, !periods.isEmpty {
            Section("Forecast periods") {
                ForEach(Array(periods.enumerated()), id: \.offset) { _, per in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(per.header).font(.caption.weight(.semibold).monospaced()).foregroundStyle(p.accent)
                        Text(per.summary).font(.caption2).foregroundStyle(p.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        Section {} footer: {
            Text("TAF from aviationweather.gov — a forecast for the airport's immediate vicinity, valid 24–30 h. Not a substitute for an official briefing.")
                .font(.caption2).foregroundStyle(p.textDim)
        }
        .onAppear { tafs.ensure([o.ident]) }
    }

    /// NWS 7-day outlook — day/night periods with temp, wind, and the short forecast (its own sub-tab).
    @ViewBuilder private func forecastSection(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        Section("7-day outlook (NWS)") {
            if let periods = forecasts.forecast(o.ident), !periods.isEmpty {
                ForEach(Array(periods.enumerated()), id: \.offset) { _, per in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(per.name).font(.caption.weight(.semibold)).foregroundStyle(p.text)
                            Text([per.shortForecast, per.windText.isEmpty ? nil : "Wind \(per.windText)"]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Text(per.tempText)
                            .font(.callout.weight(.semibold).monospaced())
                            .foregroundStyle(per.isDaytime == true ? p.warn : p.accent)
                    }
                }
            } else {
                switch forecasts.state(o.ident) {
                case .failed:
                    Label("Outlook unavailable — reopen to retry.", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(p.textDim)
                case .empty:
                    Label("No NWS outlook for this location.", systemImage: "calendar")
                        .font(.caption).foregroundStyle(p.textDim)
                default:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Fetching the outlook…").font(.caption).foregroundStyle(p.textDim)
                    }
                }
            }
        }
        .onAppear { forecasts.ensure(o.ident, coord: o.coord) }
        Section {} footer: {
            Text("7-day outlook from the U.S. National Weather Service (api.weather.gov). Planning context, not an aviation forecast — always check the TAF and an official briefing.")
                .font(.caption2).foregroundStyle(p.textDim)
        }
    }

    /// Historical weather: opens the NASA POWER Airport Climate charts (windrose, best time of day,
    /// seasonal winds, density altitude) — decades of normals, clearly not current conditions.
    @ViewBuilder private func historicalWxSection(_ o: IdentifiedObject) -> some View {
        let p = model.palette
        climateSection(o)
        Section {} footer: {
            Text("NASA POWER historical winds, seasonal normals & density altitude (decades of climatology) — planning context, not current weather. Always check current METAR/TAF.")
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
            .buttonStyle(.plainHaptic)
            // Send-to-map is georef-only (overlayPlate refuses plates without one): the Map button
            // simply isn't offered on schematic plates (SIDs/STARs/minimums) — the scope icon above
            // already marks which plates auto-align.
            if auto {
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
                .buttonStyle(.plainHaptic).disabled(sending)
                .accessibilityIdentifier("plate-send-to-map")
            }
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
                        Text("Windrose · best time of day · seasonal winds · density altitude")
                            .font(.caption2).foregroundStyle(p.textDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                }
            }
            .buttonStyle(.plainHaptic).accessibilityIdentifier("airport-climate")
        }
    }

    private func displayName(_ o: IdentifiedObject) -> String? {
        switch o.kind {
        case .airport:   return NavMeta.airport(o.ident)?.name
        case .vor:       return NavMeta.navaid(o.ident).flatMap { m in [m.name, m.typeLabel].compactMap { $0 }.joined(separator: " · ") }
        // Class B/C/D names are airport-derived words ("BOSTON" → "Boston"); SUA names are FAA
        // identifiers/acronyms ("ABEL EAST MOA", "W-102H") that .capitalized would mangle — keep verbatim.
        case .airspace:  return o.airspace.map { ["B", "C", "D"].contains($0.cls) ? $0.name.capitalized(with: .current) : $0.name }
        case .traffic:   return "Live traffic"
        case .fix:       return "Reporting point / RNAV fix"
        case .userPoint: return "Custom point on the map"
        case .hazard:    return "Satellite-observed — NASA EONET"
        case .tfr:       return "Temporary Flight Restriction — FAA"
        case .airway:    return "Enroute airway — file it between two of its fixes"
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
                    if let mag = ev.magnitudeText { KV(ev.magnitudeLabel, mag) }
                    if ev.updatedAt > .distantPast {
                        KV("Last updated", Self.relative.localizedString(for: ev.updatedAt, relativeTo: Date()))
                    }
                }
                KV("Position", coordText(o.coord))
                bearingRow(o.coord)
            case .tfr:
                if let t = o.tfr {
                    HStack(spacing: 8) {
                        Text(t.type.label).font(.headline).foregroundStyle(p.text)
                        Spacer(minLength: 0)
                        Self.tfrStatusChip(t)
                    }
                    KV("Floor", Self.altText(t.floorFt))
                    KV("Ceiling", Self.altText(t.ceilingFt))
                    if let eff = t.effective { KV("Effective", Self.tfrTime(eff)) }
                    if let exp = t.expires { KV("Expires", Self.tfrTime(exp)) }
                    if let fac = t.facility { KV("Center", [fac, t.state].compactMap { $0 }.joined(separator: " · ")) }
                    KV("NOTAM", t.id)
                    if !t.title.isEmpty {
                        Text(t.title).font(.caption).foregroundStyle(p.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text("Awareness only — confirm against an official briefing.")
                        .font(.caption2).foregroundStyle(p.textDim)
                }
                bearingRow(o.coord)
            case .airway:
                KV("Route", o.ident)
                KV("Kind", Self.airwayKindName(o.ident))
                // Area-scoped: the East Coast V1 and the Hawaii V1 are different airways with different
                // MEAs — look up the one that was actually tapped (defaults to USA for older tap paths).
                let alt = Airways.altitudes(of: o.ident, area: o.airwayArea ?? "USA")
                if let lo = alt.meaLow {
                    // MEA varies by segment — show the coded range across the whole airway.
                    KV("Minimum enroute alt", alt.meaHigh.map { hi in
                        hi == lo ? "\(lo.grouped)′" : "\(lo.grouped)–\(hi.grouped)′ (varies by segment)"
                    } ?? "\(lo.grouped)′")
                }
                if let maa = alt.maa { KV("Maximum authorized", Self.altText(maa)) }
                Text("To file it, type the airway between two of its fixes in the route — e.g. “GDM \(o.ident) ORW”.")
                    .font(.caption).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(p.text)
    }

    /// Human name for an airway ident's class: V = low-altitude Victor, J = high-altitude Jet,
    /// T/Q = RNAV (low/high).
    static func airwayKindName(_ ident: String) -> String {
        switch ident.first {
        case "V": return "Victor airway (low altitude)"
        case "J": return "Jet route (high altitude)"
        case "Q": return "RNAV Q-route (high altitude)"
        case "T": return "RNAV T-route (low altitude)"
        default:  return "Enroute airway"
        }
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

    /// TFRs are awareness context pulled from tfr.faa.gov — always confirm against an official briefing.
    private var tfrFooter: some View {
        Section {
        } footer: {
            let stale = model.tfrsUpdatedAt.map { Self.relative.localizedString(for: $0, relativeTo: Date()) }
            Text("FAA TFR feed\(stale.map { ", updated \($0)" } ?? ""). Boundaries are approximate — confirm against the official NOTAM before flight.")
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

    /// Open the tapped airport's diagram full-page in the Plates tab (the same hand-off `--preview-plate-full`
    /// uses): pin the airport, queue the plate for the viewer, switch tabs, and dismiss this card.
    private func openDiagramInPlatesTab(_ apd: AirportProcedure, ident: String) {
        model.platesAirport = ident
        model.previewPlatePdf = apd.pdf
        model.selectedTab = .plates
        onClose()
    }

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

    /// Absolute TFR time in UTC ("Jul 17, 04:39Z") — NOTAM windows are always published in Zulu.
    private static let tfrDF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func tfrTime(_ d: Date) -> String { "\(tfrDF.string(from: d))Z" }

    /// Active / upcoming / expired chip for a TFR, from its effective window.
    @ViewBuilder static func tfrStatusChip(_ t: TFR, now: Date = Date()) -> some View {
        let (text, color): (String, Color) = {
            if let e = t.effective, now < e { return ("Upcoming", .hex(0xF5A623)) }
            if let x = t.expires, now > x { return ("Expired", .hex(0x8E8E93)) }
            return ("Active now", .hex(0xF71433))
        }()
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
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
        case .tfr:       return .hex(0xF71433)
        case .airway:    return .hex(0x6B94DB)
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
        case .tfr:       return "exclamationmark.octagon"
        case .airway:    return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

// MARK: - Airport-diagram thumbnail

/// The airport-diagram (APD) plate rendered as a tappable thumbnail in the tapped-airport card's Info tab.
/// Tapping opens that diagram full-page in the Plates tab. Renders nothing when the field publishes no
/// APD chart; downloads on demand and rasterises off-main, so it never blocks the card from appearing.
struct AirportDiagramThumbnail: View {
    @EnvironmentObject var model: AppModel
    let ident: String
    var onOpen: (AirportProcedure) -> Void

    @State private var image: UIImage?
    @State private var phase: Phase = .loading
    private enum Phase { case loading, ready, failed }

    private var diagram: AirportProcedure? { Procedures.forAirport(ident).first { $0.code == "APD" } }

    var body: some View {
        if let apd = diagram {
            Section("Airport diagram") {
                Button { Haptics.impact(.light); onOpen(apd) } label: { thumb }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("airport-diagram-thumb")
            }
            .task(id: ident) { await load(apd) }
        }
    }

    private var thumb: some View {
        let p = model.palette
        return Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity).frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            } else {
                HStack(spacing: 8) {
                    if phase == .loading { ProgressView() }
                    Image(systemName: phase == .failed ? "exclamationmark.triangle" : "doc.richtext")
                        .foregroundStyle(p.textDim)
                    Text(phase == .failed ? "Diagram unavailable offline" : "Loading airport diagram…")
                        .font(.caption).foregroundStyle(p.textDim)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            }
        }
        .contentShape(Rectangle())
    }

    private func load(_ apd: AirportProcedure) async {
        image = nil; phase = .loading
        guard let url = await PlateStore.ensureOnDisk(apd) else { phase = .failed; return }
        let rendered = await Task.detached(priority: .userInitiated) {
            PlateImageRenderer.firstPageImage(pdfURL: url, maxDimension: 900)
        }.value
        guard !Task.isCancelled else { return }            // a newer airport was tapped
        if let rendered { image = rendered; phase = .ready } else { phase = .failed }
    }
}
