// EXPERIMENTAL — branch experimental/maplibre-migration. DO NOT MERGE.
//
// Milestone 1 of the MKMapView→MapLibre migration ("tiles + route first"): render our ACTUAL offline FAA
// chart tiles + the filed route on the MapLibre globe. Tiles come from the same `MBTilesReader`s / `ChartStore`
// the production map uses, bridged to MapLibre via the loopback `MBTilesHTTPServer`. An OSM raster sits
// underneath as an ONLINE-ONLY backdrop; the FAA sectional (offline packs) draws on top wherever downloaded.
// EXPERIMENTAL caveat: offline in the cockpit only the FAA-covered regions + the #0b1a2b background render
// (the OSM backdrop needs connectivity) — a bundled low-zoom base is a pre-ship TODO before this leaves spike.
//
// Still to port in later milestones: airspace / airways / TFR / plate overlays, nearby FAA symbols,
// ownship + traffic, and tap-to-identify. See EXPERIMENTAL_DO_NOT_MERGE.md.

#if canImport(MapLibre)
import SwiftUI
import MapLibre
import MapKit
import CoreLocation

struct MapLibreChartView: UIViewRepresentable {
    let store: ChartStore
    var layer: ChartLayer = .sectional               // FAA base layer (sectional / IFR-low / IFR-high)
    var routeCoords: [CLLocationCoordinate2D]
    var breadcrumbCoords: [CLLocationCoordinate2D] = []   // flight-recorder trail (translucent orange)
    var radarTemplate: String? = nil                      // live precipitation-radar tile URL (nil = off)
    var ownship: CLLocationCoordinate2D? = nil
    var ownshipCourse: Double? = nil
    var traffic: [Aircraft] = []
    var tfrs: [TFR] = []
    var showTFRs: Bool = false
    var showAirspace: Bool = true                     // MapLayersMenu overlay toggles (parity with ChartMapView)
    var showNearby: Bool = true
    var showAirways: Bool = true
    var plateOverlay: PlateOverlayState? = nil
    var routeIdents: Set<String> = []
    var initialCenter: Coord? = nil                   // frame here on first load (pilot's GPS) if no route
    var focus: Coord? = nil                           // recenter here when it changes (search-result pick)
    var restoreCamera: SavedMapCamera? = nil          // restore the pilot's last pan/zoom across remounts (M7)
    var onTapObjects: ([IdentifiedObject]) -> Void = { _ in }
    var onPlateAnchors: ((CGPoint, CGPoint)?) -> Void = { _ in }   // plate top-corner screen-points → host chrome
    var searchHighlight: CLLocationCoordinate2D? = nil            // a pulsing search-result marker (layer-independent)
    var onSearchPoint: (CGPoint?) -> Void = { _ in }             // its screen-point → the SwiftUI pulsing overlay
    var mapCommand: MapCommandRequest? = nil                      // one-shot side-bar camera command (zoom / center)
    var onRenderStalled: () -> Void = {}                           // map drew 0 frames → host falls back to classic map
    var onVisibleRegion: (MKMapRect) -> Void = { _ in }            // settle → host persists model.lastMapCamera
    var renderMeter: MapRenderMeter? = nil                         // battery diagnostics: per-frame counter → map fps
    var globeProjection: Bool = false                             // DEV: emit projection:globe (inert on stock 6.27.0)

    func makeCoordinator() -> Coordinator { Coordinator(store: store, routeCoords: routeCoords) }

