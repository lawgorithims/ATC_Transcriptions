import SwiftUI
import PDFKit

/// One marker (ownship or a traffic target) to draw on a georeferenced plate.
struct PlateTraffic { let coord: Coord; let track: Double? }

/// A PDF annotation that draws an ownship dot or a traffic chevron in PAGE space, so PDFKit pans/zooms
/// it with the plate for free. Ownship = blue dot; traffic = orange chevron rotated to its track.
final class PlateMarkerAnnotation: PDFAnnotation {
    enum Kind { case ownship, traffic }
    private let kind: Kind
    private let headingDeg: Double?

    init(pagePoint: CGPoint, kind: Kind, heading: Double?) {
        self.kind = kind; self.headingDeg = heading
        let r: CGFloat = 13
        super.init(bounds: CGRect(x: pagePoint.x - r, y: pagePoint.y - r, width: 2 * r, height: 2 * r),
                   forType: .stamp, withProperties: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = min(bounds.width, bounds.height) * 0.42
        context.saveGState()
        switch kind {
        case .ownship:
            context.setFillColor(UIColor.systemBlue.cgColor)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(1.6)
            context.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.drawPath(using: .fillStroke)
        case .traffic:
            context.translateBy(x: c.x, y: c.y)
            // Page space is y-up (north = +y). Heading is clockwise-from-north → rotate by -heading.
            if let h = headingDeg { context.rotate(by: -CGFloat(h) * .pi / 180) }
            let s = r
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: s))               // nose (north at 0°)
            context.addLine(to: CGPoint(x: -s * 0.72, y: -s))
            context.addLine(to: CGPoint(x: 0, y: -s * 0.45))
            context.addLine(to: CGPoint(x: s * 0.72, y: -s))
            context.closePath()
            context.setFillColor(UIColor.systemOrange.cgColor)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(0.8)
            context.drawPath(using: .fillStroke)
        }
        context.restoreGState()
    }
}

/// Renders a PDF (an FAA terminal-procedure plate) with PDFKit — pinch-zoom, scroll, native. When a
/// georeference is supplied and `showTraffic` is on, plots ownship + ADS-B traffic on the page.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    var georef: PlateGeorefEntry? = nil
    var ownship: Coord? = nil
    var traffic: [PlateTraffic] = []
    var showTraffic: Bool = false

    func makeCoordinator() -> State { State() }
    final class State { var loadedURL: URL?; var signature = ""; var markers: [PDFAnnotation] = [] }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true                       // fit-to-width, then free pinch-zoom
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .black
        v.minScaleFactor = 0.2
        v.maxScaleFactor = 8
        v.document = PDFDocument(url: url)
        context.coordinator.loadedURL = url
        applyMarkers(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if context.coordinator.loadedURL != url {
            v.document = PDFDocument(url: url)
            context.coordinator.loadedURL = url
            context.coordinator.signature = ""; context.coordinator.markers = []
        }
        applyMarkers(v, context.coordinator)
    }

    /// Rebuild the ownship/traffic annotations only when they actually moved (signature guard) — the
    /// live-traffic feed re-evaluates the SwiftUI view a few times a second and we don't want to churn
    /// the PDF each time.
    private func applyMarkers(_ v: PDFView, _ co: State) {
        guard let page = v.document?.page(at: 0) else { return }
        let active = showTraffic && georef != nil
        let sig = signature(active: active)
        if sig == co.signature { return }
        co.signature = sig
        for a in co.markers { page.removeAnnotation(a) }
        co.markers = []
        guard active, let g = georef else { return }
        let size = page.bounds(for: .mediaBox).size
        if let own = ownship, let pt = g.pagePoint(lat: own.lat, lon: own.lon, pageSize: size) {
            let a = PlateMarkerAnnotation(pagePoint: pt, kind: .ownship, heading: nil)
            page.addAnnotation(a); co.markers.append(a)
        }
        var drawn = 0
        for t in traffic where drawn < 200 {                    // bounded
            guard let pt = g.pagePoint(lat: t.coord.lat, lon: t.coord.lon, pageSize: size) else { continue }
            let a = PlateMarkerAnnotation(pagePoint: pt, kind: .traffic, heading: t.track)
            page.addAnnotation(a); co.markers.append(a); drawn += 1
        }
    }

    private func signature(active: Bool) -> String {
        guard active else { return "off" }
        func r(_ d: Double) -> Int { Int((d * 5000).rounded()) }   // ~0.0002° buckets
        var s = "on|"
        if let o = ownship { s += "\(r(o.lat)),\(r(o.lon))" }
        s += "|"
        for t in traffic.prefix(200) { s += "\(r(t.coord.lat)),\(r(t.coord.lon));" }
        return s
    }
}

