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
    var onSendToMap: ((URL) -> Void)? = nil
    var onClose: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var url: URL?
    @State private var loading = true
    @State private var showOverlay = true                  // show ownship/traffic by default on a georef'd plate

    private var georef: PlateGeorefEntry? { PlateGeoref.lookup(pdf: procedure.pdf) }
    private var trafficMarkers: [PlateTraffic] {
        model.aircraft.compactMap { ac in ac.coordinate.map { PlateTraffic(coord: $0, track: ac.trackDeg) } }
    }
    /// Ownship position: a VALID Stratux fix wins (avoids a stale last-known position, C4), else the
    /// device's own GPS — so a Stratux-less iPad still shows the pilot on a georeferenced plate.
    private var ownshipCoord: Coord? {
        if let g = model.stratuxGPS, g.hasFix { return g.coordinate }
        return deviceLocation.coord
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
                        .overlay(alignment: .bottom) { if showOverlay { trafficLegend } }
                } else if loading {
                    ProgressView("Downloading plate…").tint(palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    offlineState
                }
            }
            .navigationTitle(procedure.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(procedure.name).font(.headline).lineLimit(1)
                        Text(airport).font(.caption2).foregroundStyle(palette.textDim)
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
                if let onSendToMap, let url {
                    ToolbarItem(placement: .primaryAction) {
                        Button { onSendToMap(url) } label: { Label("Overlay on map", systemImage: "map") }
                            .accessibilityIdentifier("plate-overlay-map")
                    }
                }
            }
        }
        .tint(palette.accent)
        .task { await load() }
        // Run the device GPS only while a GEOREFERENCED plate is open (it's the only kind that can plot
        // ownship); stop on close so it isn't a background battery drain.
        .onAppear { if georef != nil { deviceLocation.start() } }
        .onDisappear { deviceLocation.stop() }
    }

    /// A small caption under the chart when the overlay is on — states what the markers are and the
    /// honest caveat (georef is a reference aid; own position needs a Stratux/GPS fix).
    private var trafficLegend: some View {
        HStack(spacing: 12) {
            Label("You", systemImage: "circle.fill").foregroundStyle(.blue)
            Label("Traffic", systemImage: "triangle.fill").foregroundStyle(.orange)
            if ownshipCoord == nil { Text("· waiting for GPS").foregroundStyle(palette.textDim) }
        }
        .font(.caption2).padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 10)
    }

    private var offlineState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.system(size: 34)).foregroundStyle(palette.textDim)
            Text("Plate not downloaded").font(.headline).foregroundStyle(palette.text)
            Text("This plate isn’t cached yet and couldn’t be fetched. Connect to the internet once to download it, then it works offline.")
                .font(.caption).foregroundStyle(palette.textDim)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Try again") { Task { loading = true; await load() } }
                .buttonStyle(.borderedProminent).tint(palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        // Instant path: already cached.
        if let cached = PlateStore.localURL(procedure), FileManager.default.fileExists(atPath: cached.path) {
            url = cached; loading = false; return
        }
        let got = await PlateStore.ensureOnDisk(procedure)
        url = got
        loading = false
    }
}