    // Host the MLNMapView inside a plain UIView CONTAINER, and create the MLNMapView itself LAZILY — only once
    // the scene is ACTIVE. An MLNMapView built during scene-connect (cold launch, deep in the RootTabView
    // opacity-switched ZStack) starts DORMANT: valid (in-window, sized, visible) yet renders ZERO frames until a
    // background→foreground cycle. Built once the scene is active it renders immediately. (The full-screen
    // standalone screen never hit this because it is created near the window root as the scene activates.)
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: UIScreen.main.bounds)
        container.backgroundColor = .clear
        context.coordinator.onRenderStalled = onRenderStalled   // set BEFORE mount (watchdog is armed in createMap)
        context.coordinator.onVisibleRegion = onVisibleRegion
        context.coordinator.renderMeter = renderMeter
        context.coordinator.globeProjection = globeProjection   // read once at style install (createMap)
        context.coordinator.mount(in: container, initialCenter: initialCenter, routeFirst: routeCoords.first)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let c = context.coordinator
        c.onVisibleRegion = onVisibleRegion
        c.onSearchPoint = onSearchPoint
        c.inMapCommand = mapCommand
        c.cacheInputs(layer: layer, routeCoords: routeCoords, breadcrumbCoords: breadcrumbCoords,
                      radarTemplate: radarTemplate, ownship: ownship, ownshipCourse: ownshipCourse,
                      traffic: traffic, tfrs: showTFRs ? tfrs : [], showAirspace: showAirspace,
                      showNearby: showNearby, showAirways: showAirways, plateOverlay: plateOverlay,
                      routeIdents: routeIdents, focus: focus, restoreCamera: restoreCamera,
                      onTap: onTapObjects, onAnchors: onPlateAnchors, searchHighlight: searchHighlight)
        guard c.map != nil else { return }      // map not built yet (scene still activating) → apply on createMap
        c.applyLatest()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.teardown() }

    // MARK: coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let store: ChartStore
        let server: MBTilesHTTPServer
        private var routeCoords: [CLLocationCoordinate2D]
        weak var map: MLNMapView?              // the hosted map (inside a UIView container); driven by updateUIView
        private var overlayGen = 0                 // drops stale async overlay refreshes (mirrors contextGen)
        private var wantFixes = false              // hysteretic GPS-fix visibility (show scale<2.2, hide >2.7)
        var onTapObjects: (([IdentifiedObject]) -> Void)?
        var onPlateAnchors: ((CGPoint, CGPoint)?) -> Void = { _ in }  // plate top-corner screen-points → host chrome
        var routeIdents: Set<String> = []
        var tfrByID: [String: TFR] = [:]           // full TFRs, recovered from a tapped feature's "id"
        private var cachedTFRs: [TFR] = []         // applied at didFinishLoading if the style wasn't ready yet
        private var plateState: PlateOverlayState? // last plate applied; diffed against below to avoid churn
        private var plateKey: String?
        private var plateOpacity: Double?
        private var plateInverted: Bool?
        private var plateImageKey: String?         // "pdf|inverted" — refresh the raster on a plate SWAP, not just invert
        private var plateCornersCoord: (tl: CLLocationCoordinate2D, tr: CLLocationCoordinate2D)?  // chrome anchors
        private var serverPort: UInt16 = 0         // bound loopback port, delivered async by the tile server
        private var servedReadersSig: String?      // (layer + sorted mounted packIDs) last handed to the tile server
        private var regionDebounce: DispatchWorkItem?  // coalesces a burst of region-settle events (pan/zoom)
        private var layer: ChartLayer = .sectional     // FAA base layer; drives ensureVisiblePacks
        private var appliedLayer: ChartLayer?          // last-applied — a change re-requests packs for the new layer
        private var showAirspace = true, showNearby = true, showAirways = true   // MapLayersMenu overlay toggles
        private var appliedToggles: String?            // last-applied toggle triple — a change re-runs refreshOverlays
        private var lastFocus: Coord?                  // search-recenter dedupe
        var onVisibleRegion: ((MKMapRect) -> Void)?    // settle → host persists model.lastMapCamera (M7)
        private var restoreCamera: SavedMapCamera?     // pilot's last pan/zoom, restored once on first frame
        private var didFrame = false                   // one-shot: frame to camera/route/GPS once real data exists
        private var probeGen = 0                       // tap-identify generation guard (a newer tap supersedes)
        private var styleConfigured = false            // setup-overlays ONCE per coordinator (didFinishLoading can re-fire)
        // Lazy-map plumbing: the container + framing captured at mount, and the latest updateUIView inputs (so
        // they can be applied once the map is actually built on scene-active).
        private weak var container: UIView?
        private var pendingInitialCenter: Coord?
        private var pendingRouteFirst: CLLocationCoordinate2D?
        private var inLayer: ChartLayer = .sectional
        private var inRoute: [CLLocationCoordinate2D] = []
        private var inBreadcrumb: [CLLocationCoordinate2D] = []
        private var trackCoords: [CLLocationCoordinate2D] = []   // last-applied trail (re-applied after a style reload)
        private var appliedTrackCount = -1                       // cheap change signature (append-only + reset-to-0)
        private var inRadarTemplate: String?                     // latest radar tile URL from updateUIView
        private var appliedRadarTemplate: String??              // last-applied (double-optional: distinguishes "never applied")
        private var inOwnship: CLLocationCoordinate2D?
        private var inOwnCourse: Double?
        private var inTraffic: [Aircraft] = []
        private var inTFRs: [TFR] = []
        private var inShowAirspace = true, inShowNearby = true, inShowAirways = true
        private var inPlate: PlateOverlayState?
        private var inFocus: Coord?

        /// Stash the latest inputs from updateUIView (called every body eval, even before the map exists).
        func cacheInputs(layer: ChartLayer, routeCoords: [CLLocationCoordinate2D],
                         breadcrumbCoords: [CLLocationCoordinate2D], radarTemplate: String?,
                         ownship: CLLocationCoordinate2D?,
                         ownshipCourse: Double?, traffic: [Aircraft], tfrs: [TFR], showAirspace: Bool,
                         showNearby: Bool, showAirways: Bool, plateOverlay: PlateOverlayState?,
                         routeIdents: Set<String>, focus: Coord?, restoreCamera: SavedMapCamera?,
                         onTap: @escaping ([IdentifiedObject]) -> Void,
                         onAnchors: @escaping ((CGPoint, CGPoint)?) -> Void,
                         searchHighlight: CLLocationCoordinate2D?) {
            inLayer = layer; inRoute = routeCoords; inBreadcrumb = breadcrumbCoords; inRadarTemplate = radarTemplate
            inOwnship = ownship; inOwnCourse = ownshipCourse
            inTraffic = traffic; inTFRs = tfrs; inShowAirspace = showAirspace; inShowNearby = showNearby
            inShowAirways = showAirways; inPlate = plateOverlay; inFocus = focus; self.restoreCamera = restoreCamera
            self.routeIdents = routeIdents; self.onTapObjects = onTap; self.onPlateAnchors = onAnchors
            inSearchHighlight = searchHighlight
        }
        var inSearchHighlight: CLLocationCoordinate2D?
        var onSearchPoint: (CGPoint?) -> Void = { _ in }
        /// Stream the search highlight's screen point (or nil) so the SwiftUI pulsing marker rides the map.
        func emitSearchPoint(_ map: MLNMapView) {
            guard let cc = inSearchHighlight else { onSearchPoint(nil); return }
            onSearchPoint(map.convert(cc, toPointTo: map))
        }

        var inMapCommand: MapCommandRequest?
        var lastMapCommandToken = 0
        /// Apply a side-bar camera command on the GPU map: step the zoom level, or re-frame on the ownship.
        func applyMapCommand(_ map: MLNMapView) {
            guard let cmd = inMapCommand, cmd.token != lastMapCommandToken else { return }
            lastMapCommandToken = cmd.token
            switch cmd.kind {
            case .zoomIn:  map.setZoomLevel(min(map.zoomLevel + 1, 18), animated: true)
            case .zoomOut: map.setZoomLevel(max(map.zoomLevel - 1, 1), animated: true)
            case .centerOwnship:
                guard let o = inOwnship else { return }
                map.setCenter(o, zoomLevel: max(map.zoomLevel, 10), animated: true)
            }
        }

        /// Apply the cached inputs to the live map (from updateUIView, and once more right after createMap).
        func applyLatest() {
            guard let map else { return }
            frameIfNeeded(on: map)          // re-attempt initial framing until real route/GPS/saved-camera exists
            applyLayer(inLayer, on: map)
            // Surface packs whose download completed AFTER ensureVisiblePacks returned (store.readers is
            // @MainActor → hop, matching ensureVisiblePacks). Signature-gated, so a no-op when the set is unchanged.
            Task { @MainActor [weak self, weak map] in guard let self, let map else { return }; self.syncFAASource(on: map) }
            updateRoute(inRoute, on: map)
            updateTrack(inBreadcrumb, on: map)
            updateRadar(inRadarTemplate, on: map)
            emitSearchPoint(map)               // keep the pulsing search marker glued to its spot
            applyMapCommand(map)               // one-shot side-bar zoom / center-on-ownship
            applyOverlayToggles(inShowAirspace, inShowNearby, inShowAirways, on: map)
            updateOwnship(inOwnship, course: inOwnCourse, on: map)
            updateTraffic(inTraffic, on: map)
            updateTFRs(inTFRs, on: map)
            updatePlate(inPlate, on: map)
            applyFocus(inFocus, on: map)
        }

        /// One-shot initial framing (mirrors ChartMapView's didFrame): at cold launch the route resolves
        /// and the GPS fix arrive AFTER the map is built, so createMap's mount-time snapshot is CONUS. Keep
        /// re-attempting on every apply until a real target exists — a fresh saved camera, else the route,
        /// else the ownship/GPS — so the map auto-centers instead of stranding the pilot at continental scale.
        private func frameIfNeeded(on map: MLNMapView) {
            guard !didFrame else { return }
            if let cam = restoreCamera, SavedMapCamera.cameraIsFresh(savedAt: cam.savedAt, now: Date()) {
                let r = cam.region
                let sw = CLLocationCoordinate2D(latitude: r.center.latitude - r.span.latitudeDelta / 2,
                                                longitude: r.center.longitude - r.span.longitudeDelta / 2)
                let ne = CLLocationCoordinate2D(latitude: r.center.latitude + r.span.latitudeDelta / 2,
                                                longitude: r.center.longitude + r.span.longitudeDelta / 2)
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), animated: false)
                didFrame = true; return
            }
            if inRoute.count >= 2 {
                let lats = inRoute.map(\.latitude), lons = inRoute.map(\.longitude)
                guard let a = lats.min(), let b = lats.max(), let c = lons.min(), let d = lons.max() else { return }
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: .init(latitude: a, longitude: c),
                                                                   ne: .init(latitude: b, longitude: d)),
                                               edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 80, right: 60),
                                               animated: false)
                didFrame = true; return
            }
            if let own = inOwnship {
                map.setCenter(own, zoomLevel: 8.0, animated: false); didFrame = true
            }
        }

        init(store: ChartStore, routeCoords: [CLLocationCoordinate2D]) {
            self.store = store
            self.routeCoords = routeCoords
            self.server = MBTilesHTTPServer()          // packs are pushed in via setReaders (main actor)
            super.init()
        }

        /// Prepare the container and create the MLNMapView only once the scene is ACTIVE (see makeUIView note:
        /// a map built during scene-connect stays dormant / never renders in the tab). If the scene is already
        /// active (a later remount, e.g. toggling the engine), build immediately.
        func mount(in container: UIView, initialCenter: Coord?, routeFirst: CLLocationCoordinate2D?) {
            self.container = container
            self.pendingInitialCenter = initialCenter
            self.pendingRouteFirst = routeFirst
            // Build the map only once the scene is ACTIVE (a map built during scene-connect can stay dormant).
            if UIApplication.shared.applicationState == .active {
                createMap()
            } else {
                NotificationCenter.default.addObserver(self, selector: #selector(createMap),
                                                       name: UIApplication.didBecomeActiveNotification, object: nil)
            }
        }

        // Render watchdog: if the MLNMapView produces ZERO frames shortly after it should be visible, it hit
        // the MLNMapView-blank-until-scene-refresh condition (seen in the Simulator) — fall back to the classic
        // map so the pilot is NEVER left with a blank chart. renderCount is driven by didFinishRenderingFrame.
        var renderCount = 0
        var onRenderStalled: (() -> Void)?
        var renderMeter: MapRenderMeter?           // shared frame counter for the battery diagnostics (map fps)
        var globeProjection = false                // DEV: consumed once at writeStyle (createMap); remount to re-apply
        func mapView(_ mapView: MLNMapView, didFinishRenderingFrame fullyRendered: Bool) {
            renderCount += 1; renderMeter?.tick()
        }

        /// MapLibre failed to load the map/tiles (e.g. the style URL was never set on a bind failure, or a
        /// fatal tile error). Fall back to the classic map immediately — the zero-frame watchdog can't see a
        /// blank-but-rendering globe, so a real load failure must trigger the fallback explicitly.
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) { onRenderStalled?() }

        @objc private func createMap() {
            guard map == nil, let container else { return }
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            let m = MLNMapView(frame: container.bounds)
            m.delegate = self
            m.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            m.preferredFramesPerSecond = .lowPower  // BATTERY: cap ~30fps (EFB
            // moving map needs no 60fps); halves GPU per redraw + per symbol-fade frame. Still increments
            // renderCount so the zero-frame stall watchdog is unaffected.
            // Frame the pilot's location if we have a fix, else the route, else CONUS. Zoom 7-8 keeps the visible
            // span under the ~7° gate so airway/airspace-altitude labels render (hidden when zoomed further out).
            if let ic = pendingInitialCenter {
                m.setCenter(CLLocationCoordinate2D(latitude: ic.lat, longitude: ic.lon), zoomLevel: 8.0, animated: false)
            } else if let c = pendingRouteFirst {
                m.setCenter(c, zoomLevel: 7.0, animated: false)
            } else {
                m.setCenter(CLLocationCoordinate2D(latitude: 39, longitude: -96), zoomLevel: 3.2, animated: false)
            }
            m.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
            m.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:))))
            container.addSubview(m)
            self.map = m
            // Start the loopback tile server WITHOUT blocking the main thread; install the style only once the
            // listener binds a port (the port is the sole thing writeStyle needs). A failed bind delivers 0.
            server.start { [weak self, weak m] port in
                guard let self, let m else { return }
                // Loopback bind FAILED (onReady delivers 0) → the style would render blank forever. Fall back to
                // the classic map NOW rather than relying on the zero-frame watchdog (which a blank-but-rendering
                // globe defeats). Same for a temp-file write failure making writeStyle nil.
                guard port > 0 else { self.onRenderStalled?(); return }
                guard self.serverPort == 0 else { return }                 // install the style ONCE
                self.serverPort = port
                guard let styleURL = Self.writeStyle(port: port, globe: self.globeProjection) else { self.onRenderStalled?(); return }
                m.styleURL = styleURL
            }
            applyLatest()   // push whatever updateUIView cached before the map existed
            armRenderWatchdog()
        }

        /// Render watchdog: if the map draws ZERO frames it hit the MLNMapView-blank-until-scene-refresh
        /// condition → hand back to the classic map. STAGGERED (not a single 2.2s shot): a slow-but-working
        /// first frame under cold-launch contention (WhisperKit compile + NavDB warm + listener bind + style
        /// parse) shouldn't be misclassified as a permanent failure. Only the LAST check falls back, giving
        /// ~6.6s of grace; any frame in between → healthy → no-op. Hard failures (bind/style/load-error) still
        /// fall back immediately via their own paths. MERCATOR ONLY — under the globe (dev harness, opt-in) the
        /// same zero-frame count false-reverts a map that IS drawing → the "globe for a second then flat" bug;
        /// genuine load failures still trip mapViewDidFailLoadingMap immediately for both projections.
        private static let maxStallChecks = 3
        private func armRenderWatchdog() {
            assert(Self.maxStallChecks >= 1, "watchdog needs >=1 check")
            assert(renderCount >= 0, "renderCount underflow")
            guard !self.globeProjection else { return }   // globe: skip the mercator-only zero-frame watchdog
            for i in 1...Self.maxStallChecks {                          // bounded (rule 2), no recursion
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2 * Double(i)) { [weak self] in
                    guard let self, self.renderCount == 0 else { return }   // any frame → healthy
                    if i == Self.maxStallChecks { self.onRenderStalled?() }  // still blank at the last check
                }
            }
        }

        /// Cancel the pending region-settle work and stop the loopback server (called from dismantleUIView).
        func teardown() {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            regionDebounce?.cancel(); regionDebounce = nil; server.stop()
        }

        // MARK: style + layers

        private static func writeStyle(port: UInt16, globe: Bool) -> URL? {
            // FULLY OFFLINE style: FAA sectional raster from the loopback server over a #0b1a2b sea, with a
            // bundled vector land base (setupLandBase, added at didFinishLoading) drawn between. NO network
            // dependency — glyphs + FAA tiles are loopback, land is bundled. Only ever called with a bound
            // port (>0), so both loopback URLs are always connectable.
            assert(port > 0, "writeStyle requires a bound loopback port")
            // GLOBE DEV HARNESS: when the hidden Developer "Globe" toggle is on we emit the style-spec
            // `projection:globe` key, which the custom MapLibre fork (ios/docs/GLOBE_FORK_PLAN.md, linked as
            // Vendor/MapLibre.xcframework) honors — curving the map onto a sphere. Remount to re-apply.
            let projection = globe ? "\"projection\": { \"type\": \"globe\" },\n              " : ""
            // Sea colour: on the globe the background renders as the SPHERE surface (ocean), and the area outside
            // the sphere is "space" (the app's near-black palette bg, #0B1117). The flat sea #0b1a2b is almost
            // that same near-black, so on the globe the ocean melts into space. Use a deeper, clearly-blue ocean
            // on the globe so the sphere reads as a planet against the void; the flat chart keeps its dark sea.
            let sea = globe ? "#0f3a63" : "#0b1a2b"
            // On the globe, request FAA tiles through the "/uz/" underzoom path so the chart drapes over the whole
            // sphere when zoomed out (low-res context, MBTilesHTTPServer composites minZoom tiles). Flat map is
            // unchanged: plain "/{z}/{x}/{y}", no underzoom. minzoom:0 lets the raster source request low zooms.
            let faaTiles = globe ? "uz/{z}/{x}/{y}" : "{z}/{x}/{y}"
            let style = """
            {
              "version": 8,
              \(projection)"glyphs": "http://127.0.0.1:\(port)/font/{fontstack}/{range}.pbf",
              "sources": {
                "faa": { "type": "raster", "tiles": ["http://127.0.0.1:\(port)/\(faaTiles)"],
                         "tileSize": 256, "minzoom": 0, "maxzoom": 16, "attribution": "FAA charts (offline pack)" }
              },
              "layers": [
                { "id": "bg", "type": "background", "paint": { "background-color": "\(sea)" } },
                { "id": "faa", "type": "raster", "source": "faa" }
              ]
            }
            """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("maplibre-chart.json")
            do { try style.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            servedReadersSig = nil               // the faa source is freshly (re)created empty here → force a remount
            appliedTrackCount = -1               // the "track" source is recreated empty → force a re-apply below
            appliedRadarTemplate = nil           // wxradar source gone after reload → force updateRadar to re-add
            setupOverlayLayers(style)            // airspace/airways/nav + TFR/route/traffic/ownship (empty)
            updateRoute(routeCoords, on: mapView)
            updateTrack(trackCoords, on: mapView)
            updateRadar(inRadarTemplate, on: mapView)
            ensureVisiblePacks(mapView)
            refreshOverlays(mapView)
            frameIfNeeded(on: mapView)           // frame now if route/GPS/camera arrived before the style loaded
            // Re-apply anything updateUIView cached before the style finished loading (same idiom as route).
            updateOwnship(lastOwnship, course: lastOwnCourse, on: mapView)
            updateTraffic(lastTraffic, on: mapView)
            updateTFRs(cachedTFRs, on: mapView)
            updatePlate(plateState, on: mapView)
        }

        /// Load the chart packs under the region the user settles on (as MapHostView does), so panning the
        /// globe pulls in coverage; and refresh the vector overlays for the new region. DEBOUNCED 0.4s (like
        /// the production MK coordinator) so a momentum pan / pinch burst coalesces to ONE pack-load + overlay
        /// refresh instead of firing redundant network downloads + off-main DB scans on every settle.
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            emitPlateAnchors(mapView)              // keep the plate corner gear pinned (NOT debounced — must be live)
            emitSearchPoint(mapView)
            regionDebounce?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.onVisibleRegion?(Coordinator.visibleMapRect(mapView))  // host saves model.lastMapCamera (M7)
                self.ensureVisiblePacks(mapView)
                self.refreshOverlays(mapView)
            }
            regionDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        /// The map's visible span as an MKMapRect (for the host's SavedMapCamera + store.ensureVisible).
        static func visibleMapRect(_ mapView: MLNMapView) -> MKMapRect {
            let b = mapView.visibleCoordinateBounds
            let ne = MKMapPoint(b.ne), sw = MKMapPoint(b.sw)
            return MKMapRect(x: min(ne.x, sw.x), y: min(ne.y, sw.y),
                             width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
        }

        /// Stream the plate corner gear's screen anchors continuously during an active pan/zoom (cheap:
        /// projects 2 points, guarded to no-op when no plate is loaded), so the gear rides the plate live.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) { emitPlateAnchors(mapView); emitSearchPoint(mapView) }

        // MARK: airspace + airways overlays (milestone 2)

        /// Create the persistent overlay sources + layers ONCE (empty). Per-region refresh only mutates
        /// `source.shape` — so we never remove a source a layer still uses (MapLibre would throw). Stacking:
        /// land base below the FAA raster below airways below airspace below route.
        private func setupOverlayLayers(_ style: MLNStyle) {
            // ONCE per coordinator: MapLibre can call didFinishLoading more than once for the SAME map.
            guard !styleConfigured else { return }
            styleConfigured = true
            // CLEAN SLATE: MapLibre restores runtime-added layers from its ambient cache across launches, so
            // the "fresh" style can already carry OUR layers (with dangling sources) → adding them again throws
            // MLNRedundantLayerIdentifierException. Remove any of our managed layers/sources first (layers
            // before their sources, or MapLibre throws), then build fresh — self-healing + fully idempotent.
            clearManagedStyle(style)
            setupLandBase(style)               // OFFLINE vector land/coastline, bottom-most (above bg, below faa)
            setupAirwayAirspaceLayers(style)   // airways-line + airspace fill/outline (below labels)
            setupLabelLayers(style)            // airway idents + airspace altitude blocks (SDF text)
            setupNavLayers(style)              // FAA nav glyphs + idents
            setupDynamicLayers(style)          // TFR/route/traffic/ownship (empty; driven by updateUIView)
        }

        /// Remove every layer + source THIS coordinator manages, layers-before-sources (MapLibre throws if a
        /// source is removed while a layer still uses it). Makes setup self-healing against a MapLibre ambient
        /// cache that restored our runtime layers (leaving dangling ids). "faa" is intentionally excluded — it
        /// lives in the base style JSON and is re-managed by ensureVisiblePacks. Bounded loops, >=2 asserts.
        private func clearManagedStyle(_ style: MLNStyle) {
            let layers = ["plate-raster", "ownship-sym", "traffic-sym", "route-line", "track-line",
                          "wxradar-layer", "tfr-label", "tfr-outline", "tfr-fill", "nav-sym",
                          "airspace-label", "airways-label", "airspace-outline", "airspace-fill",
                          "airways-line", "coastline", "land-fill"]
            for id in layers where style.layer(withIdentifier: id) != nil {          // bounded (rule 2)
                if let l = style.layer(withIdentifier: id) { style.removeLayer(l) }
            }
            let sources = ["plate", "ownship", "traffic", "route", "track", "wxradar", "tfr-labels", "tfr",
                           "nav", "airspace-labels", "airspace", "airways", "land"]
            for id in sources where style.source(withIdentifier: id) != nil {        // bounded (rule 2)
                if let s = style.source(withIdentifier: id) { style.removeSource(s) }
            }
            assert(style.layer(withIdentifier: "coastline") == nil, "clearManagedStyle: coastline survived")
            assert(style.source(withIdentifier: "land") == nil, "clearManagedStyle: land source survived")
        }

        /// OFFLINE world backdrop: a bundled coarse global land polygon set (Natural Earth 1:50m, public
        /// domain) as a fill + thin coastline, so the map shows land-vs-water + coastlines with NO network
        /// (replacing the old online OSM raster). Drawn just above the background so it sits BELOW the FAA
        /// raster and every overlay; `above: bg` survives ensureVisiblePacks re-inserting the faa layer.
        /// No-ops (map still renders bg+faa) if the bundled asset is missing/unparseable — never crashes.
        private func setupLandBase(_ style: MLNStyle) {
            guard style.source(withIdentifier: "land") == nil else { return }   // per-id idempotency (defensive)
            guard let url = Bundle.main.url(forResource: "ne_land", withExtension: "geojson", subdirectory: "basemap"),
                  let data = try? Data(contentsOf: url),
                  let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue) else {
                assert(false, "offline land base asset missing/unparseable — shipping bg+faa only")
                return
            }
            assert(!data.isEmpty, "land base data empty")
            let src = MLNShapeSource(identifier: "land", shape: shape, options: nil)
            style.addSource(src)
            let fill = MLNFillStyleLayer(identifier: "land-fill", source: src)
            // Muted slate-green land, clearly distinct from the #0b1a2b sea (so coastlines read outside FAA
            // coverage) but quiet enough not to fight the chart/route/airspace colors where a pack IS mounted.
            fill.fillColor = NSExpression(forConstantValue: UIColor(red: 0.20, green: 0.28, blue: 0.29, alpha: 1))
            let coast = MLNLineStyleLayer(identifier: "coastline", source: src)
            coast.lineColor = NSExpression(forConstantValue: UIColor(red: 0.40, green: 0.52, blue: 0.55, alpha: 0.7))
            coast.lineWidth = NSExpression(forConstantValue: 0.7)
            if let bg = style.layer(withIdentifier: "bg") {
                style.insertLayer(fill, above: bg); style.insertLayer(coast, above: fill)
            } else {
                style.addLayer(fill); style.addLayer(coast)
            }
        }

        /// Airways line + airspace fill/outline, stacked bottom-most of the vector context.
        private func setupAirwayAirspaceLayers(_ style: MLNStyle) {
            let awySrc = MLNShapeSource(identifier: "airways", shape: nil, options: nil)
            style.addSource(awySrc)
            let awy = MLNLineStyleLayer(identifier: "airways-line", source: awySrc)
            awy.lineColor = NSExpression(forConstantValue: UIColor(red: 0.42, green: 0.58, blue: 0.86, alpha: 0.75))
            awy.lineWidth = NSExpression(forConstantValue: 1.6)
            awy.lineCap = NSExpression(forConstantValue: "round"); awy.lineJoin = NSExpression(forConstantValue: "round")
            awy.minimumZoomLevel = 4.5              // the scale<9 gate
            style.addLayer(awy)

            let aspSrc = MLNShapeSource(identifier: "airspace", shape: nil, options: nil)
            style.addSource(aspSrc)
            let fill = MLNFillStyleLayer(identifier: "airspace-fill", source: aspSrc)
            fill.fillColor = Self.aspColorExpr()
            fill.fillOpacity = Self.aspOpacityExpr()
            fill.minimumZoomLevel = 4.0
            style.addLayer(fill)
            let outline = MLNLineStyleLayer(identifier: "airspace-outline", source: aspSrc)
            outline.lineColor = Self.aspColorExpr()
            outline.lineWidth = Self.aspWidthExpr()
            outline.lineCap = NSExpression(forConstantValue: "round"); outline.lineJoin = NSExpression(forConstantValue: "round")
            outline.minimumZoomLevel = 4.0
            style.addLayer(outline)
        }

        /// TEXT LABELS (need the bundled SDF glyphs, wired via the style's "glyphs" URL): airway idents +
        /// airspace altitude blocks. The airway label reuses the already-added "airways" source.
        private func setupLabelLayers(_ style: MLNStyle) {
            guard let awySrc = style.source(withIdentifier: "airways") as? MLNShapeSource else { return }
            // Airway idents — one per run, placed along the line centre (white text, slate-blue halo).
            let awyLabel = MLNSymbolStyleLayer(identifier: "airways-label", source: awySrc)
            awyLabel.text = NSExpression(forKeyPath: "ident")
            awyLabel.symbolPlacement = NSExpression(forConstantValue: "line-center")
            awyLabel.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            awyLabel.textFontSize = NSExpression(forConstantValue: 10)
            awyLabel.textColor = NSExpression(forConstantValue: UIColor.white)
            awyLabel.textHaloColor = NSExpression(forConstantValue: UIColor(red: 0.42, green: 0.58, blue: 0.86, alpha: 0.9))
            awyLabel.textHaloWidth = NSExpression(forConstantValue: 1.4)
            awyLabel.minimumZoomLevel = 5.0
            awyLabel.symbolSortKey = NSExpression(forConstantValue: 1)   // yields to everything else
            style.addLayer(awyLabel)

            // Airspace altitude blocks (ceiling over floor) — its own point source at each area's north edge.
            let aspLabelSrc = MLNShapeSource(identifier: "airspace-labels", shape: nil, options: nil)
            style.addSource(aspLabelSrc)
            let aspLabel = MLNSymbolStyleLayer(identifier: "airspace-label", source: aspLabelSrc)
            aspLabel.text = NSExpression(forKeyPath: "alt")             // two lines: "\(ceil)\n\(floor)"
            aspLabel.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            aspLabel.textFontSize = NSExpression(forConstantValue: 9)
            aspLabel.textColor = Self.aspColorExpr()                    // class colour, like AirspaceLabelView
            aspLabel.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.6))
            aspLabel.textHaloWidth = NSExpression(forConstantValue: 1.2)
            aspLabel.textLineHeight = NSExpression(forConstantValue: 1.0)
            aspLabel.minimumZoomLevel = 5.0
            style.addLayer(aspLabel)
        }

        /// NAV SYMBOLS — FAA glyphs (VOR/VORTAC/NDB/fix/airport) as an icon-image layer with the ident
        /// below, above airspace so navaids read clearly. Reuses the app's exact symbols.
        private func setupNavLayers(_ style: MLNStyle) {
            registerNavImages(style)
            let navSrc = MLNShapeSource(identifier: "nav", shape: nil, options: nil)
            style.addSource(navSrc)
            let nav = MLNSymbolStyleLayer(identifier: "nav-sym", source: navSrc)
            nav.iconImageName = NSExpression(forKeyPath: "glyph")       // "nav-vor" / "nav-fix" / … set per feature
            nav.iconAllowsOverlap = NSExpression(forConstantValue: false)
            nav.text = NSExpression(forKeyPath: "ident")
            nav.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            nav.textFontSize = NSExpression(forConstantValue: 9)
            nav.textColor = NSExpression(forConstantValue: UIColor.white)
            nav.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.85))
            nav.textHaloWidth = NSExpression(forConstantValue: 1.2)
            nav.textAnchor = NSExpression(forConstantValue: "top")      // ident under the glyph
            nav.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.9)))
            nav.textOptional = NSExpression(forConstantValue: true)     // drop the ident before the glyph on collision
            nav.minimumZoomLevel = 5.5
            style.addLayer(nav)
        }

        /// TFR + route + traffic + ownship layers (empty; driven by updateUIView, not by region). Stacked on
        /// top of the static context so the route/traffic/ownship read above everything (as MK annotations do).
        private func setupDynamicLayers(_ style: MLNStyle) {
            let red = ChartMapView.Coordinator.airspaceColor("TFR")     // #F71433 — reuse, no hand-typed hex
            let tfrSrc = MLNShapeSource(identifier: "tfr", shape: nil, options: nil); style.addSource(tfrSrc)
            let tfrFill = MLNFillStyleLayer(identifier: "tfr-fill", source: tfrSrc)   // no minzoom: TFRs show at any zoom
            tfrFill.fillColor = NSExpression(forConstantValue: red); tfrFill.fillOpacity = NSExpression(forConstantValue: 0.18)
            style.addLayer(tfrFill)
            let tfrLine = MLNLineStyleLayer(identifier: "tfr-outline", source: tfrSrc)
            tfrLine.lineColor = NSExpression(forConstantValue: red); tfrLine.lineWidth = NSExpression(forConstantValue: 2.4)
            tfrLine.lineCap = NSExpression(forConstantValue: "round"); tfrLine.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(tfrLine)
            let tfrLblSrc = MLNShapeSource(identifier: "tfr-labels", shape: nil, options: nil); style.addSource(tfrLblSrc)
            let tfrLbl = MLNSymbolStyleLayer(identifier: "tfr-label", source: tfrLblSrc)
            tfrLbl.text = NSExpression(forKeyPath: "alt"); tfrLbl.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            tfrLbl.textFontSize = NSExpression(forConstantValue: 9); tfrLbl.textColor = NSExpression(forConstantValue: red)
            tfrLbl.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.6))
            tfrLbl.textHaloWidth = NSExpression(forConstantValue: 1.2); tfrLbl.textLineHeight = NSExpression(forConstantValue: 1.0)
            tfrLbl.minimumZoomLevel = 5.0
            style.addLayer(tfrLbl)

            // Flight-recorder breadcrumb (where the aircraft HAS BEEN) — translucent orange, BELOW the route so
            // the magenta filed route reads over it, both above the FAA raster / TFR and below traffic/ownship.
            let trackSrc = MLNShapeSource(identifier: "track", shape: nil, options: nil); style.addSource(trackSrc)
            let track = MLNLineStyleLayer(identifier: "track-line", source: trackSrc)
            track.lineColor = NSExpression(forConstantValue: UIColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 0.85))
            track.lineWidth = NSExpression(forConstantValue: 4.0)
            track.lineCap = NSExpression(forConstantValue: "round"); track.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(track)

            // Route (persistent source so ownship/traffic can sit above it).
            let routeSrc = MLNShapeSource(identifier: "route", shape: nil, options: nil); style.addSource(routeSrc)
            let route = MLNLineStyleLayer(identifier: "route-line", source: routeSrc)
            route.lineColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 1))
            route.lineWidth = NSExpression(forConstantValue: 3.0)
            route.lineCap = NSExpression(forConstantValue: "round"); route.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(route)

            style.setImage(ChartMapView.Coordinator.traffic, forName: "own-traffic")
            style.setImage(ChartMapView.Coordinator.ownPlane, forName: "own-ship")
            let trafficSrc = MLNShapeSource(identifier: "traffic", shape: nil, options: nil); style.addSource(trafficSrc)
            let traffic = MLNSymbolStyleLayer(identifier: "traffic-sym", source: trafficSrc)
            traffic.iconImageName = NSExpression(forConstantValue: "own-traffic")
            traffic.iconRotation = NSExpression(forKeyPath: "rot")          // pre-baked (track - 90)
            traffic.iconRotationAlignment = NSExpression(forConstantValue: "map")
            traffic.iconAllowsOverlap = NSExpression(forConstantValue: true)   // traffic must never collide away
            traffic.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(traffic)
            let ownSrc = MLNShapeSource(identifier: "ownship", shape: nil, options: nil); style.addSource(ownSrc)
            let own = MLNSymbolStyleLayer(identifier: "ownship-sym", source: ownSrc)
            own.iconImageName = NSExpression(forConstantValue: "own-ship")
            own.iconRotation = NSExpression(forKeyPath: "rot")             // pre-baked (course - 90)
            own.iconRotationAlignment = NSExpression(forConstantValue: "map")
            // Screen-flat billboard (heading via rotation-alignment=map). Pitch-alignment defaults to "auto",
            // which inherits rotation-alignment="map" -> pitch-with-map. That resolves the ownship's anchor through
            // the map-pixel label plane, so on the globe it floats off the sphere (and on a pitched flat map it would
            // tilt away). Pinning pitch-alignment=viewport keeps it a top-down screen billboard so the globe fork
            // projects its anchor onto the sphere; visually identical on the flat top-down map (pitch 0).
            own.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
            own.iconAllowsOverlap = NSExpression(forConstantValue: true)
            own.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(own)
        }

        /// Register the FAA nav glyphs (reusing the app's exact NearbyMarkerView drawings) under the names
        /// the layer's `iconImageName` expression selects per feature. Idempotent.
        private func registerNavImages(_ style: MLNStyle) {
            let images: [String: UIImage] = [
                "nav-airport": NearbyMarkerView.airportGlyphImage,
                "nav-fix": NearbyMarkerView.fixGlyphImage,
                "nav-vor": NearbyMarkerView.navaidGlyph("VOR"),
                "nav-vortac": NearbyMarkerView.navaidGlyph("VORTAC"),
                "nav-vordme": NearbyMarkerView.navaidGlyph("VOR-DME"),
                "nav-ndb": NearbyMarkerView.navaidGlyph("NDB"),
                "nav-ndbdme": NearbyMarkerView.navaidGlyph("NDB-DME"),
                "nav-tacan": NearbyMarkerView.navaidGlyph("TACAN"),
                "nav-dme": NearbyMarkerView.navaidGlyph("DME"),
            ]
            assert(images.count == 9, "expected 9 nav glyphs")
            assert(images.values.allSatisfy { $0.size.width > 0 }, "a nav glyph failed to render")
            for (name, img) in images { style.setImage(img, forName: name) }   // bounded (rule 2)
        }

        /// The registered image name for a nav point, mirroring NearbyMarkerView.navaidGlyph's classification.
        static func glyphName(_ np: NavPoint) -> String {
            switch np.kind {
            case .airport: return "nav-airport"
            case .vor:     return navGlyph(forType: NavMeta.navaid(np.ident)?.type ?? "VOR")
            default:       return "nav-fix"
            }
        }

        /// Pure classification of a navaid's FAA type string → glyph name. Extracted from glyphName so it's
        /// unit-testable with NO NavMeta/DB dependency. Order matters: TACAN and the *DME combinations are
        /// checked before the plain-VOR fallback (a TACAN/DME must NOT imply a VOR glyph).
        static func navGlyph(forType rawType: String) -> String {
            let t = rawType.uppercased()
            if t == "TACAN" { return "nav-tacan" }
            if t.contains("VORTAC") { return "nav-vortac" }
            if t.contains("NDB"), t.contains("DME") { return "nav-ndbdme" }
            if t.contains("NDB") { return "nav-ndb" }
            if t == "DME" { return "nav-dme" }
            if t.contains("DME") { return "nav-vordme" }
            return "nav-vor"
        }

        /// Query the vector overlays for the settled region OFF-MAIN (gated on angular scale, exactly like
        /// refreshContext), then set the features on the persistent sources on the main actor. Orchestrator
        /// only — the per-overlay feature building lives in the bounded static builders below (rule 4).
        private func refreshOverlays(_ mapView: MLNMapView) {
            let b = mapView.visibleCoordinateBounds
            guard b.ne.latitude > b.sw.latitude, b.ne.longitude > b.sw.longitude else { return }  // antimeridian/degenerate
            // Visible span in degrees. Mirror the production MK gate max(latΔ, lonΔ·cos(lat)) — a lat-only
            // scale UNDER-estimates the span in landscape (the common iPad-in-cockpit orientation, where the
            // longitude span dominates), which would flood the map with nav/fix/airway features + labels the
            // production map suppresses at that zoom.
            let latD = b.ne.latitude - b.sw.latitude
            let lonD = b.ne.longitude - b.sw.longitude
            let midLat = (b.ne.latitude + b.sw.latitude) * 0.5
            let scale = max(latD, lonD * cos(midLat * .pi / 180))
            assert(scale > 0, "refreshOverlays: non-positive scale")
            assert(overlayGen >= 0, "refreshOverlays: generation underflow")
            let m = 0.15
            let bb = BBox(minLat: b.sw.latitude - latD * m, minLon: b.sw.longitude - lonD * m,
                          maxLat: b.ne.latitude + latD * m, maxLon: b.ne.longitude + lonD * m)
            if scale < 2.2 { wantFixes = true } else if scale > 2.7 { wantFixes = false }   // hysteresis dead band
            // Gate on the MapLayersMenu toggles AND the zoom scale — a toggle OFF makes the builder return []
            // so the source clears (parity with ChartMapView's showAirspace/showNearby/showAirways).
            let wantAir = showAirspace && scale < 14, wantLbl = showAirspace && scale < 7
            let wantAwy = showAirways && scale < 9, wantNear = showNearby && scale < 5.5
            let showFixes = wantNear && wantFixes
            overlayGen += 1
            let gen = overlayGen
            Task { @MainActor in
                let f = await Task.detached(priority: .userInitiated) {
                    () -> (asp: [MLNPolygonFeature], lbl: [MLNPointFeature], awy: [MLNPolylineFeature], nav: [MLNPointFeature]) in
                    let a = Coordinator.airspaceFeatures(bb, want: wantAir, labels: wantLbl)
                    return (a.polys, a.labels, Coordinator.airwayFeatures(bb, want: wantAwy),
                            Coordinator.navFeatures(bb, near: wantNear, fixes: showFixes))
                }.value
                guard gen == self.overlayGen, let style = mapView.style else { return }
                (style.source(withIdentifier: "airspace") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.asp)
                (style.source(withIdentifier: "airspace-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.lbl)
                (style.source(withIdentifier: "airways") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.awy)
                (style.source(withIdentifier: "nav") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.nav)
            }
        }

        /// Airspace polygons (1 per ring, "cls" attr) + altitude-block points, capped + safety-sorted like
        /// refreshContext. nonisolated (runs in the detached task). Bounded loops (rule 2), >=2 assertions.
        static func airspaceFeatures(_ bb: BBox, want: Bool, labels: Bool) -> (polys: [MLNPolygonFeature], labels: [MLNPointFeature]) {
            assert(bb.minLat <= bb.maxLat && bb.minLon <= bb.maxLon, "airspaceFeatures: degenerate box")
            guard want else { return ([], []) }
            let order: [String: Int] = ["TFR": 0, "P": 1, "R": 2, "B": 3, "C": 4, "W": 5, "MOA": 6, "A": 7, "D": 8]
            let list = NavDatabase.airspaces(intersecting: bb)
                .sorted { (order[$0.cls] ?? 9, $0.name) < (order[$1.cls] ?? 9, $1.name) }
            var polys: [MLNPolygonFeature] = []
            building: for a in list {
                for ring in a.rings {                                      // bounded by the 260 cap
                    var c = ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                    var at: [String: Any] = ["cls": a.cls, "name": a.name]   // name/floor/ceiling for the tap card
                    if let fl = a.floorFt { at["floorFt"] = fl }
                    if let cl = a.ceilingFt { at["ceilingFt"] = cl }         // omit nil ints (MLN attrs reject NSNull)
                    f.attributes = at
                    polys.append(f)
                    if polys.count >= 260 { break building }
                }
            }
            var lbls: [MLNPointFeature] = []
            if labels {
                for a in list where lbls.count < 140 {                     // bounded (rule 2)
                    guard let top = a.rings.flatMap({ $0 }).max(by: { $0.lat < $1.lat }) else { continue }
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon)
                    f.attributes = ["cls": a.cls,
                                    "alt": "\(AirspaceLabelAnnotation.altText(a.ceilingFt))\n\(AirspaceLabelAnnotation.altText(a.floorFt))"]
                    lbls.append(f)
                }
            }
            assert(polys.count <= 260 && lbls.count <= 140, "airspaceFeatures: caps exceeded")
            return (polys, lbls)
        }

        /// One polyline per already-split airway run. nonisolated. Bounded by Airways.inRegion's own caps.
        static func airwayFeatures(_ bb: BBox, want: Bool) -> [MLNPolylineFeature] {
            assert(bb.minLat <= bb.maxLat, "airwayFeatures: degenerate box")
            guard want else { return [] }
            var out: [MLNPolylineFeature] = []
            for seg in Airways.inRegion(bb) where seg.points.count >= 2 {   // bounded (Airways caps at 80 idents)
                var c = seg.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let f = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
                f.attributes = ["ident": seg.ident, "area": seg.area]      // for the future tap card
                out.append(f)
            }
            assert(out.count <= 4096, "airwayFeatures: unexpectedly many runs")
            return out
        }

        /// Nearby airports/navaids (+ terminal/approach fixes when zoomed in), one point each carrying its
        /// FAA-glyph name + ident. Deduped by ident. nonisolated. Bounded by the query limits (rule 2).
        static func navFeatures(_ bb: BBox, near: Bool, fixes: Bool) -> [MLNPointFeature] {
            assert(bb.minLat <= bb.maxLat, "navFeatures: degenerate box")
            guard near else { return [] }
            var out: [MLNPointFeature] = []
            var seen = Set<String>()
            for np in NavDatabase.nearby(bb, types: [0, 1], limit: 160) where seen.insert(np.ident).inserted {
                out.append(navFeature(np))
            }
            if fixes {
                for np in NavDatabase.nearby(bb, types: [2], limit: 90) where seen.insert(np.ident).inserted {
                    out.append(navFeature(np))
                }
                for np in CIFP.terminalFixes(inRegion: bb, limit: 120) where seen.insert(np.ident).inserted {
                    out.append(navFeature(np))
                }
            }
            assert(out.count <= 370, "navFeatures: exceeded the combined query cap")
            return out
        }
        private static func navFeature(_ np: NavPoint) -> MLNPointFeature {
            let f = MLNPointFeature()
            f.coordinate = CLLocationCoordinate2D(latitude: np.coord.lat, longitude: np.coord.lon)
            f.attributes = ["glyph": glyphName(np), "ident": np.ident]
            return f
        }

        /// "#RRGGBB" from the app's canonical `airspaceColor` (reused verbatim — no hand-typed hex).
        private static func hex(_ cls: String) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
            ChartMapView.Coordinator.airspaceColor(cls).getRed(&r, green: &g, blue: &bl, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(bl * 255))
        }
        // Data-driven paint props keyed on the "cls" feature attribute (default covers B & D — chart blue).
        private static func aspColorExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "C", hex("C"), "TFR", hex("TFR"), "R", hex("R"), "P", hex("P"),
                "W", hex("W"), "A", hex("A"), "MOA", hex("MOA"), hex("B")])
        }
        private static func aspOpacityExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "P", 0.18, "TFR", 0.18, "R", 0.10, "W", 0.10, "A", 0.10, "MOA", 0.10, 0.05])
        }
        private static func aspWidthExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "R", 2.4, "P", 2.4, "TFR", 2.4, "W", 1.8, "A", 1.8, "MOA", 1.8, "B", 1.5, "C", 1.5, 1.2])
        }

        private func ensureVisiblePacks(_ mapView: MLNMapView) {
            let b = mapView.visibleCoordinateBounds
            let ne = MKMapPoint(b.ne), sw = MKMapPoint(b.sw)
            let rect = MKMapRect(x: min(ne.x, sw.x), y: min(ne.y, sw.y),
                                 width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
            Task { @MainActor in
                await store.ensureVisible(rect, layer: layer)      // the selected FAA base (sectional/IFR-low/high)
                syncFAASource(on: mapView)                          // surface whatever is now mounted
            }
        }

        /// Hand the store's currently-mounted packs to the loopback tile server and (re)mount the "faa" raster
        /// whenever the mounted SET or the selected layer changes. Runs on EVERY apply (not only on a pan /
        /// layer-switch) so packs whose DOWNLOAD completes AFTER ensureVisiblePacks already returned — e.g.
        /// store.setLayer's route-corridor download landing over slow Wi-Fi — appear the instant store.readers
        /// publishes, instead of a blank chart until the pilot pans (the build-63 IFR-low-wouldn't-load bug; the
        /// classic ChartMapView reconciles its `readers` prop every updateUIView, which the port had dropped).
        /// A (layer + sorted packID) signature makes an unchanged set a cheap no-op. Bounded (≤64), ≥2 asserts.
        @MainActor private func syncFAASource(on map: MLNMapView) {
            guard serverPort > 0, let style = map.style else { return }
            let readers = store.readers
            assert(readers.count <= 64, "syncFAASource: unexpectedly many packs mounted")
            let sig = "\(layer.rawValue)#" + readers.map(\.packID).sorted().joined(separator: ",")
            guard sig != servedReadersSig else { return }          // same set + layer → nothing to remount
            servedReadersSig = sig
            server.setReaders(readers)
            // ORDER MATTERS: remove the LAYER before the SOURCE (MapLibre throws otherwise), then re-add so it
            // re-requests tiles it 404'd while the set was empty/different. Cap maxzoom at the packs' real max.
            if let faaLayer = style.layer(withIdentifier: "faa") { style.removeLayer(faaLayer) }
            if let src = style.source(withIdentifier: "faa") { style.removeSource(src) }
            let faaMax = readers.map(\.maxZoom).max() ?? 16
            assert(faaMax >= 0, "syncFAASource: negative maxzoom")
            let fresh = MLNRasterTileSource(identifier: "faa",
                tileURLTemplates: ["http://127.0.0.1:\(serverPort)/{z}/{x}/{y}"],
                options: [.tileSize: 256,
                          .maximumZoomLevel: NSNumber(value: faaMax + MBTilesTileOverlay.overzoomLevels)])
            style.addSource(fresh)
            let faaRaster = MLNRasterStyleLayer(identifier: "faa", source: fresh)   // BOTTOM (below the first vector layer)
            // Anchor the OPAQUE FAA chart BELOW the translucent radar when the radar exists — else a pack
            // remount (pan to new coverage, VFR⇄IFR switch, late download) re-inserts faa above the radar
            // (they shared the "airways-line" anchor) and the precipitation vanishes until the next ~10-min
            // frame rollover (a red-hat finding). Falls back to the old anchor when radar is off.
            if let radar = style.layer(withIdentifier: "wxradar-layer") { style.insertLayer(faaRaster, below: radar) }
            else if let bottom = style.layer(withIdentifier: "airways-line") { style.insertLayer(faaRaster, below: bottom) }
            else { style.addLayer(faaRaster) }
        }

        // MARK: route line

        func updateRoute(_ coords: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            routeCoords = coords
            guard let src = mapView.style?.source(withIdentifier: "route") as? MLNShapeSource else { return }
            let sig = coords.map { "\(Self.q($0.latitude)),\(Self.q($0.longitude))" }.joined(separator: "|")
            guard sig != appliedRouteSig else { return }                 // unchanged → skip the re-tessellation
            appliedRouteSig = sig
            guard coords.count >= 2 else { src.shape = nil; return }
            var c = coords
            src.shape = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
        }

        /// Live precipitation-radar raster (RainViewer). A remote raster source added ABOVE the FAA chart but
        /// BELOW the vector overlays. The tile URL rolls over ~every 10 min → remove/re-add the source when the
        /// template changes (or is cleared). Signature-gated so an unchanged template is a no-op per tick.
        func updateRadar(_ template: String?, on map: MLNMapView) {
            guard let style = map.style else { return }
            guard appliedRadarTemplate == nil || appliedRadarTemplate! != template else { return }  // unchanged
            appliedRadarTemplate = .some(template)
            if let l = style.layer(withIdentifier: "wxradar-layer") { style.removeLayer(l) }
            if let s = style.source(withIdentifier: "wxradar") { style.removeSource(s) }
            guard let template else { return }   // nil → radar off (removed above)
            // maximumZoomLevel 7: RainViewer's free tier serves a "Zoom Level Not Supported" PLACEHOLDER
            // IMAGE past z7 (verified byte-identical tiles z8+), which would tile that error text across the
            // chart. Capped, MapLibre natively overzooms (upscales) the z7 tiles at closer zooms instead.
            let src = MLNRasterTileSource(identifier: "wxradar", tileURLTemplates: [template],
                                          options: [.tileSize: 256, .maximumZoomLevel: 7])
            style.addSource(src)
            let layer = MLNRasterStyleLayer(identifier: "wxradar-layer", source: src)
            layer.rasterOpacity = NSExpression(forConstantValue: 0.6)   // translucent — chart reads underneath
            if let above = style.layer(withIdentifier: "airways-line") {   // above faa, below the vector overlays
                style.insertLayer(layer, below: above)
            } else {
                style.addLayer(layer)
            }
        }

        /// The flight-recorder breadcrumb. Append-only during a recording + reset-to-empty on stop, so the
        /// POINT COUNT is a sufficient (and cheapest) change signature — no per-point string like the route.
        /// BATTERY: skips the re-tessellation on every unrelated updateUIView tick.
        func updateTrack(_ coords: [CLLocationCoordinate2D], on map: MLNMapView) {
            trackCoords = coords
            guard let src = map.style?.source(withIdentifier: "track") as? MLNShapeSource else { return }
            guard coords.count != appliedTrackCount else { return }      // only rebuild when a point was added/cleared
            appliedTrackCount = coords.count
            guard coords.count >= 2 else { src.shape = nil; return }
            assert(coords.count <= 200_000, "updateTrack: breadcrumb unbounded — recorder must cap")
            var c = coords
            src.shape = MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
        }

        // MARK: ownship + traffic (milestone 5)

        private var lastOwnship: CLLocationCoordinate2D?
        private var lastOwnCourse: Double?
        private var lastTraffic: [Aircraft] = []
        // Last-APPLIED signatures — early-return guards so an unrelated AppModel publish (e.g. the audio VU
        // meter, ~10-30×/s) can't re-tessellate + re-upload unchanged route/ownship/traffic/TFR geometry.
        // These are the map inputs' identity, distinct from the last-INPUT caches above (which exist so
        // didFinishLoading can re-apply). Set ONLY after a real apply, so the first post-style apply still runs.
        private var appliedRouteSig: String?
        private var appliedOwnSig: String?
        private var appliedTrafficSig: String?
        private var appliedTFRSig: String?
        static func q(_ v: Double) -> Int { Int((v * 100_000).rounded()) }   // ~1 m quantization, kills float jitter
        // BATTERY: the ownship/traffic change-detection is coarser than the route's (~12 m + 3° dead band). A
        // PARKED aircraft's normal 3-5 m GPS jitter (Stratux streams ~1 Hz with no distanceFilter) otherwise
        // crosses the fine ~1 m bucket every fix → `src.shape =` reassign → full-scene redraw + a 300 ms symbol
        // fade → near-continuous idle GPU (the reported heat). The displayed feature still uses RAW lat/lon
        // (positions/taps unchanged); only the "did it move enough to redraw" test coarsens.
        static func qJit(_ v: Double) -> Int { Int((v * 9_000).rounded()) }   // ~12 m idle-jitter dead band
        static func qDeg(_ d: Double) -> Int { Int((d / 3).rounded()) }       // ~3° heading dead band

        /// A single static ownship marker (no pulsing showsUserLocation dot — we render our own). The SF
        /// "airplane" glyph draws nose-EAST, so rot = course - 90 to make the nose point along the heading.
        func updateOwnship(_ coord: CLLocationCoordinate2D?, course: Double?, on map: MLNMapView) {
            lastOwnship = coord; lastOwnCourse = course
            guard let src = map.style?.source(withIdentifier: "ownship") as? MLNShapeSource else { return }
            let sig = coord.map { "\(Self.qJit($0.latitude)),\(Self.qJit($0.longitude)),\(Self.qDeg(course ?? 0))" } ?? "nil"
            guard sig != appliedOwnSig else { return }
            appliedOwnSig = sig
            guard let coord else { src.shape = nil; return }             // no fix → hide (MK removes the annotation)
            let f = MLNPointFeature(); f.coordinate = coord
            f.attributes = ["rot": (course.map { $0 - 90 } ?? 0)]
            src.shape = f
        }

        /// Live ADS-B/Stratux traffic, deduped by ICAO hex, rotated by track. Bounded (rule 2).
        func updateTraffic(_ aircraft: [Aircraft], on map: MLNMapView) {
            lastTraffic = aircraft
            guard let src = map.style?.source(withIdentifier: "traffic") as? MLNShapeSource else { return }
            var seen = Set<String>(); var out: [MLNPointFeature] = []; var sigs: [String] = []
            for ac in aircraft.prefix(128) {                             // bounded (rule 2)
                guard let c = ac.coordinate, !ac.hex.isEmpty, seen.insert(ac.hex).inserted else { continue }
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
                f.attributes = ["rot": (ac.trackDeg ?? 0) - 90, "hex": ac.hex, "label": ac.label ?? "Traffic"]
                out.append(f)
                sigs.append("\(ac.hex):\(Self.qJit(c.lat)),\(Self.qJit(c.lon)),\(Self.qDeg(ac.trackDeg ?? 0))")
            }
            assert(out.count <= 128, "updateTraffic: field bound exceeded")
            assert(seen.count == out.count, "updateTraffic: dedup/emit mismatch")
            let sig = sigs.sorted().joined(separator: "|")               // order-independent snapshot identity
            guard sig != appliedTrafficSig else { return }
            appliedTrafficSig = sig
            src.shape = MLNShapeCollectionFeature(shapes: out)
        }

        // MARK: live TFRs (milestone 6)

        func updateTFRs(_ tfrs: [TFR], on map: MLNMapView) {
            cachedTFRs = tfrs
            tfrByID = Dictionary(tfrs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            guard let style = map.style else { return }                  // style not up yet → didFinishLoading re-applies
            let sig = tfrs.map { "\($0.id):\($0.polygon.count):\($0.ceilingFt ?? -1):\($0.floorFt ?? -1)" }
                .sorted().joined(separator: "|")
            guard sig != appliedTFRSig else { return }                   // unchanged TFR set → skip rebuild
            appliedTFRSig = sig
            let f = Coordinator.tfrFeatures(tfrs)
            (style.source(withIdentifier: "tfr") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.polys)
            (style.source(withIdentifier: "tfr-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.labels)
        }

        /// One polygon per TFR (single ring) + an altitude-block point. nonisolated; bounded; >=2 assertions.
        static func tfrFeatures(_ tfrs: [TFR]) -> (polys: [MLNPolygonFeature], labels: [MLNPointFeature]) {
            assert(tfrs.count <= 4096, "tfrFeatures: absurd TFR count")
            var polys: [MLNPolygonFeature] = []; var lbls: [MLNPointFeature] = []
            for t in tfrs.prefix(400) where t.polygon.count >= 3 {       // bounded + ring guard (TFRMapLayer)
                var c = t.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                f.attributes = ["id": t.id, "cls": "TFR"]
                polys.append(f)
                if let top = t.labelCoord {
                    let p = MLNPointFeature(); p.coordinate = CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon)
                    p.attributes = ["alt": "\(AirspaceLabelAnnotation.altText(t.ceilingFt))\n\(AirspaceLabelAnnotation.altText(t.floorFt))"]
                    lbls.append(p)
                }
            }
            assert(polys.count <= 400, "tfrFeatures: cap exceeded")
            return (polys, lbls)
        }

        // MARK: georeferenced plate overlay (milestone 7)

        /// Add / update-in-place / remove the overlaid approach plate as an MLNImageSource (a warped raster
        /// from the 4 geo corners). rasterOpacity + image swap are honored GPU props — no rebuild, no mask
        /// hack (the layer covers the context labels via z-order, yet stays BELOW ownship/traffic).
        func updatePlate(_ s: PlateOverlayState?, on map: MLNMapView) {
            plateState = s
            guard let style = map.style else { return }
            assert(Thread.isMainThread, "updatePlate off the main thread")
            guard let s else {
                if let l = style.layer(withIdentifier: "plate-raster") { style.removeLayer(l) }
                if let src = style.source(withIdentifier: "plate") { style.removeSource(src) }
                plateKey = nil; plateOpacity = nil; plateInverted = nil; plateImageKey = nil
                plateCornersCoord = nil; onPlateAnchors(nil); return   // hide the corner gear
            }
            assert((0.0...1.0).contains(s.opacity), "plate opacity out of range")
            // The plate's RENDERED-bitmap identity: pdf selects the page, inverted selects normal/night render.
            // geoKey is PLACEMENT-only, so without this the raster would go stale on a plate SWAP (a pilot would
            // see the WRONG approach chart warped onto the new airport's footprint) — a safety-critical bug.
            let imgKey = "\(s.pdf)|\(s.inverted)"
            let isNewPlate = style.source(withIdentifier: "plate") == nil
            if let src = style.source(withIdentifier: "plate") as? MLNImageSource,
               let layer = style.layer(withIdentifier: "plate-raster") as? MLNRasterStyleLayer {
                if plateKey != s.geoKey { src.coordinates = Coordinator.plateQuad(s) }
                if plateImageKey != imgKey { src.image = s.displayImage }   // refresh on plate swap OR invert
                if plateOpacity != s.opacity { layer.rasterOpacity = NSExpression(forConstantValue: s.opacity) }
            } else {
                let src = MLNImageSource(identifier: "plate", coordinateQuad: Coordinator.plateQuad(s), image: s.displayImage)
                style.addSource(src)
                let layer = MLNRasterStyleLayer(identifier: "plate-raster", source: src)
                layer.rasterOpacity = NSExpression(forConstantValue: s.opacity)
                layer.rasterOpacityTransition = MLNTransition(duration: 0, delay: 0)   // slider must be instant
                // Insert BELOW traffic/ownship so the 70%-opaque plate never washes out the ownship chevron
                // (MK draws annotations above overlays; without this the port inverts that safety-critical order).
                // Still above nav/airway/airspace labels (created earlier), so it covers the context labels.
                if let above = style.layer(withIdentifier: "traffic-sym") {
                    style.insertLayer(layer, below: above)
                } else {
                    style.addLayer(layer)
                }
            }
            plateKey = s.geoKey; plateOpacity = s.opacity; plateInverted = s.inverted; plateImageKey = imgKey
            // Feed the host chrome's corner gear (the ONLY path to dim/invert/hide/remove the plate) + frame
            // the plate on first load so it never loads off-screen (mirrors ChartMapView's mapFrameRect).
            plateCornersCoord = Coordinator.plateTopCorners(s)
            emitPlateAnchors(map)
            if isNewPlate { frameToPlate(s, on: map) }
        }

        /// The 4 geo corners as an MLNCoordinateQuad {topLeft, bottomLeft, bottomRight, topRight}.
        static func plateQuad(_ s: PlateOverlayState) -> MLNCoordinateQuad {
            return MLNCoordinateQuadMake(corner(s, -1, 1), corner(s, -1, -1), corner(s, 1, -1), corner(s, 1, 1))
        }
        /// The plate's TOP-left/-right geo corners (chrome-anchor coords), matching plateQuad's corner order.
        static func plateTopCorners(_ s: PlateOverlayState) -> (tl: CLLocationCoordinate2D, tr: CLLocationCoordinate2D) {
            (corner(s, -1, 1), corner(s, 1, 1))
        }
        private static func corner(_ s: PlateOverlayState, _ dx: Double, _ dy: Double) -> CLLocationCoordinate2D {
            PlatePlacement.corner(centerLat: s.centerLat, centerLon: s.centerLon,
                                  widthMeters: s.widthMeters, heightMeters: s.heightMeters,
                                  rotationDeg: s.rotationDeg, dxSign: dx, dySign: dy)
        }

        /// Frame the loaded plate: fit all 4 corners in view (with padding) so it never opens off-screen.
        private func frameToPlate(_ s: PlateOverlayState, on map: MLNMapView) {
            let cs = [Coordinator.corner(s, -1, 1), Coordinator.corner(s, -1, -1),
                      Coordinator.corner(s, 1, -1), Coordinator.corner(s, 1, 1)]
            let lats = cs.map(\.latitude), lons = cs.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }
            let sw = CLLocationCoordinate2D(latitude: minLat, longitude: minLon)
            let ne = CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
            map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne),
                                           edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 80, right: 60),
                                           animated: true, completionHandler: nil)
        }

        /// Project the plate's top-corner geo coords to SCREEN points and stream them to the host chrome
        /// (called on every region tick so the corner gear rides the plate through pans/zooms).
        func emitPlateAnchors(_ map: MLNMapView) {
            guard let c = plateCornersCoord else { return }
            onPlateAnchors((map.convert(c.tl, toPointTo: map), map.convert(c.tr, toPointTo: map)))
        }

        // MARK: layer / overlay-toggle / focus application (tab-parity inputs)

        /// Switch the FAA base layer (sectional ↔ IFR-low ↔ IFR-high). A real change re-requests packs +
        /// re-adds the faa source for the new layer (ensureVisiblePacks). The first apply just records.
        func applyLayer(_ new: ChartLayer, on map: MLNMapView) {
            layer = new
            defer { appliedLayer = new }
            guard let prev = appliedLayer, prev != new, map.style != nil else { return }
            ensureVisiblePacks(map)
        }

        /// Apply the MapLayersMenu overlay toggles; a real change re-runs refreshOverlays so a toggled-off
        /// layer clears (the builders return [] when its `want` is false).
        func applyOverlayToggles(_ air: Bool, _ near: Bool, _ awy: Bool, on map: MLNMapView) {
            showAirspace = air; showNearby = near; showAirways = awy
            let sig = "\(air)\(near)\(awy)"
            defer { appliedToggles = sig }
            guard let prev = appliedToggles, prev != sig, map.style != nil else { return }
            refreshOverlays(map)
        }

        /// Recenter on a search-result pick (keeps the current zoom). Only fires when `focus` changes.
        func applyFocus(_ focus: Coord?, on map: MLNMapView) {
            guard let focus, focus != lastFocus else { return }
            lastFocus = focus
            map.setCenter(CLLocationCoordinate2D(latitude: focus.lat, longitude: focus.lon), animated: true)
        }

        // MARK: tap-to-identify (milestone 8)

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let mv = map, gr.state == .ended else { return }
            probe(at: gr.location(in: mv), in: mv, radius: 24, userPoint: false)
        }
        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let mv = map else { return }
            probe(at: gr.location(in: mv), in: mv, radius: 40, userPoint: true)
        }

        /// Identify what's under the finger and present the same object card. Mirrors ChartMapView.beginProbe:
        /// the cheap screen-math runs on MAIN, the full-table nav scan + airspace containment run OFF-MAIN
        /// (so a tap never blocks the UI thread on SQLite during active map interaction), then the rendered-
        /// feature hit-tests + rank hop back to MAIN under a per-tap generation guard.
        private func probe(at pt: CGPoint, in mv: MLNMapView, radius: CGFloat, userPoint: Bool) {
            assert(radius > 0, "probe: non-positive radius")
            let ll = mv.convert(pt, toCoordinateFrom: mv)
            let here = Coord(lat: ll.latitude, lon: ll.longitude)
            // Box ~2.5× the tap radius (matches beginProbe) for the nav scan + airspace containment.
            let off = mv.convert(CGPoint(x: pt.x + radius * 2.5, y: pt.y + radius * 2.5), toCoordinateFrom: mv)
            let dLat = max(abs(ll.latitude - off.latitude), 0.002), dLon = max(abs(ll.longitude - off.longitude), 0.002)
            let box = BBox(minLat: ll.latitude - dLat, minLon: ll.longitude - dLon,
                           maxLat: ll.latitude + dLat, maxLon: ll.longitude + dLon)
            let wantAir = showAirspace
            probeGen &+= 1
            let gen = probeGen
            Task.detached(priority: .userInitiated) { [weak self] in
                let nearby = NavDatabase.nearby(box, types: [0, 1, 2], limit: 40)           // full-table scan — off main
                let airspaces = wantAir ? NavDatabase.airspaces(intersecting: box).filter { $0.containsCoord(here) } : []
                await MainActor.run { [weak self] in
                    guard let self, self.probeGen == gen else { return }   // a newer tap superseded this one
                    self.finishProbe(pt: pt, ll: ll, here: here, radius: radius, userPoint: userPoint,
                                     nearby: nearby, airspaces: airspaces, in: mv)
                }
            }
        }

        /// Main-actor finish: rank the nav-DB hits + rendered traffic/airway features by on-screen distance,
        /// then append the off-main airspace containment + geometric TFR containment (any zoom, not tessellation-
        /// limited) and the long-press user point. Present via onTapObjects → the same MapObjectSheet flow.
        @MainActor private func finishProbe(pt: CGPoint, ll: CLLocationCoordinate2D, here: Coord, radius: CGFloat,
                                            userPoint: Bool, nearby: [NavPoint], airspaces: [Airspace], in mv: MLNMapView) {
            let rect = CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)
            func dist(_ c: CLLocationCoordinate2D) -> Double { let s = mv.convert(c, toPointTo: mv); return Double(hypot(s.x - pt.x, s.y - pt.y)) }
            func dist(_ c: Coord) -> Double { dist(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)) }
            var cands: [(object: IdentifiedObject, distance: Double)] = []
            var seen = Set<String>()
            for np in nearby where seen.insert(np.ident).inserted {
                cands.append((IdentifiedObject(kind: MapObjectKind(routeKind: np.kind), ident: np.ident,
                                               coord: np.coord, onRoute: routeIdents.contains(np.ident)), dist(np.coord)))
            }
            for f in mv.visibleFeatures(in: rect, styleLayerIdentifiers: ["traffic-sym"]) {
                guard let label = f.attributes["label"] as? String else { continue }
                let c = (f as? MLNPointFeature)?.coordinate ?? ll
                cands.append((IdentifiedObject(kind: .traffic, ident: label,
                                               coord: Coord(lat: c.latitude, lon: c.longitude), onRoute: false), dist(c)))
            }
            for f in mv.visibleFeatures(in: rect, styleLayerIdentifiers: ["airways-line"]) {
                guard let id = f.attributes["ident"] as? String else { continue }
                cands.append((IdentifiedObject(kind: .airway, ident: id, coord: here, onRoute: false,
                                               airwayArea: (f.attributes["area"] as? String) ?? "USA"), 0))
            }
            var results = MapProbe.rank(cands, within: Double(radius))
            for asp in airspaces where !results.contains(where: { $0.kind == .airspace && $0.ident == asp.name }) {
                results.append(IdentifiedObject(kind: .airspace, ident: asp.name, coord: here, onRoute: false, airspace: asp))
            }
            for t in tfrByID.values where t.polygon.count >= 3 {           // geometric containment (any zoom)
                guard Geo.pointInRing(here, t.polygon), !results.contains(where: { $0.tfr?.id == t.id }) else { continue }
                results.append(IdentifiedObject(kind: .tfr, ident: t.id, coord: t.labelCoord ?? here, onRoute: false, tfr: t))
            }
            if userPoint { results.insert(IdentifiedObject(kind: .userPoint, ident: UserPoint.token(here), coord: here, onRoute: false), at: 0) }
            guard !results.isEmpty else { return }
            onTapObjects?(results)
        }
    }
}