/// Full-screen viewer for one approach/departure/arrival plate. Loads from the offline `PlateStore`
/// cache, downloading once if needed (with a spinner) and degrading to an offline notice if it isn't
/// cached and there's no signal. `onSendToMap` (when provided) offers the "overlay on the map" action.
/// For a georeferenced plate it can also plot the ownship position + ADS-B traffic on the chart.
struct PlateViewer: View {
    let procedure: AirportProcedure
    let airport: String
    let palette: Palette
    @ObservedObject var deviceLocation: DeviceLocation      // observed directly (nested-observable, see C2)
    /// Observed directly for the same reason: a change inside `AppModel.minima` does not redraw a view
    /// that only observes `AppModel`, so the Minima button would never appear once the parse finished.
    @ObservedObject var minimaStore: MinimaStore
    var onSendToMap: ((URL) -> Void)? = nil
    var onClose: () -> Void

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var metars: MetarStore
    @State private var url: URL?
    @State private var loading = true
    @State private var showOverlay = true                  // show ownship/traffic by default on a georef'd plate
    @State private var showMinima = false
    /// The plate FLIPPED to, or nil while the injected one is showing. See `flipPartner`.
    @State private var flipped: AirportProcedure?

    /// THE plate on screen. Every read below goes through this and never through `procedure` directly —
    /// title, georef, minima, and the document URL must describe the same chart at all times. Mixing
    /// them would draw one plate's page under another's name with a third's georeference feeding the
    /// ownship transform, which is the single most dangerous thing this screen can do.
    private var current: AirportProcedure { flipped ?? procedure }

    /// The chart to flip to: the airport DIAGRAM, resolved here rather than injected so both presenters
    /// (`PlatesTabView` and `MapObjectView`) get the control without either having to pass it.
    ///
    /// Usually absent. Measured against the bundled cycle, 2,291 of 3,197 charted airports publish no
    /// APD at all — so a missing partner is the MAJORITY case and the control is HIDDEN rather than
    /// disabled, following the by-minima button next door.
    private var flipPartner: AirportProcedure? {
        let diagram = Procedures.forAirport(airport).first { $0.code == "APD" }
        guard let diagram, diagram.id != procedure.id else { return nil }
        return diagram
    }

