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
    /// Published holding patterns on the active approach, already filtered to the ones being FLOWN
    /// (a skipped course reversal never reaches the map).
    var holds: [ApproachHold] = []
    var ownship: CLLocationCoordinate2D? = nil
    var ownshipCourse: Double? = nil
    /// 1-sigma horizontal accuracy of the device fix in metres (nil for a Stratux fix / no fix) — drawn
    /// as the accuracy ring, and integrity tints both the ring and the ownship symbol.
    var ownshipAccuracyM: Double? = nil
    var ownshipIntegrity: GPSIntegrityState = .unknown
    var traffic: [Aircraft] = []
    /// Stations whose weather is deteriorating fast (chart markers). See `WxTrendPin`.
    var wxTrend: [WxTrendPin] = []
    var tfrs: [TFR] = []
    var showTFRs: Bool = false
    var showAirspace: Bool = true                     // MapLayersMenu overlay toggles (parity with ChartMapView)
    var showNearby: Bool = true
    var showAirways: Bool = true
    /// See AppModel.declutter — suppress the enroute furniture on ANY base, as `.smartDark` already does.
    var declutter: Bool = false
    /// Lock the chart north-up (disable rotate + snap bearing to 0). See AppModel.northLocked.
    var northLocked: Bool = true
    var plateOverlay: PlateOverlayState? = nil
    var routeIdents: Set<String> = []
    /// The flown route as RESOLVED LEGS — the same ordered, procedure-expanded list the route line is drawn
    /// from, but carrying each waypoint's ident and published crossing restrictions. Drives the route-
    /// waypoint symbols on the decluttered night base (`routeCoords` is only geometry).
    var routeLegs: [ResolvedLeg] = []
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
    var theme: AppTheme = .cockpit                                // map palette; re-applied LIVE (no remount)
    var chartBrightness: Double = 1.0                             // pilot's raster-brightness scale (layers panel)
    var windFields: WindFieldSet? = nil                           // decoded GFS winds aloft (nil = none yet)
    var windLevel: Int = 0                                        // altitude-slider detent → WindLevel
    var windPalette: WindRamp.Palette = .auto                     // pilot's sprite-colour choice
    var windEnabled: Bool = false                                 // layer toggle ∧ scene active ∧ !thermal

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
        context.coordinator.inTheme = theme                     // style JSON is written with this palette
        context.coordinator.inChartBrightness = chartBrightness
        // Seed the base layer too: mount() can create the map (and write the style JSON) before the first
        // updateUIView caches inputs, and the style's background color comes from the layer-aware palette.
        // Unseeded, a cold launch straight into Dark paints one frame of the default blue sea.
        context.coordinator.seedLayer(layer)
        context.coordinator.mount(in: container, initialCenter: initialCenter, routeFirst: routeCoords.first)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let c = context.coordinator
        c.onVisibleRegion = onVisibleRegion
        c.onSearchPoint = onSearchPoint
        c.inMapCommand = mapCommand
        c.northLocked = northLocked
        c.inTheme = theme
        c.inChartBrightness = chartBrightness
        c.inWindFields = windFields
        c.inWindLevel = windLevel
        c.inWindPalette = windPalette
        c.inWindEnabled = windEnabled
        c.cacheInputs(layer: layer, routeCoords: routeCoords, breadcrumbCoords: breadcrumbCoords,
                      radarTemplate: radarTemplate, holds: holds, ownship: ownship, ownshipCourse: ownshipCourse,
                      ownshipAccuracyM: ownshipAccuracyM, ownshipIntegrity: ownshipIntegrity,
                      traffic: traffic, wxTrend: wxTrend, tfrs: showTFRs ? tfrs : [], showAirspace: showAirspace,
                      showNearby: showNearby, showAirways: showAirways, declutter: declutter,
                      plateOverlay: plateOverlay,
                      routeIdents: routeIdents, routeLegs: routeLegs, focus: focus, restoreCamera: restoreCamera,
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
        var northLocked: Bool = true          // mirrors AppModel.northLocked; applied in applyLatest
        var inTheme: AppTheme = .cockpit      // mirrors model.theme; applied one-shot in applyMapThemeIfNeeded
        var inChartBrightness: Double = 1.0   // mirrors model.chartBrightness (layers-panel slider)
        private var appliedMapTheme: AppTheme?   // last palette actually applied (nil → force apply)
        private var appliedBrightness: Double?   // last raster-brightness scale applied
        private var appliedSmartMode: Bool?      // last-applied "is this the smartDark palette?" (nil → force)
        private weak var starfield: StarfieldView?   // globe space backdrop; retinted on theme change
        private weak var windView: WindParticleView?  // animated winds-aloft particles, floated OVER the map
        var inWindFields: WindFieldSet?              // mirrors model.windAloft.fieldSet
        var inWindLevel = 0                          // mirrors model.windLevelIndex
        var inWindPalette: WindRamp.Palette = .auto  // mirrors model.windPalette
        var inWindEnabled = false                    // mirrors the composed wind gate
        private var appliedWindStamp: String?        // (validTime, level, enabled, theme) last pushed

        /// The palette for the CURRENT theme + selected base + pilot brightness — the single source every
        /// apply path uses. Reads `inLayer` (the latest input) and NOT `layer` (only synced inside
        /// applyLayer, which runs AFTER the theme pass in applyLatest — so `layer` is one frame stale on
        /// the switch, which would paint the new base with the old palette).
        var currentMapTheme: MapTheme {
            MapTheme.forLayer(inLayer, theme: inTheme, chartBrightness: inChartBrightness)
        }
        private var serverPort: UInt16 = 0         // bound loopback port, delivered async by the tile server
        private var servedReadersSig: String?      // (layer + sorted mounted packIDs) last handed to the tile server
        // Bundled always-present RASTER bases for the globe (loaded once): a global Blue Marble satellite backstop
        // + a low-res whole-US chart base per layer. Appended LAST (lowest priority, first-match-wins) so the FAA
        // raster returns an OPAQUE tile at every globe zoom → it covers the vector land-fill, hiding the fill
        // subdivision fragmentation, and shows satellite/charts where the pilot has downloaded nothing.
        private lazy var bundledSatelliteBase: MBTilesReader? =
            Bundle.main.url(forResource: "satellite_base", withExtension: "mbtiles", subdirectory: "basemap")
                .flatMap { MBTilesReader(path: $0.path) }
        private lazy var bundledVFRBase: MBTilesReader? =
            Bundle.main.url(forResource: "vfr_base", withExtension: "mbtiles", subdirectory: "basemap")
                .flatMap { MBTilesReader(path: $0.path) }
        private lazy var bundledIFRLowBase: MBTilesReader? =
            Bundle.main.url(forResource: "ifrlow_base", withExtension: "mbtiles", subdirectory: "basemap")
                .flatMap { MBTilesReader(path: $0.path) }
        private lazy var bundledIFRHighBase: MBTilesReader? =
            Bundle.main.url(forResource: "ifrhigh_base", withExtension: "mbtiles", subdirectory: "basemap")
                .flatMap { MBTilesReader(path: $0.path) }
        /// The decluttered night base's terrain relief: pre-baked dark shaded relief with a TRANSPARENT
        /// ocean (CONUS, z0–z10 from z10 source DEM; ios/Tools/build_terrain_relief.py). SPARSE at its
        /// deepest level — z10 is carried only where there is terrain worth the bytes and flat country
        /// falls back to the magnified parent (MBTilesHTTPServer.ancestorPNG), which is why the pack can
        /// afford 118 m/px at the terminal area. Pre-baked rather than a live
        /// hillshade/raster-DEM layer because the globe fork never ported those render paths — they would
        /// draw as unsubdivided Mercator quads on the sphere, while the raster path is globe-correct.
        /// A missing pack is not fatal: `.smartDark` then shows the dark base + land silhouettes.
        private lazy var bundledTerrainBase: MBTilesReader? =
            Bundle.main.url(forResource: "terrain_base", withExtension: "mbtiles", subdirectory: "basemap")
                .flatMap { MBTilesReader(path: $0.path) }
        /// Server path segment per chart layer for the bundled bases (see setupChartBaseLayers).
        private static let baseNames: [ChartLayer: String] = [.sectional: "vfr", .ifrLow: "ifrlow",
                                                             .ifrHigh: "ifrhigh", .smartDark: "terrain"]

        /// Web-Mercator latitude limit. Anything beyond this is not representable and makes mbgl::LatLng throw.
        private static let maxMercatorLat = 85.05112878
        private static func clampLat(_ v: Double) -> Double {
            guard v.isFinite else { return 0 }
            return min(maxMercatorLat, max(-maxMercatorLat, v))
        }
        private static func clampLon(_ v: Double) -> Double {
            guard v.isFinite else { return 0 }
            return min(180, max(-180, v))
        }
        private var regionDebounce: DispatchWorkItem?  // coalesces a burst of region-settle events (pan/zoom)
        private var layer: ChartLayer = .sectional     // FAA base layer; drives ensureVisiblePacks
        private var appliedLayer: ChartLayer?          // last-applied — a change re-requests packs for the new layer
        private var showAirspace = true, showNearby = true, showAirways = true   // MapLayersMenu overlay toggles
        private var declutterOn = false                                          // the pilot's declutter mask
        private var appliedToggles: String?            // last-applied toggle triple — a change re-runs refreshOverlays
        private var lastFocus: Coord?                  // search-recenter dedupe
        var onVisibleRegion: ((MKMapRect) -> Void)?    // settle → host persists model.lastMapCamera (M7)
        private var restoreCamera: SavedMapCamera?     // pilot's last pan/zoom, restored once on first frame
        private var didFrame = false                   // one-shot: frame to camera/route/GPS once real data exists
        private var probeGen = 0                       // tap-identify generation guard (a newer tap supersedes)
        private var styleGate = StyleSetupGate()       // setup-overlays once per STYLE (didFinishLoading can re-fire)
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
        private var inHolds: [ApproachHold] = []
        private var inWxTrend: [WxTrendPin] = []
        private var appliedCategoryVersion = 0
        private var inTFRs: [TFR] = []
        private var inShowAirspace = true, inShowNearby = true, inShowAirways = true
        private var inDeclutter = false
        private var inPlate: PlateOverlayState?
        private var inFocus: Coord?
        private var inRouteLegs: [ResolvedLeg] = []          // flown route WITH idents + constraints
        private var appliedRouteWptSig: String?              // last-applied waypoint set (ident+pos+labels)

        /// Pre-mount seed for the base layer, so the FIRST style JSON is written with the right palette
        /// (see makeUIView). `cacheInputs` overwrites this on the first real update.
        func seedLayer(_ l: ChartLayer) { inLayer = l }

        /// Stash the latest inputs from updateUIView (called every body eval, even before the map exists).
        func cacheInputs(layer: ChartLayer, routeCoords: [CLLocationCoordinate2D],
                         breadcrumbCoords: [CLLocationCoordinate2D], radarTemplate: String?,
                         holds: [ApproachHold],
                         ownship: CLLocationCoordinate2D?,
                         ownshipCourse: Double?, ownshipAccuracyM: Double?,
                         ownshipIntegrity: GPSIntegrityState,
                         traffic: [Aircraft], wxTrend: [WxTrendPin], tfrs: [TFR], showAirspace: Bool,
                         showNearby: Bool, showAirways: Bool, declutter: Bool,
                         plateOverlay: PlateOverlayState?,
                         routeIdents: Set<String>, routeLegs: [ResolvedLeg],
                         focus: Coord?, restoreCamera: SavedMapCamera?,
                         onTap: @escaping ([IdentifiedObject]) -> Void,
                         onAnchors: @escaping ((CGPoint, CGPoint)?) -> Void,
                         searchHighlight: CLLocationCoordinate2D?) {
            inLayer = layer; inRoute = routeCoords; inBreadcrumb = breadcrumbCoords; inRadarTemplate = radarTemplate
            inHolds = holds
            inOwnship = ownship; inOwnCourse = ownshipCourse
            inOwnAccuracy = ownshipAccuracyM; inOwnIntegrity = ownshipIntegrity
            inTraffic = traffic; inWxTrend = wxTrend; inTFRs = tfrs; inShowAirspace = showAirspace; inShowNearby = showNearby
            inShowAirways = showAirways; inDeclutter = declutter
            inPlate = plateOverlay; inFocus = focus; self.restoreCamera = restoreCamera
            self.routeIdents = routeIdents; inRouteLegs = routeLegs
            self.onTapObjects = onTap; self.onPlateAnchors = onAnchors
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
            applyMapThemeIfNeeded(on: map)  // one-shot palette re-apply on theme change (nil-compare when unchanged)
            applyLayer(inLayer, on: map)
            // Surface packs whose download completed AFTER ensureVisiblePacks returned (store.readers is
            // @MainActor → hop, matching ensureVisiblePacks). Signature-gated, so a no-op when the set is unchanged.
            Task { @MainActor [weak self, weak map] in guard let self, let map else { return }; self.syncFAASource(on: map) }
            updateRoute(inRoute, on: map)
            updateRouteWaypoints(inRouteLegs, on: map)
            updateHolds(inHolds, on: map)
            updateTrack(inBreadcrumb, on: map)
            updateRadar(inRadarTemplate, on: map)
            emitSearchPoint(map)               // keep the pulsing search marker glued to its spot
            applyNorthLock(map)                // chart north-up lock (rotate gesture + bearing)
            applyMapCommand(map)               // one-shot side-bar zoom / center-on-ownship
            applyOverlayToggles(inShowAirspace, inShowNearby, inShowAirways, declutter: inDeclutter, on: map)
            updateOwnship(inOwnship, course: inOwnCourse, accuracyM: inOwnAccuracy,
                          integrity: inOwnIntegrity, on: map)
            updateTraffic(inTraffic, on: map)
            updateWxTrend(inWxTrend, on: map)
            // New weather → the airport glyphs' category rings changed → rebuild the nav features.
            if appliedCategoryVersion != Coordinator.categoryVersion {
                appliedCategoryVersion = Coordinator.categoryVersion
                refreshOverlays(map)
            }
            updateTFRs(inTFRs, on: map)
            updatePlate(inPlate, on: map)
            applyFocus(inFocus, on: map)
            updateWind(on: map)
        }

        // MARK: winds aloft (animated particle overlay)

        /// Float the particle layer OVER the map, inside the same container. Created here rather than in
        /// `mount` so it shares the map's lifetime exactly: a render-stall rebuild or a globe-toggle remount
        /// destroys both and `createMap` builds both again. Nothing but the decoded field set (which lives
        /// in the service) survives that, and the trails regrow in about two seconds.
        private func mountWindLayer(in container: UIView, over map: MLNMapView) {
            guard windView == nil else { return }
            // A device with no Metal renderer gets no layer at all — better than an empty view over the chart.
            guard let wind = WindParticleView.make(frame: container.bounds) else { return }
            wind.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(wind)                  // inserted AFTER the map → draws on top of it
            wind.setCameraProvider { [weak map, weak wind] in
                guard let map, let wind else { return nil }
                return Coordinator.camera(from: map, in: wind)
            }
            windView = wind
        }

        /// Sample the live projection into the affine the particles live in.
        ///
        /// Three `convert` calls rather than mercator arithmetic, because this tree runs the forked globe
        /// below zoom 12 and honours chart rotation — both of which a hand-rolled projection gets wrong.
        /// The probe step scales with the visible span so it stays inside the linear region when zoomed in
        /// and above pixel quantisation when zoomed out.
        static func camera(from map: MLNMapView, in view: UIView) -> WindCamera? {
            let bounds = map.visibleCoordinateBounds
            let lonSpan = abs(bounds.ne.longitude - bounds.sw.longitude)
            let center = map.centerCoordinate
            guard center.latitude.isFinite, center.longitude.isFinite else { return nil }
            let step = min(max(lonSpan / 40, 0.002), 1.0)
            // Probe toward the equator near a pole so the offset coordinate stays representable.
            let latStep = center.latitude > 0 ? -step : step
            let north = CLLocationCoordinate2D(latitude: center.latitude + latStep, longitude: center.longitude)
            let east = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + step)
            guard let t = WindViewportTransform.fit(center: center,
                                                   centerPoint: map.convert(center, toPointTo: view),
                                                   northPoint: map.convert(north, toPointTo: view),
                                                   eastPoint: map.convert(east, toPointTo: view),
                                                   northDelta: latStep, eastDelta: step) else { return nil }
            return WindCamera(transform: t, zoom: map.zoomLevel,
                              lonSpan: lonSpan > 0 ? lonSpan : 360)
        }

        /// Push the wind inputs, gated by a signature so an unchanged frame costs one string compare.
        /// The particle layer itself is paused whenever it is off, so a disabled overlay has no frame cost.
        private func updateWind(on map: MLNMapView) {
            guard let wind = windView else { return }
            let level = WindLevel.at(index: inWindLevel)
            // `inLayer` is in the stamp because the ramp now resolves through it (`.smartDark` forces the
            // night ramp — see WindRamp.forLayer); without it a VFR⇄Dark switch at an unchanged theme
            // would keep the old ramp on the particles for the life of the session.
            //
            // `fetchedAt` — not `validTime` — is what identifies the GRID. Panning off the covered box
            // triggers a re-download for the new area, and that download almost always lands on the SAME
            // model cycle and forecast hour as the one already held, so its `validTime` is identical: the
            // signature never changed, and the freshly-decoded grid for where the pilot has actually flown
            // to was dropped on the floor while the old one kept sampling nil. `fetchedAt` is distinct per
            // download by construction, so a new box always reaches the renderer.
            let stamp = "\(inWindEnabled)|\(level.rawValue)|\(inTheme.rawValue)|\(inLayer.rawValue)|"
                + "\(inWindPalette.rawValue)|"
                + "\(inWindFields?.fetchedAt.timeIntervalSince1970 ?? -1)"
            guard stamp != appliedWindStamp else { return }
            appliedWindStamp = stamp
            wind.apply(fieldSet: inWindEnabled ? inWindFields : nil, level: level,
                       ramp: WindRamp.resolve(palette: inWindPalette, layer: inLayer, theme: inTheme))
            wind.setActive(inWindEnabled && inWindFields != nil)
        }

        /// One-shot initial framing (mirrors ChartMapView's didFrame): at cold launch the route resolves
        /// and the GPS fix arrive AFTER the map is built, so createMap's mount-time snapshot is CONUS. Keep
        /// re-attempting on every apply until a real target exists — a fresh saved camera, else the route,
        /// else the ownship/GPS — so the map auto-centers instead of stranding the pilot at continental scale.
        private func frameIfNeeded(on map: MLNMapView) {
            guard !didFrame else { return }
            if let cam = restoreCamera, SavedMapCamera.cameraIsFresh(savedAt: cam.savedAt, now: Date()) {
                // CLAMP (crash fix): MKCoordinateRegion(rect) reports a MERCATOR-midpoint center with an
                // ARITHMETIC latitudeDelta, so reconstructing center ± delta/2 overshoots ±90° for any wide or
                // latitude-asymmetric view (measured: a 24.5° span at sw 60/ne 85 already yields ne 90.15).
                // MLNCoordinateBounds is an unvalidated C struct and MLNMapView does not catch, so the
                // out-of-range value reaches mbgl::LatLng, throws std::domain_error, and terminates the app —
                // reachable on the SHIPPED flat map by pinch-out → tab switch (the map is rebuilt and restores).
                let r = cam.region
                let sw = CLLocationCoordinate2D(
                    latitude: Self.clampLat(r.center.latitude - r.span.latitudeDelta / 2),
                    longitude: Self.clampLon(r.center.longitude - r.span.longitudeDelta / 2))
                let ne = CLLocationCoordinate2D(
                    latitude: Self.clampLat(r.center.latitude + r.span.latitudeDelta / 2),
                    longitude: Self.clampLon(r.center.longitude + r.span.longitudeDelta / 2))
                assert(sw.latitude <= ne.latitude, "restore: inverted latitude bounds")
                assert(CLLocationCoordinate2DIsValid(sw) && CLLocationCoordinate2DIsValid(ne),
                       "restore: invalid restored bounds")
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), animated: false)
                didFrame = true; return
            }
            if inRoute.count >= 2 {
                let lats = inRoute.map(\.latitude), lons = inRoute.map(\.longitude)
                guard let a = lats.min(), let b = lats.max(), let c = lons.min(), let d = lons.max() else { return }
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: .init(latitude: a, longitude: c),
                                                                   ne: .init(latitude: b, longitude: d)),
                                               edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 80, right: 60),
                                               animated: false, completionHandler: nil)
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
            if globeProjection {
                // Globe: the fork clears "space" (outside the sphere) to transparent, so make the map non-opaque
                // and float a night-sky starfield BEHIND it — space reads as black with stars while the ocean
                // sphere sits in front. The flat map stays opaque (the fork fills the whole viewport), so the
                // starfield never shows there.
                m.isOpaque = false
                m.backgroundColor = .clear
                let sky = StarfieldView(frame: container.bounds)
                sky.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                let t = currentMapTheme
                sky.apply(space: t.space, starColor: t.starColor, alphaScale: CGFloat(t.starAlphaScale))
                container.addSubview(sky)   // inserted before the map → sits behind it (= "space")
                self.starfield = sky
            }
            container.addSubview(m)
            self.map = m
            mountWindLayer(in: container, over: m)
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
                guard let styleURL = Self.writeStyle(port: port, globe: self.globeProjection,
                                                     theme: self.currentMapTheme) else { self.onRenderStalled?(); return }
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
            regionDebounce?.cancel(); regionDebounce = nil
            // Drop the host callback BEFORE stopping the server, so a torn-down coordinator can never
            // drive the host's engine state whichever callback wins the race.
            onRenderStalled = nil
            server.stop()
            // Stop the particle display link before the view is released — an MTKView left unpaused keeps
            // drawing (and drawing from a dead camera provider) until it is deallocated.
            windView?.setCameraProvider(nil)
            windView?.setActive(false)
        }

        // MARK: style + layers

        private static func writeStyle(port: UInt16, globe: Bool, theme: MapTheme) -> URL? {
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
            // the sphere is "space". A near-black flat sea would melt into space on the globe, so the globe keeps
            // a clearly-blue ocean; both values come from the per-theme MapTheme.
            let sea = MapTheme.hexString(globe ? theme.globeSea : theme.sea)
            // Chart tiles use the plain "{z}/{x}/{y}" path on BOTH projections. (An earlier globe-only "/uz/"
            // underzoom path was never reachable — syncFAASource rebuilt the source with a prefix-less template
            // before any reader was mounted — and the bundled raster bases superseded it: the globe now gets its
            // zoomed-out chart from the always-mounted low-res bases, not from synthesised sub-minZoom tiles.)
            let faaTiles = "{z}/{x}/{y}"
            let style = """
            {
              "version": 8,
              \(projection)"glyphs": "http://127.0.0.1:\(port)/font/{fontstack}/{range}.pbf",
              "sources": {
                "faa": { "type": "raster", "tiles": ["http://127.0.0.1:\(port)/\(faaTiles)"],
                         "tileSize": \(Coordinator.rasterTileSize), "minzoom": 0, "maxzoom": 11, "attribution": "FAA charts (offline pack)" }
              },
              "layers": [
                { "id": "bg", "type": "background", "paint": { "background-color": "\(sea)" } },
                { "id": "faa", "type": "raster", "source": "faa",
                  "paint": { "raster-brightness-max": \(theme.rasterBrightnessMax),
                             "raster-saturation": \(theme.rasterSaturation),
                             "raster-contrast": \(theme.rasterContrast) } }
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
            // Same reason, and easy to miss: the map loads TWO styles in its life (MapLibre's default,
            // then the loopback style), so anything applied to the first must be re-applied to the
            // second. Without these the re-apply below hits its own "unchanged → skip" guard against a
            // freshly-created EMPTY source, and the polygons are never uploaded to the style the pilot
            // is actually looking at. Traffic self-heals because it changes every second; a TFR set can
            // sit unchanged for hours, so it simply stays invisible.
            appliedTFRSig = nil
            appliedTrafficSig = nil
            appliedHoldSig = nil                 // holds sit unchanged for a whole approach — exactly the
                                                 // TFR case above, so without this the racetrack is built
                                                 // into the throwaway style and never drawn on the real one
            appliedRouteSig = nil                // same class (pre-existing): an unchanged ROUTE applied to
                                                 // the throwaway style never re-uploads to the real one
            appliedOwnSig = nil                  // and a PARKED aircraft's ownship (inside the ~12 m/3°
                                                 // dead band) could stay invisible; motion self-heals,
                                                 // sitting still must not
            appliedRouteWptSig = nil             // same trap: a filed route can sit unchanged for the whole
                                                 // flight, so without this reset the waypoints would exist
                                                 // only in the discarded style and never draw
            appliedMapTheme = nil                // freshly-built layers carry setup colors → force a theme pass
            appliedSmartMode = nil               // …and the palette also depends on the selected base layer
            setupOverlayLayers(style)            // airspace/airways/nav + TFR/route/traffic/ownship (empty)
            applyMapThemeIfNeeded(on: mapView)   // recolor the fresh layers for the active theme
            updateRoute(routeCoords, on: mapView)
            updateRouteWaypoints(inRouteLegs, on: mapView)
            applyRouteWptVisibility(on: mapView) // fresh layers default to visible → hide off the dark base
            updateHolds(inHolds, on: mapView)
            updateTrack(trackCoords, on: mapView)
            updateRadar(inRadarTemplate, on: mapView)
            ensureVisiblePacks(mapView)
            refreshOverlays(mapView)
            frameIfNeeded(on: mapView)           // frame now if route/GPS/camera arrived before the style loaded
            // Re-apply anything updateUIView cached before the style finished loading (same idiom as route).
            updateOwnship(lastOwnship, course: lastOwnCourse, accuracyM: lastOwnAccuracy,
                          integrity: lastOwnIntegrity, on: mapView)
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

        /// Tracks WHICH style object the overlay layers were built into.
        ///
        /// MapLibre calls `didFinishLoading` once per style load, and a single map loads more than one style
        /// in its life (its default, then ours; then again on any style swap). Runtime-added layers belong to
        /// the style they were added to and do NOT survive the swap, so "configure once" has to mean once per
        /// style, not once ever.
        struct StyleSetupGate {
            private var configured: ObjectIdentifier?
            /// True the first time a given style object is seen (and every time it CHANGES).
            mutating func shouldConfigure(_ style: AnyObject) -> Bool {
                let token = ObjectIdentifier(style)
                guard configured != token else { return false }
                configured = token
                return true
            }
            /// Read-only: has THIS style object been configured? (The theme re-apply pass must not
            /// latch "applied" against the throwaway default style's empty layer set.)
            func isConfigured(_ style: AnyObject) -> Bool { configured == ObjectIdentifier(style) }
        }

        // MARK: airspace + airways overlays (milestone 2)

        /// Create the persistent overlay sources + layers ONCE (empty). Per-region refresh only mutates
        /// `source.shape` — so we never remove a source a layer still uses (MapLibre would throw). Stacking:
        /// land base below the FAA raster below airways below airspace below route.
        private func setupOverlayLayers(_ style: MLNStyle) {
            // ONCE PER STYLE — emphatically NOT once per coordinator. The map comes up on MapLibre's own
            // default style and only switches to ours once the loopback tile server binds a port (that bind
            // is async, see createMap). Latching on the first didFinishLoading therefore built every overlay
            // into a style that was about to be thrown away: when the real style loaded, the guard skipped
            // setup and the pilot got the chart raster and NOTHING else — no ownship, route, traffic,
            // airspace, airways or airport symbology — for the rest of the session. Whether it happened at
            // all came down to whether the bind beat the default style's load, which is why it looked
            // intermittent. Keyed on the style OBJECT: a re-fire for the same style still no-ops.
            guard styleGate.shouldConfigure(style) else { return }
            // CLEAN SLATE: MapLibre restores runtime-added layers from its ambient cache across launches, so
            // the "fresh" style can already carry OUR layers (with dangling sources) → adding them again throws
            // MLNRedundantLayerIdentifierException. Remove any of our managed layers/sources first (layers
            // before their sources, or MapLibre throws), then build fresh — self-healing + fully idempotent.
            clearManagedStyle(style)
            setupLandBase(style)               // OFFLINE vector land/coastline, bottom-most (above bg, below faa)
            setupNightVeil(style)              // red dark-adaptation wash over the chart (night theme only)
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
            let layers = ["plate-raster", "ownship-sym", "accuracy-fill", "accuracy-line", "traffic-sym",
                          "route-wpt-spd", "route-wpt-alt", "route-wpt-sym",
                          "hold-line", "route-line", "track-line",
                          "wxradar-layer", "tfr-label", "tfr-outline", "tfr-fill", "nav-sym",
                          "airspace-label", "airways-label", "airspace-outline", "airspace-fill",
                          "airways-line", "night-veil-fill", "coastline", "land-fill"]
            for id in layers where style.layer(withIdentifier: id) != nil {          // bounded (rule 2)
                if let l = style.layer(withIdentifier: id) { style.removeLayer(l) }
            }
            let sources = ["plate", "ownship", "accuracy", "traffic", "route-wpt", "holds", "route", "track",
                           "wxradar", "tfr-labels", "tfr",
                           "nav", "airspace-labels", "airspace", "airways", "night-veil", "land"]
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
            // Globe with a bundled raster base: while a RASTER chart layer is selected the satellite/chart base
            // IS the land, so the vector land is redundant AND z-fights the raster at the same sphere depth
            // (faint triangles). But "Standard map"/"Satellite" are first-class rows in the layers menu and have
            // no raster chart base, and skipping the land outright left them showing a 32x-upscaled photo with no
            // coastline. So always BUILD it and toggle visibility per layer in applyLandBaseVisibility().
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

        /// A static world polygon washed over the chart for the night theme's red shift (dark
        /// adaptation) — opacity 0 / hidden in every other theme, so cockpit and day pay nothing.
        /// FLAT MAP ONLY: on the globe the world polygon would tessellate onto the sphere and
        /// z-fight the raster (the globe gets the raster dim without the red wash). Added before
        /// the vector layers so airways/TFR/route/ownship render at full intensity ABOVE the veil;
        /// syncFAASource re-floats it directly above the recreated "faa" layer on every pack change.
        private func setupNightVeil(_ style: MLNStyle) {
            guard !globeProjection else { return }
            guard style.source(withIdentifier: "night-veil") == nil else { return }   // idempotent
            var corners = [CLLocationCoordinate2D(latitude: 85, longitude: -180),
                           CLLocationCoordinate2D(latitude: 85, longitude: 180),
                           CLLocationCoordinate2D(latitude: -85, longitude: 180),
                           CLLocationCoordinate2D(latitude: -85, longitude: -180)]
            assert(corners.count == 4, "night veil must be a quad")
            let world = MLNPolygonFeature(coordinates: &corners, count: UInt(corners.count))
            let src = MLNShapeSource(identifier: "night-veil", shape: world, options: nil)
            style.addSource(src)
            let veil = MLNFillStyleLayer(identifier: "night-veil-fill", source: src)
            veil.fillColor = NSExpression(forConstantValue: MapTheme.nightVeilColor)
            veil.fillOpacity = NSExpression(forConstantValue: 0)
            veil.isVisible = false
            style.addLayer(veil)   // later setup* addLayer calls stack the vectors above it
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

        /// Stations whose weather is deteriorating fast. Drawn as a distinct marker rather than folded
        /// into the airport glyph, because "this field is going down" is a different question from "what
        /// is this field" — and a pilot scanning ahead needs to spot it without reading every symbol.
        private func setupWxTrendLayer(_ style: MLNStyle) {
            guard style.source(withIdentifier: "wxtrend") == nil else { return }
            let src = MLNShapeSource(identifier: "wxtrend", shape: nil, options: nil)
            style.addSource(src)
            style.setImage(WxTrendMarker.image(severity: .falling), forName: "wx-falling")
            style.setImage(WxTrendMarker.image(severity: .dropping), forName: "wx-dropping")
            let layer = MLNSymbolStyleLayer(identifier: "wxtrend-sym", source: src)
            layer.iconImageName = NSExpression(forKeyPath: "img")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            layer.text = NSExpression(forKeyPath: "cap")
            layer.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            layer.textFontSize = NSExpression(forConstantValue: 9)
            layer.textColor = NSExpression(forConstantValue: UIColor.white)
            layer.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.9))
            layer.textHaloWidth = NSExpression(forConstantValue: 1.2)
            layer.textAnchor = NSExpression(forConstantValue: "top")
            layer.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.1)))
            layer.textOptional = NSExpression(forConstantValue: true)
            layer.minimumZoomLevel = 4.5
            style.addLayer(layer)
        }

        /// Push the current set of deteriorating stations onto the map.
        private var appliedWxTrend: [WxTrendPin] = []
        func updateWxTrend(_ results: [WxTrendPin], on map: MLNMapView) {
            guard let style = map.style else { return }
            guard results != appliedWxTrend || style.source(withIdentifier: "wxtrend") == nil else { return }
            appliedWxTrend = results
            setupWxTrendLayer(style)
            var feats: [MLNPointFeature] = []
            for r in results.prefix(120) {                          // bounded (rule 2)
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: r.coord.lat, longitude: r.coord.lon)
                f.attributes = ["img": r.severity == .dropping ? "wx-dropping" : "wx-falling",
                                "cap": r.caption]
                feats.append(f)
            }
            assert(feats.count <= 120, "updateWxTrend: unexpectedly many markers")
            (style.source(withIdentifier: "wxtrend") as? MLNShapeSource)?.shape =
                MLNShapeCollectionFeature(shapes: feats)
        }

        /// TFR + route + traffic + ownship layers (empty; driven by updateUIView, not by region). Stacked on
        /// top of the static context so the route/traffic/ownship read above everything (as MK annotations do).
        private func setupDynamicLayers(_ style: MLNStyle) {
            let red = ChartMapView.Coordinator.airspaceColor("TFR")     // #F71433 — reuse, no hand-typed hex
            let tfrSrc = MLNShapeSource(identifier: "tfr", shape: nil, options: nil); style.addSource(tfrSrc)
            let tfrFill = MLNFillStyleLayer(identifier: "tfr-fill", source: tfrSrc)   // no minzoom: TFRs show at any zoom
            tfrFill.fillColor = NSExpression(forConstantValue: red)
            // Louder than the 0.14 standing national-defense areas: a live NOTAM outranks chart furniture.
            tfrFill.fillOpacity = NSExpression(forConstantValue: 0.24)
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

            // Holding patterns on the active approach. Same magenta family as the route (it IS part of
            // the procedure) but DASHED, so a racetrack the pilot may or may not fly is never mistaken
            // for the course line they are tracking.
            let holdSrc = MLNShapeSource(identifier: "holds", shape: nil, options: nil); style.addSource(holdSrc)
            let holdLine = MLNLineStyleLayer(identifier: "hold-line", source: holdSrc)
            holdLine.lineColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 0.95))
            holdLine.lineWidth = NSExpression(forConstantValue: 2.5)
            holdLine.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
            holdLine.lineCap = NSExpression(forConstantValue: "round"); holdLine.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(holdLine)
            // …and the fix's NAME, on the same source. On an FAA raster the chart underneath already
            // prints it, but `.smartDark` has no chart under the racetrack and its labels come from the
            // route-fix stars — which are fed by the resolved plan, and `ProcedureRoute` deliberately
            // strips the missed-approach segment. So after arming the missed on the dark base the pilot
            // got a dashed racetrack floating over black terrain with no fix name to check it against.
            // The line layer ignores point features and this layer ignores lines, so one source serves
            // both and the existing signature gate already covers the fix.
            let holdLabel = MLNSymbolStyleLayer(identifier: "hold-label", source: holdSrc)
            holdLabel.text = NSExpression(forKeyPath: "ident")
            holdLabel.textFontSize = NSExpression(forConstantValue: 10)
            holdLabel.textColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.24, blue: 0.62, alpha: 1))
            holdLabel.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.85))
            holdLabel.textHaloWidth = NSExpression(forConstantValue: 1.2)
            holdLabel.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -12)))
            holdLabel.textOptional = NSExpression(forConstantValue: true)
            holdLabel.textAllowsOverlap = NSExpression(forConstantValue: false)
            style.addLayer(holdLabel)

            setupRouteWptLayers(style)   // above the route/hold lines, below accuracy/traffic/ownship

            style.setImage(ChartMapView.Coordinator.traffic, forName: "own-traffic")
            // Three ownship symbols, selected per-feature by integrity, so a degraded fix can never be
            // drawn in the same confident blue as a good one. (An unreliable/suspect fix is normally not
            // passed to the map at all — MapHostView suppresses it — but if one ever is, it reads red.)
            style.setImage(ChartMapView.Coordinator.ownPlane(for: .nominal), forName: "own-ship")
            style.setImage(ChartMapView.Coordinator.ownPlane(for: .degraded), forName: "own-ship-degraded")
            style.setImage(ChartMapView.Coordinator.ownPlane(for: .suspect), forName: "own-ship-suspect")

            // 1-sigma horizontal accuracy ring. MapLibre has no metre-radius circle primitive, so this is
            // a real geodesic polygon rebuilt when the fix moves materially (see updateOwnship). It is
            // added BEFORE the ownship symbol so the aircraft always draws on top of its own uncertainty.
            let accSrc = MLNShapeSource(identifier: "accuracy", shape: nil, options: nil); style.addSource(accSrc)
            let accFill = MLNFillStyleLayer(identifier: "accuracy-fill", source: accSrc)
            accFill.fillColor = NSExpression(forKeyPath: "color")
            accFill.fillOpacity = NSExpression(forConstantValue: 0.10)
            style.addLayer(accFill)
            let accLine = MLNLineStyleLayer(identifier: "accuracy-line", source: accSrc)
            accLine.lineColor = NSExpression(forKeyPath: "color")
            accLine.lineOpacity = NSExpression(forConstantValue: 0.55)
            accLine.lineWidth = NSExpression(forConstantValue: 1.0)
            style.addLayer(accLine)
            let trafficSrc = MLNShapeSource(identifier: "traffic", shape: nil, options: nil); style.addSource(trafficSrc)
            let traffic = MLNSymbolStyleLayer(identifier: "traffic-sym", source: trafficSrc)
            traffic.iconImageName = NSExpression(forConstantValue: "own-traffic")
            traffic.iconRotation = NSExpression(forKeyPath: "rot")          // pre-baked (track - 90)
            traffic.iconRotationAlignment = NSExpression(forConstantValue: "map")
            // Same reason as ownship below: pitch-alignment defaults to "auto" -> inherits rotation-alignment
            // "map" -> pitch-with-map, which makes the globe fork skip the sphere reprojection AND the far-side
            // horizon cull for this layer. Traffic would then be placed by the flat Mercator label plane while
            // ownship sits on the sphere — a radial 1/cos(lat) range error between them (~30% at lat 40, ~2x at
            // Anchorage). On a traffic display that is WRONG data, so pin it to the same frame as ownship.
            traffic.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
            traffic.iconAllowsOverlap = NSExpression(forConstantValue: true)   // traffic must never collide away
            traffic.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(traffic)
            let ownSrc = MLNShapeSource(identifier: "ownship", shape: nil, options: nil); style.addSource(ownSrc)
            let own = MLNSymbolStyleLayer(identifier: "ownship-sym", source: ownSrc)
            own.iconImageName = NSExpression(forKeyPath: "img")      // per-integrity symbol
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

        /// The route-waypoint layer ids, top-of-stack order irrelevant (they share one source).
        static let routeWptLayers = ["route-wpt-sym", "route-wpt-alt", "route-wpt-spd"]

        /// Text offsets (in ems, the units MLNSymbolStyleLayer wants) for the constraint sublabels. The
        /// speed line sits directly under the ident when there is no altitude, and under the altitude when
        /// there is — a fixed slot would leave an empty gap on the (common) speed-only leg.
        private static let spdOffsetSolo = NSValue(cgVector: CGVector(dx: 0, dy: 1.9))
        private static let spdOffsetStacked = NSValue(cgVector: CGVector(dx: 0, dy: 2.75))

        /// The waypoints of the FLOWN route — ident, plus the published crossing restrictions — as three
        /// symbol layers over one shared source.
        ///
        /// Three layers rather than one, because a single leg can carry BOTH an altitude and a speed limit
        /// and they must read apart at a glance (cyan vs magenta): one `textColor` per layer is the only
        /// way MapLibre expresses that, and per-feature attributed text is untested on the globe fork.
        ///
        /// They sit above the route/hold lines and below accuracy/traffic/ownship — the route's own labels
        /// must never cover traffic or the aircraft. Created hidden-or-shown by `applyRouteWptVisibility`.
        private func setupRouteWptLayers(_ style: MLNStyle) {
            guard style.source(withIdentifier: "route-wpt") == nil else { return }   // per-id idempotency
            style.setImage(NearbyMarkerView.routeFixGlyphImage, forName: "rw-fix")
            let src = MLNShapeSource(identifier: "route-wpt", shape: nil, options: nil)
            style.addSource(src)
            let t = currentMapTheme

            let sym = MLNSymbolStyleLayer(identifier: "route-wpt-sym", source: src)
            sym.iconImageName = NSExpression(forKeyPath: "glyph")        // "rw-fix" or an "apt-…" signature
            // The route's marks always draw: they are the point of this mode. But they DO claim placement,
            // so the generic nav-sym airport symbol at the same field collides away instead of printing a
            // second ident on top of this one.
            sym.iconAllowsOverlap = NSExpression(forConstantValue: true)
            sym.iconIgnoresPlacement = NSExpression(forConstantValue: false)
            // Same reason as ownship/traffic: pitch-alignment defaults to "auto" → inherits
            // rotation-alignment → pitch-with-map, which makes the globe fork place the anchor through the
            // flat Mercator label plane instead of on the sphere.
            sym.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
            sym.text = NSExpression(forKeyPath: "ident")
            sym.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])   // the only bundled fontstack
            sym.textFontSize = NSExpression(forConstantValue: 9.5)
            sym.textColor = Self.routeWptTextExpr(t)
            sym.textHaloColor = NSExpression(forConstantValue: t.navLabelHalo)
            sym.textHaloWidth = NSExpression(forConstantValue: 1.2)
            sym.textAnchor = NSExpression(forConstantValue: "top")
            sym.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.9)))
            sym.textOptional = NSExpression(forConstantValue: true)      // drop the ident before the mark
            style.addLayer(sym)                                          // NO minzoom: the route is the mode

            // Constraint sublabels are detail, not orientation: they'd be unreadable mush at continental
            // zoom, so they appear once the pilot is zoomed into the procedure.
            let alt = MLNSymbolStyleLayer(identifier: "route-wpt-alt", source: src)
            alt.text = NSExpression(forKeyPath: "alt")
            alt.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            alt.textFontSize = NSExpression(forConstantValue: 8.5)
            alt.textColor = NSExpression(forConstantValue: t.routeWptAlt)
            alt.textHaloColor = NSExpression(forConstantValue: t.navLabelHalo)
            alt.textHaloWidth = NSExpression(forConstantValue: 1.2)
            alt.textAnchor = NSExpression(forConstantValue: "top")
            alt.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.9)))
            alt.textOptional = NSExpression(forConstantValue: true)
            alt.textIgnoresPlacement = NSExpression(forConstantValue: true)
            alt.minimumZoomLevel = 7
            style.addLayer(alt)

            let spd = MLNSymbolStyleLayer(identifier: "route-wpt-spd", source: src)
            spd.text = NSExpression(forKeyPath: "spd")
            spd.textFontNames = NSExpression(forConstantValue: ["Arial Bold"])
            spd.textFontSize = NSExpression(forConstantValue: 8.5)
            spd.textColor = NSExpression(forConstantValue: t.routeWptSpeed)
            spd.textHaloColor = NSExpression(forConstantValue: t.navLabelHalo)
            spd.textHaloWidth = NSExpression(forConstantValue: 1.2)
            spd.textAnchor = NSExpression(forConstantValue: "top")
            // Offsets are NSValue-wrapped vectors, which a feature attribute can't carry — so switch
            // between two CONSTANT vectors on a per-feature boolean instead of interpolating one.
            spd.textOffset = NSExpression(format: "TERNARY(stacked == YES, %@, %@)",
                                          Self.spdOffsetStacked, Self.spdOffsetSolo)
            spd.textOptional = NSExpression(forConstantValue: true)
            spd.textIgnoresPlacement = NSExpression(forConstantValue: true)
            spd.minimumZoomLevel = 7
            style.addLayer(spd)
            assert(style.layer(withIdentifier: "route-wpt-sym") != nil, "setupRouteWptLayers: sym layer missing")
            assert(style.source(withIdentifier: "route-wpt") != nil, "setupRouteWptLayers: source missing")
        }

        /// One point per flown waypoint, carrying its glyph, ident and constraint text.
        ///
        /// Deduped on ident+position, NOT ident alone: a procedure turn or a hold that revisits the same fix
        /// must not stack two identical labels, but two different fixes that share an ident (they exist) are
        /// both real points on the route. `static` and pure so it is unit-testable without a map.
        static func routeWptFeatures(_ legs: [ResolvedLeg]) -> [MLNPointFeature] {
            var out: [MLNPointFeature] = []
            var seen = Set<String>()
            var indexOf: [String: Int] = [:]                             // key → its feature, for role promotion
            for leg in legs.prefix(maxRouteWpts) where !leg.isPathOnly {  // bounded (rule 2)
                let key = "\(leg.ident)@\(q(leg.coord.lat)),\(q(leg.coord.lon))"
                guard seen.insert(key).inserted else {
                    // A course reversal or a hold can bring the route back through a fix it already
                    // passed, and the two visits are coded from different sides. Keep the more specific
                    // role on the ONE surviving label rather than whichever visit happened to be first —
                    // the same rule ProcedureRoute.appendDeduped applies at the transition join.
                    if let i = indexOf[key], i < out.count,
                       let prior = out[i].attributes["role"] as? String,
                       ProcedureRoute.roleRank(leg.role) > ProcedureRoute.roleRank(LegRole(rawValue: prior) ?? .none) {
                        out[i].attributes["role"] = leg.role.rawValue
                    }
                    continue
                }
                indexOf[key] = out.count
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: leg.coord.lat, longitude: leg.coord.lon)
                let altText = SmartRouteLabel.altText(leg.constraint)
                let spdText = SmartRouteLabel.speedText(leg.constraint)
                // Empty strings render nothing, so absent constraints need no per-feature layer filtering.
                f.attributes = ["glyph": routeWptGlyph(leg),
                                "ident": leg.ident,
                                "role": leg.role.rawValue,
                                "alt": altText ?? "",
                                "spd": spdText ?? "",
                                "stacked": altText != nil]
                out.append(f)
            }
            assert(out.count <= maxRouteWpts, "routeWptFeatures: exceeded the leg cap")
            assert(out.count == seen.count, "routeWptFeatures: dedupe key set out of step with output")
            return out
        }

        /// Per-feature ident colour, keyed on the leg's published `role` attribute.
        ///
        /// Only the TEXT is tinted, never the glyph: `iconColor` "must be set to a template image"
        /// (MLNSymbolStyleLayer.h) and the route-fix star and the FAA airport symbols are drawn artwork,
        /// not templates — recolouring them would either no-op or flatten the airport symbology this
        /// mode deliberately keeps. The ident sits directly under the mark, so the colour reads as
        /// belonging to it either way.
        ///
        /// Roles NOT in this table fall through to `routeWptText`, which is every enroute leg and every
        /// procedure leg the FAA marks no role on — the common case by a wide margin.
        static func routeWptTextExpr(_ t: MapTheme) -> NSExpression {
            let fallback = MapTheme.hexString(t.routeWptText)
            assert(fallback.count == 7, "routeWptTextExpr: hexString did not produce #RRGGBB")
            let table: [Any] = ["match", ["get", "role"],
                LegRole.initialApproachFix.rawValue,  MapTheme.hexString(t.routeWptIAF),
                LegRole.finalApproachFix.rawValue,    MapTheme.hexString(t.routeWptFAF),
                LegRole.missedApproachPoint.rawValue, MapTheme.hexString(t.routeWptMAP),
                fallback]
            assert(table.count == 3 + 2 * 3, "routeWptTextExpr: match arity is wrong")   // op + input + pairs + default
            return NSExpression(mglJSONObject: table)
        }

        /// Airports keep their real FAA symbol (towered/fuel/runway-axis detail is exactly the "minimal
        /// airport data" this mode wants); everything else on the route gets the white route-fix star.
        private static func routeWptGlyph(_ leg: ResolvedLeg) -> String {
            guard leg.kind == .airport else { return "rw-fix" }
            return "apt-" + AirportSymbolData.spec(leg.ident, category: cachedCategory(leg.ident)).signature
        }

        /// The route cap mirrors ProcedureRoute's own leg cap — beyond it the map is not the problem.
        static let maxRouteWpts = 600

        /// Push the flown route's waypoints onto the map. Signature-gated like `updateRoute`: the label text
        /// is part of the signature, so an ATC-amended crossing restriction on an unchanged geometry still
        /// redraws. Built on the main actor (≤600 features, same as traffic).
        func updateRouteWaypoints(_ legs: [ResolvedLeg], on map: MLNMapView) {
            inRouteLegs = legs
            guard let style = map.style,
                  let src = style.source(withIdentifier: "route-wpt") as? MLNShapeSource else { return }
            let sig = legs.prefix(Self.maxRouteWpts).map {
                "\($0.ident):\(Self.q($0.coord.lat)),\(Self.q($0.coord.lon))"
                    + ":\(SmartRouteLabel.altText($0.constraint) ?? "")"
                    + ":\(SmartRouteLabel.speedText($0.constraint) ?? "")"
                    + ":\($0.role.rawValue)"        // role drives ident COLOUR — must force a rebuild
            }.joined(separator: "|")
            guard sig != appliedRouteWptSig else { return }              // unchanged → skip the rebuild
            appliedRouteWptSig = sig
            let feats = Self.routeWptFeatures(legs)
            // Every caller is a main-thread path (updateUIView's applyLatest, and the MLNMapViewDelegate's
            // didFinishLoading), so this is an isolation annotation catching up with reality rather than a
            // hop — and the alternative, deferring into a Task, would let the map draw one frame of
            // unglyphed waypoints. Asserted rather than assumed.
            assert(Thread.isMainThread, "updateRouteWaypoints must run on the main thread")
            MainActor.assumeIsolated {
                Self.registerAirportGlyphs(in: feats, style: style)      // airport signatures this set uses
            }
            src.shape = MLNShapeCollectionFeature(shapes: feats)
            assert(feats.count <= Self.maxRouteWpts, "updateRouteWaypoints: over the cap")
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

        /// Reported flight category per ident, refreshed from MetarStore by the host and read by the
        /// static feature builders that run OFF the main actor. A Swift Dictionary is copy-on-write and
        /// not thread-safe: a write on main while a detached overlay-rebuild subscripts it is a data
        /// race — a torn read or heap corruption that can crash the moving map during a normal pan. All
        /// access goes through `categoryLock`; the version counter rides the same lock so a reader never
        /// sees a bumped version against the old map.
        private static let categoryLock = NSLock()
        nonisolated(unsafe) private static var _categoryByIdent: [String: AirportSymbol.Category] = [:]
        nonisolated(unsafe) private static var _categoryVersion = 0
        /// Bumped whenever the host publishes new categories, so the overlay rebuild picks them up on the
        /// SAME frame rather than a pan late.
        static var categoryVersion: Int {
            categoryLock.lock(); defer { categoryLock.unlock() }
            return _categoryVersion
        }
        static func publish(categories: [String: AirportSymbol.Category]) {
            categoryLock.lock(); defer { categoryLock.unlock() }
            guard categories != _categoryByIdent else { return }
            _categoryByIdent = categories
            _categoryVersion &+= 1
        }
        static func cachedCategory(_ ident: String) -> AirportSymbol.Category? {
            categoryLock.lock(); defer { categoryLock.unlock() }
            return _categoryByIdent[ident.uppercased()]
        }

        /// The registered image name for a nav point, mirroring NearbyMarkerView.navaidGlyph's classification.
        static func glyphName(_ np: NavPoint) -> String {
            switch np.kind {
            case .airport: return "apt-" + AirportSymbolData.spec(np.ident, category: cachedCategory(np.ident)).signature
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
            // THE DECLUTTER. `.smartDark` suppresses the enroute furniture outright — airways, airspace and
            // the off-route navaids/fixes — so the only fixes on the map are the ones being flown (they get
            // their own route-wpt layers, fed from the resolved flight plan rather than a region query).
            // Airports survive: "which field is that" stays a question the dark base should answer. The
            // pilot's overlay toggles are still honored (a toggle OFF hides airports here too); this only
            // adds suppression, never re-enables anything they turned off. TFRs/traffic/weather/ownship are
            // untouched — decluttering must never hide a hazard.
            // AIRSPACE IS NOT CLUTTER. The first cut of this mode suppressed it along with the airways and
            // the off-route navaids, which was wrong: a Class B shelf or a restricted area is a CONSTRAINT
            // on where the aircraft may legally be, and a decluttered chart that omits it is not simpler,
            // it is missing the part that can violate you. Airways and off-route fixes are genuinely
            // enroute furniture and stay suppressed; airspace now follows the pilot's own toggle in every
            // mode. (Its labels still drop at the wider scales, exactly as they do on the FAA bases.)
            // ONE composition point for the decluttered set: the purpose-built dark base forces it, and
            // the pilot's own toggle asks for it on whatever base they are on. Everything downstream
            // reads this single value rather than re-testing the layer.
            let smart = (layer == .smartDark) || declutterOn
            let wantAir = showAirspace && scale < 14, wantLbl = showAirspace && scale < 7
            let wantAwy = showAirways && scale < 9 && !smart, wantNear = showNearby && scale < 5.5
            let showFixes = wantNear && wantFixes && !smart
            overlayGen += 1
            let gen = overlayGen
            Task { @MainActor in
                let f = await Task.detached(priority: .userInitiated) {
                    () -> (asp: [MLNPolygonFeature], lbl: [MLNPointFeature], awy: [MLNPolylineFeature], nav: [MLNPointFeature]) in
                    let a = Coordinator.airspaceFeatures(bb, want: wantAir, labels: wantLbl)
                    return (a.polys, a.labels, Coordinator.airwayFeatures(bb, want: wantAwy),
                            Coordinator.navFeatures(bb, near: wantNear, fixes: showFixes,
                                                    airportsOnly: smart))
                }.value
                guard gen == self.overlayGen, let style = mapView.style else { return }
                (style.source(withIdentifier: "airspace") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.asp)
                (style.source(withIdentifier: "airspace-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.lbl)
                (style.source(withIdentifier: "airways") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.awy)
                // Register the FAA airport glyphs this feature set references. Airports that look alike
                // share a signature, so this is a handful of images even for a full screen of fields.
                Coordinator.registerAirportGlyphs(in: f.nav, style: style)
                (style.source(withIdentifier: "nav") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.nav)
            }
        }

        /// Register an image for every `apt-…` glyph name the features reference, rendering each signature
        /// once. MapLibre keeps images by name, so a re-register of an existing name is a cheap no-op.
        @MainActor static func registerAirportGlyphs(in features: [MLNPointFeature], style: MLNStyle) {
            var wanted = Set<String>()
            for f in features.prefix(512) {                         // bounded (rule 2)
                if let g = f.attributes["glyph"] as? String, g.hasPrefix("apt-") { wanted.insert(g) }
            }
            assert(wanted.count <= 512, "registerAirportGlyphs: unexpectedly many signatures")
            for name in wanted {
                guard style.image(forName: name) == nil else { continue }
                let sig = String(name.dropFirst(4))
                guard let spec = AirportSymbol.Spec(signature: sig) else { continue }
                style.setImage(AirportSymbolRenderer.image(for: spec), forName: name)
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
                    // Restricted areas get a NAME line above the altitude block. Without it a standing
                    // national-defense area was two lines of red numbers with nothing saying what they
                    // belonged to — a pilot could see a restriction and not know it was one, let alone
                    // which. Class B/C/D stay altitudes-only; they are ambient and the shape says enough.
                    let alts = "\(AirspaceLabelAnnotation.altText(a.ceilingFt))\n\(AirspaceLabelAnnotation.altText(a.floorFt))"
                    let tag = Coordinator.restrictionTag(cls: a.cls, name: a.name)
                    f.attributes = ["cls": a.cls, "alt": tag.isEmpty ? alts : "\(tag)\n\(alts)"]
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
        /// `airportsOnly` is the decluttered night base's filter: type 0 is airports, 1 navaids, 2 fixes
        /// (ios/Tools/build_nav_db.py), so dropping to `[0]` leaves the fields and removes the navaid
        /// clutter. Passed in rather than read from the coordinator because this is nonisolated and runs in
        /// the detached overlay task — same as `near`/`fixes`.
        static func navFeatures(_ bb: BBox, near: Bool, fixes: Bool,
                                airportsOnly: Bool = false) -> [MLNPointFeature] {
            assert(bb.minLat <= bb.maxLat, "navFeatures: degenerate box")
            assert(!(airportsOnly && fixes), "navFeatures: airports-only contradicts drawing fixes")
            guard near else { return [] }
            var out: [MLNPointFeature] = []
            var seen = Set<String>()
            let types: Set<Int> = airportsOnly ? [0] : [0, 1]
            for np in NavDatabase.nearby(bb, types: types, limit: 160) where seen.insert(np.ident).inserted {
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
        // The bundled "TFR" features are the 8 STANDING national-defense areas (Dallas, Beale AFB,
        // Grand Forks …), not live NOTAMs. They were pixel-identical to the live TFR layer, so a pilot
        // tapped one expecting a reason and effective times; dropping them to 0.06 fixed the confusion
        // by making them nearly INVISIBLE, which is worse — they are surface-to-unlimited restrictions
        // and belong on the chart. They are visible again here and told apart by the card instead: the
        // live TFR layer now draws louder (0.24), and tapping either one opens the right explanation.
        private static func aspOpacityExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "P", 0.18, "TFR", 0.14, "R", 0.10, "W", 0.10, "A", 0.10, "MOA", 0.10, 0.05])
        }
        /// A short, chart-style tag for airspace you may not simply enter, or "" for ambient classes.
        ///
        /// The bundled `cls == "TFR"` features are the 8 permanent national-defense areas, all named
        /// "<PLACE> NATIONAL DEFENSE AIRSPACE TFR" — far too long for a chart label, and the trailing
        /// "TFR" is exactly the word that makes a pilot expect a live NOTAM. Prohibited and restricted
        /// areas already carry their designator (P-40, R-2301) in the name; lift it out.
        static func restrictionTag(cls: String, name: String) -> String {
            switch cls.uppercased() {
            case "TFR": return "NAT'L DEFENSE"
            case "P", "R":
                let upper = name.uppercased()
                for token in upper.split(separator: " ").prefix(8)
                where token.count <= 8 && (token.hasPrefix("P-") || token.hasPrefix("R-")) {
                    return String(token)
                }
                return cls.uppercased() == "P" ? "PROHIBITED" : "RESTRICTED"
            default: return ""
            }
        }

        private static func aspWidthExpr() -> NSExpression {
            NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "R", 2.4, "P", 2.4, "TFR", 2.4, "W", 1.8, "A", 1.8, "MOA", 1.8, "B", 1.5, "C", 1.5, 1.2])
        }

        // MARK: per-theme palette re-apply (cinematic restyle)

        /// One-shot palette application: runs only when the theme actually changed, or after a style
        /// rebuild reset `appliedMapTheme`. A LIVE restyle via runtime paint setters — the map is never
        /// remounted for a theme change (ARCHITECTURE.md: the map is never torn down; remount would
        /// refetch + re-upload ~40 MB of raster for what a dozen GPU uniform updates accomplish).
        func applyMapThemeIfNeeded(on map: MLNMapView) {
            // The BASE LAYER is part of the palette identity, not just the theme: `.smartDark` overrides
            // the app theme entirely (MapTheme.forLayer). Without `smart` in this guard a layer-only
            // switch — the common case, theme and brightness unchanged — early-returns and leaves the
            // sea, land, vectors and every raster painted in the OTHER mode's palette.
            let smart = (inLayer == .smartDark)
            guard let style = map.style, styleGate.isConfigured(style),
                  inTheme != appliedMapTheme || inChartBrightness != appliedBrightness
                      || smart != appliedSmartMode else { return }
            let t = currentMapTheme
            applyBaseMapTheme(style, t)
            applyVectorMapTheme(style, t)
            applyRasterMapTheme(style, t)
            appliedMapTheme = inTheme
            appliedBrightness = inChartBrightness
            appliedSmartMode = smart
        }

        private func applyBaseMapTheme(_ style: MLNStyle, _ t: MapTheme) {
            (style.layer(withIdentifier: "bg") as? MLNBackgroundStyleLayer)?.backgroundColor =
                NSExpression(forConstantValue: globeProjection ? t.globeSea : t.sea)
            (style.layer(withIdentifier: "land-fill") as? MLNFillStyleLayer)?.fillColor =
                NSExpression(forConstantValue: t.land)
            (style.layer(withIdentifier: "coastline") as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: t.coastline)
            if let veil = style.layer(withIdentifier: "night-veil-fill") as? MLNFillStyleLayer {
                veil.fillOpacity = NSExpression(forConstantValue: t.nightVeilOpacity)
                veil.isVisible = t.nightVeilOpacity > 0
            }
            starfield?.apply(space: t.space, starColor: t.starColor, alphaScale: CGFloat(t.starAlphaScale))
        }

        private func applyVectorMapTheme(_ style: MLNStyle, _ t: MapTheme) {
            (style.layer(withIdentifier: "airways-line") as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: t.airway)
            if let l = style.layer(withIdentifier: "airways-label") as? MLNSymbolStyleLayer {
                l.textColor = NSExpression(forConstantValue: t.airwayLabelText)
                l.textHaloColor = NSExpression(forConstantValue: t.airwayLabelHalo)
            }
            let asp = Self.aspColorExpr(t)
            (style.layer(withIdentifier: "airspace-fill") as? MLNFillStyleLayer)?.fillColor = asp
            (style.layer(withIdentifier: "airspace-outline") as? MLNLineStyleLayer)?.lineColor = asp
            (style.layer(withIdentifier: "airspace-label") as? MLNSymbolStyleLayer)?.textColor = asp
            if let l = style.layer(withIdentifier: "nav-sym") as? MLNSymbolStyleLayer {
                l.textColor = NSExpression(forConstantValue: t.navLabelText)
                l.textHaloColor = NSExpression(forConstantValue: t.navLabelHalo)
            }
            let tfr = NSExpression(forConstantValue: t.airspaceColor("TFR"))
            (style.layer(withIdentifier: "tfr-fill") as? MLNFillStyleLayer)?.fillColor = tfr
            (style.layer(withIdentifier: "tfr-outline") as? MLNLineStyleLayer)?.lineColor = tfr
            (style.layer(withIdentifier: "tfr-label") as? MLNSymbolStyleLayer)?.textColor = tfr
            (style.layer(withIdentifier: "track-line") as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: t.track)
            (style.layer(withIdentifier: "route-line") as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: t.route)
            // Alpha < 1 (0.95): set as a UIColor through NSExpression, never through MapTheme.hexString,
            // which asserts opacity because style-JSON colors must be opaque.
            (style.layer(withIdentifier: "hold-line") as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: t.hold)
            if let l = style.layer(withIdentifier: "hold-label") as? MLNSymbolStyleLayer {
                l.textColor = NSExpression(forConstantValue: t.hold)
                l.textHaloColor = NSExpression(forConstantValue: t.navLabelHalo)
            }
            if let l = style.layer(withIdentifier: "route-wpt-sym") as? MLNSymbolStyleLayer {
                // The SAME data-driven expression setup builds, not a constant — assigning a constant
                // here would silently drop the role colouring on the first theme or base-layer switch.
                l.textColor = Self.routeWptTextExpr(t)
                l.textHaloColor = NSExpression(forConstantValue: t.navLabelHalo)
            }
            (style.layer(withIdentifier: "route-wpt-alt") as? MLNSymbolStyleLayer)?.textColor =
                NSExpression(forConstantValue: t.routeWptAlt)
            (style.layer(withIdentifier: "route-wpt-spd") as? MLNSymbolStyleLayer)?.textColor =
                NSExpression(forConstantValue: t.routeWptSpeed)
        }

        /// Raster paint on every chart raster (faa + bundled bases + satellite). The radar keeps its
        /// own translucency and the plate overlay its user-controlled opacity/invert — both excluded.
        private func applyRasterMapTheme(_ style: MLNStyle, _ t: MapTheme) {
            assert(style.layers.count < 256, "applyRasterMapTheme: unexpected layer explosion")
            for layer in style.layers {                              // bounded (style layer list)
                guard let rl = layer as? MLNRasterStyleLayer,
                      rl.identifier != "wxradar-layer", rl.identifier != "plate-raster" else { continue }
                Self.applyRasterPaint(to: rl, t)
            }
        }

        /// Shared with syncFAASource: the "faa" layer is destroyed + recreated on every pack-set change
        /// (pan into new coverage, VFR⇄IFR switch, late download), and a fresh layer must not wash out
        /// the theme's raster dim until the next theme switch.
        static func applyRasterPaint(to rl: MLNRasterStyleLayer, _ t: MapTheme) {
            rl.maximumRasterBrightness = NSExpression(forConstantValue: t.rasterBrightnessMax)
            rl.rasterSaturation = NSExpression(forConstantValue: t.rasterSaturation)
            rl.rasterContrast = NSExpression(forConstantValue: t.rasterContrast)
        }

        /// Theme-aware variant of `aspColorExpr` used by the re-apply pass (setup keeps the classic one).
        private static func aspColorExpr(_ t: MapTheme) -> NSExpression {
            func h(_ cls: String) -> String { MapTheme.hexString(t.airspaceColor(cls)) }
            return NSExpression(mglJSONObject: ["match", ["get", "cls"],
                "C", h("C"), "TFR", h("TFR"), "R", h("R"), "P", h("P"),
                "W", h("W"), "A", h("A"), "MOA", h("MOA"), h("B")])
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
        /// The bundled chart bases (VFR / IFR-low / IFR-high) as SEPARATE, ALWAYS-LOADED raster layers, each on
        /// its own "/base/<name>/" server path. All three stay mounted and tile-loaded at once; switching the
        /// chart layer only flips `rasterOpacity` — NOT `visibility`, which would make MapLibre unload the tiles
        /// and reintroduce the very fetch-decode-upload stall we're removing. So changing chart layer is instant
        /// with no re-request. They sit above satellite and below the downloaded-pack "faa" layer, so the pilot's
        /// downloads always win. Composited over satellite, so transparent chart collars reveal terrain, not sea.
        /// GLOBE only (the flat map keeps its existing vector-land + downloaded-pack behaviour).
        /// Declared raster tileSize, used here as a PURE PER-SOURCE ZOOM BIAS.
        ///
        /// MapLibre chooses the raster level with `round`, not `floor`:
        ///     tileZ = clamp(round(mapZoom + log2(512 / tileSize)), minzoom, maxzoom)
        /// (fork `src/mbgl/util/tile_cover.cpp:151`, `tileSize_D = 512`). At the conventional 256 that is
        /// `round(Z + 1)`, so the level DROPS at the half-zoom — at Z = 6.501 the chart is drawn at 1.41x
        /// supersample and one hair of pinch later, at Z = 6.499, at 1.41x MAGNIFICATION. That instant 2x
        /// resolution loss, half an octave before the integer zoom the eye reads as the level change, is
        /// the "it reduces the chart to a lower resolution prematurely" the pilot reported.
        ///
        /// 181 gives log2(512/181) = 1.500154, so `tileZ = floor(Z) + 2` across the whole octave: the
        /// deeper level is held all the way down to the integer instead of being surrendered half an
        /// octave early, and the worst case within an octave becomes ~1.0 chart-pixels per screen point
        /// instead of 0.707. The chart is then never drawn magnified.
        ///
        /// 181 AND NOT 182, which is the tempting choice and is a no-op where it matters. 182 gives a
        /// bias of 1.4922, so at EXACTLY integer zoom `round(8 + 1.4922) = 9` — the same level 256
        /// already picks. The app parks its camera on integer zooms (`zoomLevel: 8.0`, `7.0`), so a 182
        /// bias would have changed nothing at the commonest position on screen while still paying the
        /// tile cost everywhere else. 181's bias is a hair OVER 1.5, which is what puts the step at the
        /// integer rather than just after it.
        ///
        /// tileSize's only other consumer is the tile cache-size heuristic in `tile_pyramid.cpp`, which
        /// scales the retained-tile budget with screen area / tileSize² — so a smaller value also buys a
        /// proportionally larger cache, which is the right direction here. If the tile budget ever
        /// measures badly on an older device, 215 is the half-strength setting (+0.25 bias).
        static let rasterTileSize = 181

        /// The level MapLibre will request for a raster source — the formula above, made testable.
        static func rasterTileZ(mapZoom: Double, tileSize: Int, maxZoom: Int, minZoom: Int = 0) -> Int {
            assert(tileSize > 0 && tileSize <= 512, "rasterTileZ: implausible tileSize")
            assert(maxZoom >= 0 && maxZoom <= 24, "rasterTileZ: out-of-range maxZoom")
            let biased = mapZoom + log2(512.0 / Double(tileSize))
            return min(max(Int(biased.rounded()), minZoom), maxZoom)
        }

        private func setupChartBaseLayers(_ style: MLNStyle) {
            guard globeProjection, serverPort > 0 else { server.setBaseReaders([:]); return }
            assert(Self.baseNames.count <= 8, "setupChartBaseLayers: unexpectedly many bundled bases")
            var mounted: [String: MBTilesReader] = [:]
            for (lyr, name) in Self.baseNames {                          // bounded by baseNames (rule 2)
                let reader: MBTilesReader?
                switch lyr {
                case .sectional: reader = bundledVFRBase
                case .ifrLow:    reader = bundledIFRLowBase
                case .ifrHigh:   reader = bundledIFRHighBase
                case .smartDark: reader = bundledTerrainBase
                case .satellite: reader = nil       // its own opaque bottom layer (setupSatelliteLayer)
                }
                guard let reader else { continue }
                mounted[name] = reader
                let ident = "base-\(name)"
                if style.source(withIdentifier: ident) == nil {
                    let src = MLNRasterTileSource(identifier: ident,
                        tileURLTemplates: ["http://127.0.0.1:\(serverPort)/base/\(name)/{z}/{x}/{y}"],
                        options: [.tileSize: Self.rasterTileSize,
                                  .minimumZoomLevel: NSNumber(value: reader.minZoom),
                                  // TRUE maxzoom (no +overzoomLevels): tile_pyramid clamps ideal->maxzoom and
                                  // MapLibre magnifies the deepest real tile on the GPU at zero CPU cost. The
                                  // +N is a MapKit-only workaround; keeping it here forced every z8-z12 request
                                  // through overzoomedPNG (SQLite + WebP decode + CoreGraphics + re-encode) for
                                  // pixel-identical output, paid on all three always-loaded bases.
                                  .maximumZoomLevel: NSNumber(value: reader.maxZoom)])
                    style.addSource(src)
                    let rl = MLNRasterStyleLayer(identifier: ident, source: src)
                    Self.applyRasterPaint(to: rl, currentMapTheme)   // created after the theme pass
                    // The terrain relief goes ABOVE the vector land, every other base BELOW it. The chart
                    // bases are opaque and world-covering, so land under them is invisible anyway and is
                    // hidden outright on the globe; the relief instead needs to READ AS the land it shades,
                    // with the silhouette showing through its transparent ocean and beyond its CONUS box.
                    // (setupLandBase always re-inserts land directly above "bg", i.e. below this layer, so
                    // the order survives a style rebuild.)
                    if lyr == .smartDark, let coast = style.layer(withIdentifier: "coastline") {
                        style.insertLayer(rl, above: coast)
                    } else if let sat = style.layer(withIdentifier: "satellite") { style.insertLayer(rl, above: sat) }
                    else if let bg = style.layer(withIdentifier: "bg") { style.insertLayer(rl, above: bg) }
                    else { style.addLayer(rl) }
                }
                if let rl = style.layer(withIdentifier: ident) as? MLNRasterStyleLayer {
                    rl.rasterOpacity = NSExpression(forConstantValue: (lyr == layer) ? 1.0 : 0.0)
                }
            }
            // Blue Marble is the opaque world backstop for every OTHER layer, and it would show straight
            // through the terrain relief's transparent ocean (and outside its CONUS box) — the one thing
            // that would break the near-black base. Opacity, not visibility: the tiles stay resident so
            // switching back out of Dark is instant, same rule as the chart bases above.
            (style.layer(withIdentifier: "satellite") as? MLNRasterStyleLayer)?.rasterOpacity =
                NSExpression(forConstantValue: (layer == .smartDark) ? 0.0 : 1.0)
            server.setBaseReaders(mounted)
            applyLandBaseVisibility(style)
            assert(mounted.count <= Self.baseNames.count, "setupChartBaseLayers: mounted more bases than named")
        }

        /// The vector land base is hidden exactly when an opaque raster chart base is drawing under the globe
        /// (it would be invisible anyway and z-fights the raster). For the non-raster rows — "Standard map" and
        /// "Satellite" — it is the only land there is, so it must come back.
        /// Hide the vector land fallback whenever the opaque satellite raster is mounted on the globe.
        ///
        /// This used to also require `layer.isRaster`, which is FALSE for `.satellite` — so picking the
        /// Satellite layer left the opaque Natural Earth `land-fill` drawn ABOVE the Blue Marble raster
        /// (setupLandBase inserts land above "bg" at style load; setupSatelliteLayer inserts satellite
        /// above "bg" later, i.e. BELOW land). The result: Satellite and the old Standard map rendered
        /// byte-identically and neither ever showed Blue Marble. The satellite raster is opaque and
        /// world-covering, so the land fallback is redundant for EVERY layer once it exists.
        /// `.smartDark` is the exception: its terrain relief is CONUS-only and its ocean is transparent, so
        /// the vector land polygon is the only geography outside coverage (Canada, Mexico, Alaska, Hawaii)
        /// and the only thing separating land from water anywhere. It draws BELOW the terrain raster
        /// (setupChartBaseLayers anchors terrain above "coastline"), so it never fights the relief.
        private func applyLandBaseVisibility(_ style: MLNStyle) {
            assert(Thread.isMainThread, "style mutation must run on the main thread")
            let hide = globeProjection && bundledSatelliteBase != nil && layer != .smartDark
            for id in ["land-fill", "coastline"] {                       // bounded (rule 2)
                style.layer(withIdentifier: id)?.isVisible = !hide
            }
            assert(style.layer(withIdentifier: "bg") != nil, "applyLandBaseVisibility: base style missing")
        }

        /// The satellite base as a SEPARATE opaque bottom raster layer (served on the server's "/sat/" path), so
        /// the chart layer's transparent collars composite over satellite instead of the sea. GLOBE only, once.
        private func setupSatelliteLayer(_ style: MLNStyle) {
            server.setSatelliteReader((globeProjection ? bundledSatelliteBase : nil))
            guard globeProjection, bundledSatelliteBase != nil, serverPort > 0,
                  style.source(withIdentifier: "satellite") == nil else { return }
            let src = MLNRasterTileSource(identifier: "satellite",
                tileURLTemplates: ["http://127.0.0.1:\(serverPort)/sat/{z}/{x}/{y}"],
                // TRUE maxzoom (see the chart bases above) — MapLibre magnifies past it for free.
                options: [.tileSize: Self.rasterTileSize, .minimumZoomLevel: 0,
                          .maximumZoomLevel: NSNumber(value: bundledSatelliteBase?.maxZoom ?? 5)])
            style.addSource(src)
            let layer = MLNRasterStyleLayer(identifier: "satellite", source: src)   // bottom raster (above bg)
            Self.applyRasterPaint(to: layer, currentMapTheme)   // created after the theme pass
            if let bg = style.layer(withIdentifier: "bg") { style.insertLayer(layer, above: bg) }
            else { style.addLayer(layer) }
        }

        @MainActor private func syncFAASource(on map: MLNMapView) {
            guard serverPort > 0, let style = map.style else { return }
            setupSatelliteLayer(style)                         // globe: opaque satellite bottom layer (once)
            setupChartBaseLayers(style)                        // globe: all 3 bases preloaded, opacity-switched
            let readers = store.readers                        // faa source = the pilot's DOWNLOADED packs only
            assert(readers.count <= 128, "syncFAASource: unexpectedly many packs mounted")
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
                // TRUE pack maxzoom, not faaMax + overzoomLevels. Declaring the deeper band made
                // MapLibre request levels the packs do not have, and every one of those went through
                // `MBTilesHTTPServer.overzoomedPNG` — SQLite read + WebP decode + CoreGraphics redraw +
                // PNG re-encode, per tile, on the tile thread — for output the GPU produces for free by
                // magnifying the deepest real tile. The bundled bases already declare the true maxzoom
                // (see setupChartBaseLayers) and this source had simply never been brought into line.
                // It matters more with the tileSize bias above, which would otherwise open that CPU path
                // half a zoom earlier and at ~1.8x the tile count.
                options: [.tileSize: Self.rasterTileSize,
                          .maximumZoomLevel: NSNumber(value: faaMax)])
            style.addSource(fresh)
            let faaRaster = MLNRasterStyleLayer(identifier: "faa", source: fresh)   // BOTTOM (below the first vector layer)
            Self.applyRasterPaint(to: faaRaster, currentMapTheme)   // fresh layer must keep the theme's dim
            // Anchor the OPAQUE FAA chart BELOW the translucent radar when the radar exists — else a pack
            // remount (pan to new coverage, VFR⇄IFR switch, late download) re-inserts faa above the radar
            // (they shared the "airways-line" anchor) and the precipitation vanishes until the next ~10-min
            // frame rollover (a red-hat finding). Falls back to the old anchor when radar is off.
            // The overlaid PLATE is the other layer that must stay above the chart. Both anchors above are
            // absent in a legitimate state (radar off, and the vector overlays not yet built for this
            // region/zoom), and the old fallback then APPENDED the opaque sectional on top of everything —
            // burying a georeferenced approach plate completely. Measured stack in that state:
            //   bg > satellite > base-* > annotations.points > plate-raster > faa
            // The plate still drew, and its corner gear still tracked it, so nothing looked broken; the
            // sectional simply covered it. It re-fires whenever the pack set changes — a download
            // completing, panning into new coverage, a VFR⇄IFR switch — so a plate could vanish mid-flight.
            if let radar = style.layer(withIdentifier: "wxradar-layer") { style.insertLayer(faaRaster, below: radar) }
            else if let bottom = style.layer(withIdentifier: "airways-line") { style.insertLayer(faaRaster, below: bottom) }
            else if let plate = style.layer(withIdentifier: "plate-raster") { style.insertLayer(faaRaster, below: plate) }
            else { style.addLayer(faaRaster) }
            // The night veil must sit DIRECTLY above the chart, whatever anchor faa landed under —
            // re-float it every remount so a pan into new coverage can't leave the veil buried.
            if let veil = style.layer(withIdentifier: "night-veil-fill") {
                style.removeLayer(veil)
                style.insertLayer(veil, above: faaRaster)
            }
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

        /// The active approach's holding patterns, drawn as racetracks. Signature-gated like the route so
        /// an unchanged set costs nothing per tick. nonisolated-safe geometry: the racetrack is pure math
        /// on the pattern, no map state.
        func updateHolds(_ holds: [ApproachHold], on mapView: MLNMapView) {
            guard let src = mapView.style?.source(withIdentifier: "holds") as? MLNShapeSource else { return }
            // The signature must cover everything that changes the DRAWN shape, not just identity:
            // two approaches can publish a hold at the same fix+seq with a different course or turn,
            // and the local variation rotates the depiction. An id-only signature kept the old
            // racetrack on screen across such a change.
            let sig = holds.map { h in
                String(format: "%@:%.1f:%@:%.5f:%.5f:%.1f", h.id, h.pattern.inboundCourseMag,
                       h.pattern.turn.rawValue, h.pattern.coord.lat, h.pattern.coord.lon,
                       h.magneticVariation ?? 999)
            }.joined(separator: "|")
            guard sig != appliedHoldSig else { return }
            appliedHoldSig = sig
            guard !holds.isEmpty else { src.shape = nil; return }
            var shapes: [MLNShape] = []
            for h in holds.prefix(8) {                                   // bounded (rule 2)
                var pts = h.pattern.racetrack(magneticVariation: h.magneticVariation ?? 0).map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
                guard pts.count >= 2 else { continue }
                shapes.append(MLNPolylineFeature(coordinates: &pts, count: UInt(pts.count)))
                let label = MLNPointFeature()
                label.coordinate = CLLocationCoordinate2D(latitude: h.pattern.coord.lat,
                                                          longitude: h.pattern.coord.lon)
                label.attributes = ["ident": h.pattern.fix]
                shapes.append(label)
            }
            assert(shapes.count <= 16, "updateHolds: cap exceeded")   // a racetrack + its label per hold
            src.shape = shapes.isEmpty ? nil : MLNShapeCollectionFeature(shapes: shapes)
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
        private var lastOwnAccuracy: Double?
        private var lastOwnIntegrity: GPSIntegrityState = .unknown
        var inOwnAccuracy: Double?
        var inOwnIntegrity: GPSIntegrityState = .unknown
        private var lastTraffic: [Aircraft] = []
        // Last-APPLIED signatures — early-return guards so an unrelated AppModel publish (e.g. the audio VU
        // meter, ~10-30×/s) can't re-tessellate + re-upload unchanged route/ownship/traffic/TFR geometry.
        // These are the map inputs' identity, distinct from the last-INPUT caches above (which exist so
        // didFinishLoading can re-apply). Set ONLY after a real apply, so the first post-style apply still runs.
        private var appliedRouteSig: String?
        private var appliedHoldSig: String?
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
        func updateOwnship(_ coord: CLLocationCoordinate2D?, course: Double?,
                           accuracyM: Double? = nil, integrity: GPSIntegrityState = .unknown,
                           on map: MLNMapView) {
            lastOwnship = coord; lastOwnCourse = course
            lastOwnAccuracy = accuracyM; lastOwnIntegrity = integrity
            guard let src = map.style?.source(withIdentifier: "ownship") as? MLNShapeSource else { return }
            // The signature carries integrity and a COARSE accuracy bucket as well as position: the ring
            // must be rebuilt when the fix quality changes, but a metre of accuracy jitter at 1 Hz must
            // not rebuild a 64-point polygon every tick.
            let sig = coord.map {
                "\(Self.qJit($0.latitude)),\(Self.qJit($0.longitude)),\(Self.qDeg(course ?? 0))"
                + ",\(integrity.rawValue),\(Int((accuracyM ?? 0) / 5))"
            } ?? "nil"
            guard sig != appliedOwnSig else { return }
            appliedOwnSig = sig
            guard let coord else {                                       // no fix → hide symbol AND ring
                src.shape = nil
                (map.style?.source(withIdentifier: "accuracy") as? MLNShapeSource)?.shape = nil
                return
            }
            let f = MLNPointFeature(); f.coordinate = coord
            f.attributes = ["rot": (course.map { $0 - 90 } ?? 0), "img": Self.ownshipImageName(integrity)]
            src.shape = f
            updateAccuracyRing(coord, accuracyM: accuracyM, integrity: integrity, on: map)
        }

        /// Symbol name matching the images registered in `setupDynamicLayers`.
        private static func ownshipImageName(_ state: GPSIntegrityState) -> String {
            switch state {
            case .degraded:             return "own-ship-degraded"
            case .unreliable, .suspect: return "own-ship-suspect"
            case .unknown, .nominal:    return "own-ship"
            }
        }

        /// Rebuild the accuracy ring as a geodesic polygon. MapLibre's circle layer takes a radius in
        /// SCREEN PIXELS, which would misrepresent a metre uncertainty at every zoom, so the ring is real
        /// geometry: `ringPoints` samples a circle of `accuracyM` metres around the fix, with the
        /// longitude scaled by cos(latitude) so it stays circular on the ground rather than on the chart.
        private func updateAccuracyRing(_ coord: CLLocationCoordinate2D, accuracyM: Double?,
                                        integrity: GPSIntegrityState, on map: MLNMapView) {
            guard let src = map.style?.source(withIdentifier: "accuracy") as? MLNShapeSource else { return }
            guard let r = accuracyM, r > 0, r.isFinite else { src.shape = nil; return }
            assert(r < 100_000, "an accuracy radius this large is not a fix")
            var pts = Self.ringPoints(around: coord, radiusM: r)
            assert(pts.count == Self.ringSegments + 1, "ring must be closed")
            let poly = MLNPolygonFeature(coordinates: &pts, count: UInt(pts.count))
            poly.attributes = ["color": ChartMapView.Coordinator.integrityTint(integrity)]
            src.shape = poly
        }

        static let ringSegments = 64

        /// A closed circle of `radiusM` on the ground, as lat/lon. Flat-earth scaling is exact enough at
        /// GPS-accuracy radii (tens to hundreds of metres); the cos(lat) term is what keeps it round.
        static func ringPoints(around c: CLLocationCoordinate2D, radiusM: Double) -> [CLLocationCoordinate2D] {
            let dLat = radiusM / 111_320.0
            let dLon = radiusM / (111_320.0 * max(cos(c.latitude * .pi / 180), 0.01))
            var out: [CLLocationCoordinate2D] = []
            out.reserveCapacity(ringSegments + 1)
            for i in 0...ringSegments {                                   // bounded (rule 2)
                let t = Double(i) / Double(ringSegments) * 2 * .pi
                out.append(CLLocationCoordinate2D(latitude: c.latitude + dLat * sin(t),
                                                  longitude: c.longitude + dLon * cos(t)))
            }
            return out
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
            // The signature must see MOVED geometry, not just counts: a re-issued NOTAM keeps its id
            // and often its ring count while the boundary shifts, and a count-only signature left the
            // old shape drawn at the old place. Each ring contributes its first vertex (rounded) as a
            // cheap digest — any real amendment moves it.
            let sig = tfrs.map { t in
                let areas = t.areas.map { a -> String in
                    let p0 = a.ring.first ?? Coord(lat: 0, lon: 0)
                    return String(format: "%d.%d.%d.%.4f.%.4f", a.ring.count,
                                  a.ceilingFt ?? -1, a.floorFt ?? -1, p0.lat, p0.lon)
                }.joined(separator: "+")
                return "\(t.id):\(areas)"
            }.sorted().joined(separator: "|")
            guard sig != appliedTFRSig else { return }                   // unchanged TFR set → skip rebuild
            appliedTFRSig = sig
            let f = Coordinator.tfrFeatures(tfrs)
            (style.source(withIdentifier: "tfr") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.polys)
            (style.source(withIdentifier: "tfr-labels") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: f.labels)
        }

        /// One polygon + one altitude-block point PER AFFECTED AREA (a NOTAM like the DC SFRA defines
        /// several — concatenating them drew a bogus wedge). All of a TFR's polygons carry the same "id"
        /// attribute, so a tap on any area resolves to the one NOTAM. nonisolated; bounded; >=2 assertions.
        static func tfrFeatures(_ tfrs: [TFR]) -> (polys: [MLNPolygonFeature], labels: [MLNPointFeature]) {
            assert(tfrs.count <= 4096, "tfrFeatures: absurd TFR count")
            var polys: [MLNPolygonFeature] = []; var lbls: [MLNPointFeature] = []
            for t in tfrs.prefix(400) {                                  // bounded (TFRMapLayer parity)
                for area in t.areas.prefix(64) where area.ring.count >= 3 {
                    var c = area.ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                    f.attributes = ["id": t.id, "cls": "TFR"]
                    polys.append(f)
                    if let top = area.labelCoord {                       // per-area band on its own north edge
                        let p = MLNPointFeature(); p.coordinate = CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon)
                        p.attributes = ["alt": "\(AirspaceLabelAnnotation.altText(area.ceilingFt))\n\(AirspaceLabelAnnotation.altText(area.floorFt))"]
                        lbls.append(p)
                    }
                }
            }
            assert(polys.count <= 400 * 64, "tfrFeatures: cap exceeded")
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--debug-plate") {
                let ids = style.layers.map(\.identifier).joined(separator: ",")
                let q = Coordinator.plateQuad(s)
                NSLog("CommSight PLATE dbg: layer=%@ img=%@ quadTL=%.4f,%.4f quadBR=%.4f,%.4f center=%.4f,%.4f zoom=%.2f layers=[%@]",
                      inLayer.rawValue, s.displayImage == nil ? "NIL" : "ok",
                      q.topLeft.latitude, q.topLeft.longitude, q.bottomRight.latitude, q.bottomRight.longitude,
                      map.centerCoordinate.latitude, map.centerCoordinate.longitude, map.zoomLevel, ids)
            }
            #endif
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
            // COMPUTE THE CAMERA, DO NOT ASK FOR IT.
            //
            // `setVisibleCoordinateBounds` has to invert the projection to solve a centre and zoom from a
            // box, and on the vertical-perspective globe that solve degenerates when it runs before the
            // projection has settled — measured, with a correct Boston quad in hand it produced
            // `center = -85.05, 27.34  zoom = 22`: the south pole at maximum zoom, with the plate layer
            // present, ordered correctly and holding a good image the whole time. It looked like "the
            // plate goes away" and it showed up in Dark mode because Dark loads no chart packs, so the
            // framing fires earliest there. A centre and a zoom derived directly from the quad need no
            // inverse solve and cannot degenerate.
            let mid = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                             longitude: (minLon + maxLon) / 2)
            let lonSpan = max(maxLon - minLon, 1e-4)
            let latSpan = max(maxLat - minLat, 1e-4)
            // Web-mercator: the world is 360 degrees across 256 points at z0. Fit the WIDER axis, then
            // back off a little for the edge padding the box deserves.
            // MapLibre Native's zoom is defined against a 512-point world (util::tileSize_D), not the
            // 256 of the slippy-map convention — using 256 overstates zoom by exactly 1, which opens
            // every plate at twice the intended scale and crops it. Latitude spans also have to be
            // compared in MERCATOR units, where a degree of longitude is cos(lat) of a degree of
            // latitude; without that the fit is wrong by a factor that grows with latitude (1.4x at
            // 45 degrees) and picks the wrong axis to fit.
            let w = max(Double(map.bounds.width), 1), h = max(Double(map.bounds.height), 1)
            let cosLat = max(cos(mid.latitude * .pi / 180), 0.15)
            let zLon = log2(360.0 / lonSpan * w / 512.0)
            let zLat = log2(360.0 * cosLat / latSpan * h / 512.0)
            let zoom = min(max(min(zLon, zLat) - 0.35, 2), 14)
            guard mid.latitude.isFinite, mid.longitude.isFinite, zoom.isFinite,
                  CLLocationCoordinate2DIsValid(mid) else { return }
            map.setCenter(mid, zoomLevel: zoom, animated: false)
            // CLAIM THE FRAMING. `frameIfNeeded` is a ONE-SHOT that keeps retrying until it finds a target
            // (saved camera, else route, else ownship) — and it was never told the plate had already
            // framed, so whichever ran last won. Loading a plate then framed on the filed ROUTE instead,
            // leaving the plate a few pixels wide somewhere off screen: "the plate goes away". It showed up
            // as a Dark-mode bug only because Dark loads no chart packs, so the generic framing got there
            // second. Framing ON a plate the pilot just opened is the most specific intent there is.
            didFrame = true
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
            // Entering or leaving `.smartDark` changes WHICH features belong on the map (the declutter) and
            // whether the route-waypoint layers draw at all — neither follows from the pack reload above,
            // and a layer switch is user-rate, so rebuilding the overlays here is free.
            guard prev == .smartDark || new == .smartDark else { return }
            refreshOverlays(map)
            applyRouteWptVisibility(on: map)
        }

        /// The route-waypoint layers exist in every mode but draw only on the decluttered night base: on an
        /// FAA raster every fix is already printed on the chart, so a second set of idents would be the
        /// clutter this mode exists to remove. Keeping the layers mounted (populated, just hidden) makes a
        /// future "show route waypoints everywhere" toggle a one-line change.
        private func applyRouteWptVisibility(on map: MLNMapView) {
            guard let style = map.style else { return }
            let show = (layer == .smartDark)
            for id in Self.routeWptLayers {                               // bounded (rule 2)
                style.layer(withIdentifier: id)?.isVisible = show
            }
            assert(Self.routeWptLayers.count == 3, "applyRouteWptVisibility: layer set changed")
        }

        /// Apply the MapLayersMenu overlay toggles; a real change re-runs refreshOverlays so a toggled-off
        /// layer clears (the builders return [] when its `want` is false).
        func applyOverlayToggles(_ air: Bool, _ near: Bool, _ awy: Bool, declutter: Bool,
                                 on map: MLNMapView) {
            showAirspace = air; showNearby = near; showAirways = awy; declutterOn = declutter
            // `declutter` is IN the signature: it changes what refreshOverlays queries, so a flip with
            // every other toggle unchanged must still force a rebuild.
            let sig = "\(air)\(near)\(awy)\(declutter)"
            defer { appliedToggles = sig }
            guard let prev = appliedToggles, prev != sig, map.style != nil else { return }
            refreshOverlays(map)
        }

        /// Recenter on a search-result pick (keeps the current zoom). Only fires when `focus` changes.
        /// Enforce the north-up lock: disable the rotate gesture and snap any residual bearing back to 0.
        /// Idempotent and diffed on the map's own state, so it costs nothing on the normal per-frame apply.
        private func applyNorthLock(_ map: MLNMapView) {
            assert(Thread.isMainThread, "applyNorthLock off the main thread")
            if map.isRotateEnabled == northLocked { map.isRotateEnabled = !northLocked }
            // Snap back only when locked AND actually off north (a 0.5° deadband keeps an in-flight
            // animation from fighting this every frame).
            if northLocked, abs(map.direction) > 0.5 { map.setDirection(0, animated: true) }
        }

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
            let ranked = MapProbe.rank(cands, within: Double(radius))
            var liveTFRs: [IdentifiedObject] = []
            for t in tfrByID.values where t.hasGeometry {                  // inside ANY affected area (any zoom)
                guard t.contains(here) else { continue }
                liveTFRs.append(IdentifiedObject(kind: .tfr, ident: t.id, coord: t.labelCoord ?? here,
                                                 onRoute: false, tfr: t))
            }
            let aspObjs = airspaces.map {
                IdentifiedObject(kind: .airspace, ident: $0.name, coord: here, onRoute: false, airspace: $0)
            }
            // One ordering policy, shared with the classic engine and unit-tested — see MapProbe.merge.
            var results = MapProbe.merge(ranked: ranked, liveTFRs: liveTFRs, airspaces: aspObjs)
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
                              routeLegs: legs,
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

/// A static night-sky backdrop for the globe: a near-black field scattered with faint stars, floated BEHIND the
/// (non-opaque) MLNMapView so "space" outside the sphere reads as a night sky instead of the ocean colour. Star
/// positions are generated once in unit space (resize is a free rescale) and drawn stably across redraws.
final class StarfieldView: UIView {
    private var space = UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)  // deep night-sky navy
    private var starColor = UIColor.white
    private var alphaScale: CGFloat = 1
    private let stars: [(pos: CGPoint, r: CGFloat, a: CGFloat)]

    /// Retint for the active theme (night dims + red-shifts the stars). One redraw per theme change.
    func apply(space: UIColor, starColor: UIColor, alphaScale: CGFloat) {
        assert(alphaScale > 0 && alphaScale <= 1, "starfield alpha scale out of range")
        self.space = space; self.starColor = starColor; self.alphaScale = alphaScale
        backgroundColor = space
        setNeedsDisplay()
    }

    override init(frame: CGRect) {
        var rng = SystemRandomNumberGenerator()
        var s: [(CGPoint, CGFloat, CGFloat)] = []
        for i in 0..<420 {                                  // bounded star count
            // A few big bright stars, many small faint ones — a real night-sky spread. Radii are in POINTS.
            let big = i % 12 == 0
            s.append((CGPoint(x: .random(in: 0...1, using: &rng), y: .random(in: 0...1, using: &rng)),
                      big ? .random(in: 1.6...2.8, using: &rng) : .random(in: 0.6...1.6, using: &rng),
                      big ? .random(in: 0.8...1.0, using: &rng) : .random(in: 0.35...0.9, using: &rng)))
        }
        stars = s
        super.init(frame: frame)
        backgroundColor = space
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(space.cgColor); ctx.fill(rect)
        for star in stars {                                  // bounded (rule 2)
            let c = CGPoint(x: star.pos.x * rect.width, y: star.pos.y * rect.height)
            let a = star.a * alphaScale
            if star.r > 1.5 {                                // soft glow on the bright stars → night-sky sparkle
                ctx.setShadow(offset: .zero, blur: star.r * 2.6,
                              color: starColor.withAlphaComponent(min(1, a) * 0.85).cgColor)
            } else {
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
            }
            ctx.setFillColor(starColor.withAlphaComponent(a).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - star.r, y: c.y - star.r, width: star.r * 2, height: star.r * 2))
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
#endif