/// Full-screen host: owns a ChartStore, downloads the route corridor, and shows the globe chart with an
/// EXPERIMENTAL banner + ✕. Uses the app's filed plan if present, else a demo route.
struct MapLibreChartScreen: View {
    @ObservedObject var model: AppModel                 // re-render body on plate/tfr/aircraft @Published changes
    var onClose: (() -> Void)?
    @StateObject private var store = ChartStore(library: ChartLibrary.shared)
    @StateObject private var metars = MetarStore()      // the tapped-object card's env objects (may stay empty)
    @StateObject private var forecasts = ForecastStore()
    @StateObject private var tafs = TafStore()
    @State private var didLoad = false
    // Device GPS is a NESTED ObservableObject that doesn't republish the parent — bridge it like MapHostView.
    @State private var deviceCoord: Coord?
    @State private var deviceCourse: Double?
    @State private var probe: MapProbeResult?           // the tapped object(s) → object card sheet

    private var ownship: CLLocationCoordinate2D? {
        let c = model.stratuxGPS?.coordinate ?? deviceCoord
        return c.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
    private var ownshipCourse: Double? { model.stratuxGPS?.coordinate == nil ? deviceCourse : nil }

    /// Only substitute the demo corridor when there's genuinely NO plan. A real filed plan wins even if it
    /// resolves to <2 legs — updateRoute then draws no line (count>=2 guard) rather than fabricating a
    /// Boston→JFK→DCA route and flagging KBOS/KJFK/KDCA as "on route" on a flight display (wrong data).
    private var legs: [ResolvedLeg] {
        guard let plan = model.flightPlan, !plan.isEmpty else { return Self.demoLegs }
        return ProcedureRoute.resolve(plan)
    }

    var body: some View {
        // Resolve the route ONCE per body eval (ProcedureRoute.resolve is not free) — was computed twice
        // via the old routeCoords + routeIdents properties on every @Published republish.
        let legs = self.legs
        let routeCoords = legs.map { CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon) }
        return ZStack(alignment: .topLeading) {
            MapLibreChartView(store: store, routeCoords: routeCoords,
                              ownship: ownship, ownshipCourse: ownshipCourse,
                              traffic: model.aircraft, tfrs: model.tfrs, showTFRs: model.showTFRs,
                              plateOverlay: model.plateOverlay,
                              routeIdents: Set(legs.map { $0.ident }),
                              onTapObjects: { objs in
                                  guard !objs.isEmpty else { return }
                                  Haptics.impact(.light)
                                  probe = MapProbeResult(id: UUID().uuidString, objects: objs)
                              })
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("EXPERIMENTAL · MapLibre chart")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.red.opacity(0.85), in: Capsule())
                    Spacer()
                    if let onClose {
                        Button { onClose() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white)
                        }
                    }
                }
                Text("FAA tiles + route + airspace/airways + nav symbols + ownship/traffic + TFR + plate + tap. 1:1 port.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .padding(12).background(.black.opacity(0.35))
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            // Pull the sectional packs the route crosses (downloads them if needed) so the FAA layer shows.
            await store.setLayer(.sectional, routeRects: ChartGeo.routeRects(legs))
        }
        .onAppear { model.deviceLocation.start() }
        .onReceive(model.deviceLocation.$coord) { deviceCoord = $0 }
        .onReceive(model.deviceLocation.$courseDeg) { deviceCourse = $0 }
        .sheet(item: $probe) { p in
            MapObjectSheet(result: p)
                .environmentObject(model)
                .environmentObject(metars)
                .environmentObject(forecasts)
                .environmentObject(tafs)
        }
    }

    /// KBOS → KJFK → KDCA — a demo corridor so the chart has something to download + draw with no plan.
    private static let demoLegs: [ResolvedLeg] = [
        ResolvedLeg(ident: "KBOS", kind: .airport, coord: Coord(lat: 42.3656, lon: -71.0096)),
        ResolvedLeg(ident: "KJFK", kind: .airport, coord: Coord(lat: 40.6413, lon: -73.7781)),
        ResolvedLeg(ident: "KDCA", kind: .airport, coord: Coord(lat: 38.8521, lon: -77.0377)),
    ]
}
#endif