    private var georef: PlateGeorefEntry? { PlateGeoref.lookup(pdf: current.pdf) }
    private var trafficMarkers: [PlateTraffic] {
        model.aircraft.compactMap { ac in ac.coordinate.map { PlateTraffic(coord: $0, track: ac.trackDeg) } }
    }
    /// Ownship position: a VALID Stratux fix wins (avoids a stale last-known position, C4), else the
    /// device's own GPS — so a Stratux-less iPad still shows the pilot on a georeferenced plate.
    /// `trustedCoord`, not `coord`: an approach plate is the most dangerous place in the app to draw a
    /// position that can't be trusted, so an unreliable / suspect fix hides ownship rather than plotting
    /// it (the "waiting for GPS" caption below then explains the absence).
    private var ownshipCoord: Coord? {
        if let g = model.stratuxGPS, g.hasFix { return g.coordinate }
        return deviceLocation.trustedCoord
    }

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    PDFKitView(url: url, georef: georef,
                               ownship: showOverlay ? ownshipCoord : nil,
                               traffic: showOverlay ? trafficMarkers : [],
                               showTraffic: showOverlay)
                        .ignoresSafeArea(edges: .bottom)
                        // Night: a non-interactive dark + red scrim tames the white-page blast while
                        // keeping PDFKit's vector zoom (true inversion of a live PDFView isn't cheap).
                        .overlay {
                            if model.theme == .night {
                                ZStack {
                                    Color.black.opacity(0.35)
                                    Color.hex(0xFF2E14).opacity(0.08)
                                }
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) { if showOverlay { trafficLegend } }
                } else if loading {
                    ProgressView("Downloading plate…").tint(palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    offlineState
                }
            }
            .navigationTitle(current.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(current.name).font(.dsHeadline).lineLimit(1)
                        Text(airport).font(.dsLabelS).foregroundStyle(palette.textDim)
                    }
                }
                // Ownship + traffic overlay — only possible on a georeferenced plate (needs world→page).
                if url != nil, georef != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Haptics.impact(.light); showOverlay.toggle()
                        } label: {
                            Label("My Position", systemImage: showOverlay ? "location.fill" : "location")
                        }
                        .tint(showOverlay ? palette.accent : palette.textDim)
                        .accessibilityIdentifier("plate-traffic-toggle")
                    }
                }
                // The minima block, read off this plate. Offered only once the plate is on disk and the
                // parse actually produced a table — a button that opens an empty panel is worse than no
                // button, because it implies the numbers were checked and found absent.
                if url != nil, minimaStore.result(for: current)?.minima != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Haptics.impact(.light); showMinima = true } label: {
                            Label("Minima", systemImage: "arrow.down.to.line")
                        }
                        .accessibilityIdentifier("plate-minima")
                    }
                }
                if let partner = flipPartner {
                    ToolbarItem(placement: .primaryAction) { flipButton(partner) }
                }
                // Overlay-on-map is georef-only (placement is exact + not manually adjustable), so the
                // action is hidden for schematic plates (SIDs/STARs/minimums) with no georeference.
                if let onSendToMap, let url, georef != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { onSendToMap(url) } label: { Label("Overlay on map", systemImage: "map") }
                            .accessibilityIdentifier("plate-overlay-map")
                    }
                }
            }
        }
        .tint(palette.accent)
        // `.task(id:)`, NOT a bare `.task`. A plain task runs once per view identity, so flipping the
        // internal state would have changed the title, the georef and the minima lookup while `url` still
        // pointed at the OUTGOING document — plate A's page under plate B's name, with plate B's
        // transform placing ownship on it.
        .task(id: current.id) { await load() }
        .onChange(of: url) { _, new in
            guard new != nil else { return }
            minimaStore.ensure(current, airport: airport)
        }
        .sheet(isPresented: $showMinima) {
            if let parsed = minimaStore.result(for: current), let m = parsed.minima {
                NavigationStack {
                    MinimaPanel(minima: m, refusals: parsed.refusals,
                                temperatureC: metars.metar(airport)?.tempC, palette: palette)
                        .navigationTitle("Minima")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showMinima = false }
                            }
                        }
                }
                .tint(palette.accent)
                .presentationDetents([.large, .medium])
            }
        }
        // Run the device GPS only while a GEOREFERENCED plate is open (it's the only kind that can plot
        // ownship); stop on close so it isn't a background battery drain. The stop is SYMMETRIC with the
        // GPS is owned by the always-mounted map (single owner) — the plate viewer only READS
        // deviceLocation.coord to place ownship, so it no longer starts/stops the shared session
        // (which previously left the map's ownship frozen after the viewer closed).
    }

    /// Swap between the approach plate and the airport diagram in one tap.
    ///
    /// This is the alternation this app leaves most expensive. Everything else is already cheap to swap
    /// — tabs stay mounted, every chart base stays tile-loaded — but only one plate exists at a time,
    /// and 0 of 908 airport diagrams are georeferenced, so the two cannot both be put on the map
    /// instead. Going approach → diagram → approach otherwise costs Done, scroll the binder, find the
    /// APD, tap, at the busiest minute of the flight.
    @ViewBuilder private func flipButton(_ partner: AirportProcedure) -> some View {
        let showingPartner = (flipped != nil)
        Button {
            Haptics.impact(.light)
            // Reset the document state AT the swap so the spinner and the offline notice keep telling
            // the truth while the new plate loads, rather than the old page lingering under a new title.
            url = nil
            loading = true
            flipped = showingPartner ? nil : partner
        } label: {
            Label(showingPartner ? procedure.name : partner.name,
                  systemImage: "arrow.left.arrow.right.square")
        }
        .tint(showingPartner ? palette.accent : palette.textDim)
        .accessibilityIdentifier("plate-flip")
    }

    /// A small caption under the chart when the overlay is on — states what the markers are and the
    /// honest caveat (georef is a reference aid; own position needs a Stratux/GPS fix).
    private var trafficLegend: some View {
        HStack(spacing: 12) {
            Label("You", systemImage: "circle.fill").foregroundStyle(.blue)
            Label("Traffic", systemImage: "triangle.fill").foregroundStyle(.orange)
            if ownshipCoord == nil { Text("· waiting for GPS").foregroundStyle(palette.textDim) }
        }
        .font(.dsLabelS).padding(.horizontal, 12).padding(.vertical, 6)
        .background(palette.overlay, in: Capsule())
        .padding(.bottom, 10)
    }

    private var offlineState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.system(size: 34)).foregroundStyle(palette.textDim)
            Text("Plate not downloaded").font(.dsHeadline).foregroundStyle(palette.text)
            Text("This plate isn’t cached yet and couldn’t be fetched. Connect to the internet once to download it, then it works offline.")
                .font(.dsLabel).foregroundStyle(palette.textDim)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Try again") { Haptics.impact(.light); Task { loading = true; await load() } }
                .buttonStyle(.borderedProminent).tint(palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let want = current
        // Instant path: already cached.
        if let cached = PlateStore.localURL(want), FileManager.default.fileExists(atPath: cached.path) {
            url = cached; loading = false; return
        }
        let got = await PlateStore.ensureOnDisk(want)
        // A slow fetch can land after the pilot has flipped again; adopting it would put the wrong
        // document on screen. `.task(id:)` cancels the old task, but the await may already have resumed.
        guard want.id == current.id else { return }
        url = got
        loading = false
    }
}
