import SwiftUI
import MapKit

/// The always-present home-screen map background. Lifts the map-owning half of `RouteMapSheet`: it draws
/// the filed route + FAA/Apple base layer + airspace/nearby/traffic via `ChartMapView`, resolves the
/// route with `RouteResolver`, and routes taps to `widgets.mapProbe` (which drives the object side panel /
/// sheet — a sibling in `ConsoleView`'s ZStack). Layer + overlay choices come from persisted `AppModel`
/// state so the top-bar layers menu and this map stay in sync.
///
/// Battery: the live map renders only when enabled + foregrounded + not hidden behind the full-screen
/// route map. It is NEVER torn down for thermal reasons — losing the whole moving map is a dangerous
/// failure mode in the cockpit. Heat is shed gracefully instead (the terrain flattens under
/// `thermalSerious`, and the network map layers pause) while the map itself stays up.
struct MapHostView: View {
    @EnvironmentObject var model: AppModel
    /// Plain reference (NOT observed): the map only WRITES the tapped-object probe here — it must not
    /// re-render / re-reconcile just because a widget's layout changed.
    let widgets: WidgetStore
    /// MEASURED height of the console's opaque top chrome (`ConsoleView.topChromeHeight`). The map is
    /// full-bleed UNDER that chrome, so every control this view floats over the map must start below it.
    /// Defaulted so the memberwise init keeps working for existing call sites.
    var topChrome: CGFloat = 0
    /// Live METARs — read here only to publish each field's flight CATEGORY into the airport-symbol
    /// builder, so a glyph carries the conditions there.
    @EnvironmentObject var metars: MetarStore
    @Environment(\.scenePhase) private var scenePhase

    /// The chrome height to lay out against, floored so the very first frame (before the measurement
    /// lands) still clears the TopBar instead of pinning controls to the screen top.
    private var mapTopInset: CGFloat { max(topChrome, 96) }

    @StateObject private var store = ChartStore(library: ChartLibrary.shared)
    @State private var route: [ResolvedLeg] = []
    /// The overlaid plate's top-corner screen-points (streamed from the map's region callbacks) — the
    /// SwiftUI ✕ / opacity controls are positioned here so they ride the plate itself.
    @State private var plateAnchors: PlateAnchors?
    // Device-GPS ownship, bridged from `model.deviceLocation` (a nested ObservableObject that doesn't
    // republish the parent) so a fix change re-renders the map. Stratux is preferred when connected.
    @State private var deviceCoord: Coord?
    @State private var deviceCourse: Double?
    /// GPS integrity verdict, bridged like deviceCoord. Gates what the map is allowed to DRAW.
    @State private var gpsIntegrity = GPSIntegrityAssessment()

    /// The device position the map may plot: nil when the integrity monitor says the fix can't be
    /// trusted. Suppressing it HERE covers BOTH engines (MapLibre and the MKMapView fallback both take
    /// `ownship:` from this one place) — a position the pilot will fly is worse than no position.
    private var trustedDeviceCoord: Coord? { gpsIntegrity.shouldSuppressOwnship ? nil : deviceCoord }
    /// Ownship for the engines: a FRESH, FIXED Stratux fix still wins (the aircraft's own receiver),
    /// else the device fix if it is trustworthy.
    ///
    /// `trustedStratuxOwnship` (not the raw coordinate) is the gate: a dropped Wi-Fi link leaves the
    /// last Stratux value published forever, and keying on `coordinate != nil` froze the ownship
    /// triangle at a stale position drawn as live while the good, moving device GPS was ignored. When
    /// the Stratux fix goes stale or drops lock, the map now falls through to the device fix rather
    /// than lying about where the aircraft is.
    private var engineOwnship: Coord? { model.trustedStratuxOwnship ?? trustedDeviceCoord }
    /// True only when a Stratux fix is CURRENTLY trustworthy (fixed + fresh). This is what suppresses
    /// the accuracy ring/tint — legitimate while a real Stratux fix is driving ownship, wrong the moment
    /// that fix is stale, because then the device GPS is driving and its integrity verdict DOES apply.
    private var stratuxHasFix: Bool { model.stratuxOwnshipTrusted }
    /// The flight recorder's breadcrumb, bridged from the nested recorder (like deviceCoord). Append-only
    /// during a recording, [] otherwise — the maps guard on its COUNT so it doesn't re-tessellate per tick.
    @State private var breadcrumb: [Coord] = []
    /// The live precipitation-radar tile URL, bridged from RainViewerService — the ONE radar value the map
    /// ENGINES consume. The corner status pill + the loop scrubber observe the service directly (see
    /// `RadarStatusPill` / `RadarLoopBar`), so they don't need per-field @State bridges here.
    @State private var radarTemplate: String?
    /// The decoded winds-aloft column, bridged from WindAloftService — the ONE wind value the map ENGINE
    /// consumes. The altitude slider's chip observes the service directly (see `WindAltitudeSlider`), so
    /// its fetching/age state needs no bridge here.
    @State private var windFields: WindFieldSet?
    /// Screen-point of the search-result highlight (streamed from the active engine, like the plate anchors),
    /// so the SwiftUI pulsing marker rides the map. nil when there's no highlight or it's off-screen-computed.
    @State private var searchPoint: CGPoint?
    /// Show the manual zoom / center-on-aircraft control bar on the map (toggled in the layers menu).
    @AppStorage("atc.map.zoomControls") private var showZoomControls = true

    struct PlateAnchors: Equatable { var tl: CGPoint; var tr: CGPoint }

    /// Chart markers for stations whose weather is going downhill fast. Recomputed when the observation
    /// history changes (not per frame) — placing them needs the nav database, so it's kept off the
    /// render path.
    @State private var wxPins: [WxTrendPin] = []

    /// Publish reported flight categories to the (off-main-actor) symbol builder. Extracted from the
    /// modifier chain: inline, it pushed `body` past the type-checker's budget.
    private func publishCategories(_ m: [String: Metar]) {
        var out: [String: AirportSymbol.Category] = [:]
        for (id, ob) in m.prefix(512) {                                   // bounded (rule 2)
            switch ob.category {
            case .vfr:  out[id] = .vfr
            case .mvfr: out[id] = .mvfr
            case .ifr:  out[id] = .ifr
            case .lifr: out[id] = .lifr
            case .unknown: break
            }
        }
        MapLibreChartView.Coordinator.publish(categories: out)
    }

    /// The region the map is showing at launch, for the FIRST weather fetch — before anything settles.
    ///
    /// This must NOT come from the map's own region callback: that callback is also what persists the
    /// pilot's camera, and publishing at style-load time wrote the pre-framing (continental) view into
    /// `lastMapCamera`. `frameIfNeeded` prefers a FRESH saved camera over the route or the ownship, so the
    /// bogus one won — the map stayed at continental scale and never framed on the plate or the field.
    /// Caught by PlateOverlayUITests: no sectional tiles, and the plate's corner gear never reachable.
    private var launchRegion: MKCoordinateRegion? {
        if let cam = model.lastMapCamera { return cam.region }
        guard let c = model.stratuxGPS?.coordinate ?? deviceCoord else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon),
                                  span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0))
    }

    /// Fetch weather for the fields the pilot is actually LOOKING AT.
    ///
    /// Without this the chart's flight-category rings and the deteriorating-weather markers had no data:
    /// the store only held airports someone had opened a card for, or that sat on the route. Bounded to 40
    /// fields, TTL-deduped inside MetarStore, and skipped when zoomed out past the scale where the airport
    /// symbology draws at all — so panning the chart doesn't turn into a network fire hose.
    private func ensureVisibleWeather(_ rect: MKMapRect) { ensureVisibleWeather(MKCoordinateRegion(rect)) }

    /// Aim the precipitation-radar prefetch at what is ON SCREEN. Called from the same debounced
    /// visible-region settle as the METAR seeding, so panning to look at weather ahead warms THAT
    /// weather's tiles rather than the ones over the aircraft.
    private func aimRadarPrefetch(_ region: MKCoordinateRegion) {
        guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return }
        model.rainViewer.viewportChanged(RadarRegion(centerLat: region.center.latitude,
                                                     centerLon: region.center.longitude,
                                                     latSpan: region.span.latitudeDelta,
                                                     lonSpan: region.span.longitudeDelta))
    }

    /// Tell the wind service what is on screen. It decides whether that needs a download — a pan inside the
    /// covered box is free, so this can fire on every settle.
    private func aimWindFetch(_ region: MKCoordinateRegion) {
        guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return }
        model.windAloft.viewportChanged(RadarRegion(centerLat: region.center.latitude,
                                                    centerLon: region.center.longitude,
                                                    latSpan: region.span.latitudeDelta,
                                                    lonSpan: region.span.longitudeDelta))
    }

    private func ensureVisibleWeather(_ region: MKCoordinateRegion) {
        let latD = region.span.latitudeDelta, lonD = region.span.longitudeDelta
        guard latD > 0, lonD > 0, latD < 5.5 else { return }        // matches the nav layer's own zoom gate
        let c = region.center
        let bb = BBox(minLat: c.latitude - latD / 2, minLon: c.longitude - lonD / 2,
                      maxLat: c.latitude + latD / 2, maxLon: c.longitude + lonD / 2)
        let store = metars
        Task.detached(priority: .utility) {
            let idents = NavDatabase.nearby(bb, types: [0], limit: 40).map(\.ident)
            guard !idents.isEmpty else { return }
            await MainActor.run { store.ensure(idents) }
        }
    }

    /// Recompute the deteriorating-weather chart markers. Extracted from the modifier chain for the same
    /// type-checker reason as `publishCategories`.
    private func refreshWxPins() {
        let pins = WxTrendPin.pins(from: metars.deterioratingStations)
        if pins != wxPins { wxPins = pins }
    }

    /// Show the live map unless it's genuinely pointless: only paused when truly backgrounded (a transient
    /// `.inactive`, e.g. a permission alert, must NOT blank it) or when the full-screen route map is
    /// covering it (no point running two MKMapViews at once). NOT gated on thermal — the map must never
    /// disappear on the pilot; heat is handled by flattening terrain + pausing network layers instead.
    ///
    /// The map is NEVER blanked by the "Live map background" toggle. With the toggle off (the battery
    /// default) an FAA raster simply REPLACES the Apple base within its coverage (MBTilesTileOverlay:
    /// canReplaceMapContent + a `reader.bounds` boundingMapRect so the fringe never goes blank); an
    /// Apple-only layer (Map/Satellite) has no raster and just renders the base. Either way the pilot
    /// always has a moving map — the toggle only chooses whether the Apple base draws UNDER the chart.
    private var live: Bool {
        // Render the map ONLY when it's the front tab. It's kept MOUNTED behind the ZStack, but a live
        // MKMapView / MapLibre map burns CPU/GPU even at opacity 0 behind another tab (the real-flight
        // battery data showed ~0.6 core still spent on the transcript tab). GPS + the flight recorder run
        // independently (started once in onAppear, read directly), so pausing the render doesn't stop them;
        // the camera restores from lastMapCamera on return. Still never gated on THERMAL — heat is handled
        // by flattening terrain, not by blanking the map on the pilot.
        scenePhase != .background && !model.showRouteMap && model.selectedTab == .map
    }

    var body: some View {
        Group {
            if live {
                mapContent
            } else {
                // Not live only when backgrounded or the full-screen route map is covering us — both
                // transient, nothing to show. (The map is never intentionally blanked anymore.)
                model.palette.bg
            }
        }
        .ignoresSafeArea()
        // Own GPS session for the map's ownship marker (replaces MKMapView's built-in showsUserLocation
        // GPS). Bridged into @State so a fix change re-renders → updateUIView moves the marker. GPS is
        // paused in the background by AppModel.handleScenePhase (battery).
        .onAppear {
            model.deviceLocation.start()
            // A restored camera moves nothing, so no region settle fires — seed the first fetch here.
            if let region = launchRegion { ensureVisibleWeather(region); aimWindFetch(region) }
        }
        .onReceive(model.deviceLocation.$coord) { c in
            let hadFix = deviceCoord != nil
            deviceCoord = c
            if !hadFix, c != nil, model.lastMapCamera == nil, let region = launchRegion {
                ensureVisibleWeather(region)        // first fix on a fresh install: fetch around it
                aimWindFetch(region)
            }
            if let c { model.rainViewer.prefetchCenter = (c.lat, c.lon) }   // aim the radar-loop prefetch nearby
        }
        .onReceive(model.deviceLocation.$courseDeg) { deviceCourse = $0 }
        .onReceive(model.deviceLocation.$integrity) { gpsIntegrity = $0 }
        .onReceive(model.flightRecorder.$trail) { breadcrumb = $0.map { Coord(lat: $0.lat, lon: $0.lon) } }
        .onReceive(model.rainViewer.$tileTemplate) { radarTemplate = $0 }   // feed the map engines the current frame
        .onReceive(model.windAloft.$fieldSet) { windFields = $0 }           // and the wind particles their grid
        // Publish reported flight categories to the symbol builder, so an airport's glyph carries the
        // conditions there. The builders run off the main actor and can't read the store directly.
        .onReceive(metars.$metars) { publishCategories($0) }
        // Where the weather is GOING: stations deteriorating past the significant rates get a chart marker.
        .onReceive(metars.$history) { _ in refreshWxPins() }
        // The plate's ✕ / opacity controls ride the PLATE's own top corners (screen-points streamed
        // from the map's region callbacks). SwiftUI-layered — not annotation subviews — so their
        // gestures never fight MapKit's pan recognizer (which cancels UIControl tracking inside
        // annotation views and made a UISlider there feel dead).
        // A single gear button rides the plate's top-right corner; tapping it opens the plate menu (in
        // ConsoleView, dropping from the top). SwiftUI-layered over the map so its tap never fights
        // MapKit's pan recognizer; hidden while the menu is open (the menu carries the controls).
        .overlay {
            // CLAMP the gear into the viewport: it's the ONLY way to reach the plate menu (dim / invert /
            // hide / remove), so if the plate's top-right corner pans or zooms off-screen the gear must
            // still be tappable — it pins to the nearest edge instead of vanishing. Gated on `live` so it
            // isn't stranded over a blank background at stale anchor coords when the map is off.
            if live, let s = model.plateOverlay, let a = plateAnchors, !model.showPlateMenu {
                GeometryReader { geo in
                    // Pin the gear to the plate's top-right corner and track it 1:1 as the plate pans and
                    // zooms — but keep the WHOLE hit box inside the map's usable band. The top of that
                    // band is MEASURED (the chrome is TopBar plus up to five strips, so every constant is
                    // wrong in some state); the bottom stays a constant because the measured tab-bar top
                    // is 73.5pt, so 96/150 already over-clears and errs safe.
                    let bottomChrome = model.showGPSBar ? 150.0 : 96.0        // GPS bar (when shown) + tab bar
                    // BOTH top corners: the gear tucks along the plate's own axes (approach plates are
                    // rotated to the runway heading) and scales its inset with the plate's screen size.
                    let c = PlateGearGeometry.center(topLeft: a.tl, topRight: a.tr, viewport: geo.size,
                                                     topInset: mapTopInset, bottomInset: bottomChrome)
                    PlateCornerSettingsButton(opacity: s.opacity)
                        .environmentObject(model)
                        .position(x: c.x, y: c.y)
                }
            }
        }
        // The pulsing search-result highlight: rides the map at the streamed screen point, drawn regardless
        // of which layers are on. Not hit-testable so it never eats a map tap.
        .overlay {
            if live, let hl = model.searchHighlight, let pt = searchPoint {
                SearchHighlightMarker(kind: hl.kind, theme: model.theme).position(x: pt.x, y: pt.y).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { statusPills }
        .overlay(alignment: .topTrailing) {
            if live {
                RadarStatusPill(rainViewer: model.rainViewer, widgets: widgets,
                                show: model.showWxRadar, thermalWarm: model.thermalSerious, palette: model.palette,
                                topInset: mapTopInset)
            }
        }
        .overlay(alignment: .bottom) {
            if live {
                RadarLoopBar(rainViewer: model.rainViewer, widgets: widgets,
                             show: model.showWxRadar, palette: model.palette)
            }
        }
        .overlay(alignment: .trailing) { if live, showZoomControls { mapSideControls } }
        // NOTE: the NRST button and the winds-aloft altitude slider used to hang here too. They now
        // render in `MapChrome`, which ConsoleView layers ABOVE the floating-widget canvas — see that
        // type for why. Everything still here is either decorative, self-relocating (the plate gear),
        // or has a second route in (pinch/double-tap for zoom), so being covered by a card the pilot
        // themselves placed is a tolerable outcome for it.
        .task { await buildRoute() }
        .onChange(of: model.flightPlan) { _, _ in Task { await buildRoute() } }      // edits redraw the route
        .onChange(of: model.chartLayer) { _, new in
            Task { await store.setLayer(new, routeRects: ChartGeo.routeRects(route)) }
        }
    }

    /// The map engine: MapLibre (GPU chart, the default) or the classic MKMapView chart. Both slot into the
    /// same chrome — every top-bar/menu/widget interaction reaches the map only via `model` + `widgets.mapProbe`.
    @ViewBuilder private var mapContent: some View {
        #if canImport(MapLibre)
        // This MUST stay an if/else and must never become a ZStack or an opacity/hidden trick. ViewBuilder
        // lowers it to _ConditionalContent, so the untaken branch is never evaluated — which is the whole
        // reason the classic engine costs exactly zero while the globe is up: no MKMapView, no Coordinator,
        // no CLLocationManager, no renderer. Layering the two would quietly resurrect all of it.
        //
        // `.id`: flipping the hidden Developer Globe toggle remounts the map so writeStyle re-runs with or
        // without the projection:globe key (it is read once at style install in createMap). The remount
        // token joins it so a render stall can rebuild the coordinator without leaving MapLibre.
        // The identifiers name WHICH engine is live. Several features are engine-specific (the wind particle
        // layer is a sibling view of the MLNMapView and cannot exist on the classic map), so a UI test that
        // finds a control missing needs to be able to say whether that is correct or a regression.
        if model.useMapLibreMap && !model.mapLibreRenderFailed {
            mapLibreMap.id("\(model.useGlobeProjection)-\(model.mapLibreRemountToken)")
                .accessibilityIdentifier("map-engine-maplibre")
        } else {
            chartMapView.accessibilityIdentifier("map-engine-classic")
        }
        #else
        chartMapView
        #endif
    }

    private var chartMapView: some View {
        ChartMapView(layer: model.chartLayer, readers: store.readers, route: route,
                     procedure: model.previewedProcedureLegs,   // resolved once off-main in AppModel (L8)
                     breadcrumb: breadcrumb,                     // flight-recorder trail
                     radarTemplate: radarTemplate,               // live precipitation radar
                     showAirspace: model.showAirspace, showNearby: model.showNearby,
                     showAirways: model.showAirways,
                     initialCenter: model.stratuxGPS?.coordinate ?? deviceCoord,
                     ownship: engineOwnship,
                     ownshipCourse: model.stratuxGPS?.coordinate == nil ? deviceCourse : nil,
                     ownshipAccuracyM: stratuxHasFix ? nil : gpsIntegrity.horizontalAccuracyM,
                     ownshipIntegrity: stratuxHasFix ? .unknown : gpsIntegrity.state,
                     onVisibleRegion: { rect in
                         // Remember where the user settled so a thermal rebuild restores it (M7);
                         // the settle hook is already debounced (0.4 s) in the coordinator.
                         model.lastMapCamera = SavedMapCamera(rect: rect, now: Date())
                         model.recenterADSBForMap()   // GPS-less: poll traffic around what's on screen
                         ensureVisibleWeather(rect)
                         aimRadarPrefetch(MKCoordinateRegion(rect))   // warm the radar the pilot is looking at
                aimWindFetch(MKCoordinateRegion(rect))       // and fetch winds covering it, if the box moved off
                         Task { await store.ensureVisible(rect, layer: model.chartLayer) }
                     },
                     onTapObjects: { objs in
                         guard !objs.isEmpty else { return }
                         Haptics.impact(.light)
                         widgets.mapProbe = MapProbeResult(id: UUID().uuidString, objects: objs)
                     },
                     focus: model.mapFocus,
                     restoreCamera: model.lastMapCamera,
                     plateOverlay: model.plateOverlay,
                     onPlateAnchors: { pts in
                         let mapped = pts.map { PlateAnchors(tl: $0.0, tr: $0.1) }
                         Task { @MainActor in
                             if plateAnchors != mapped { plateAnchors = mapped }
                         }
                     },
                     searchHighlight: model.searchHighlight.map {
                         CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon)
                     },
                     onSearchPoint: { p in Task { @MainActor in if searchPoint != p { searchPoint = p } } },
                     model: model)
    }

    #if canImport(MapLibre)
    /// The MapLibre GPU map fed from the SAME MapHostView state as ChartMapView. Taps route to
    /// `widgets.mapProbe` (NOT a private sheet), so the existing object-card / side-panel flow keeps working.
    /// The single-GPS-owner ownship invariant is preserved: this reuses the shared deviceCoord/deviceCourse
    /// (started + bridged once in body's onAppear/onReceive), and MapLibre draws its own ownship (no
    /// MLNMapView user-location dot / second CLLocationManager).
    private var mapLibreMap: some View {
        MapLibreChartView(
            store: store,
            layer: model.chartLayer,
            routeCoords: route.map { CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon) },
            breadcrumbCoords: breadcrumb.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            radarTemplate: radarTemplate,
            // Only the holds actually being FLOWN reach the map — a skipped course reversal is not
            // drawn, so the chart shows what the pilot is doing rather than everything published.
            holds: model.activeApproach?.activeHolds ?? [],
            ownship: engineOwnship.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            },
            ownshipCourse: model.stratuxGPS?.coordinate == nil ? deviceCourse : nil,
            ownshipAccuracyM: stratuxHasFix ? nil : gpsIntegrity.horizontalAccuracyM,
            ownshipIntegrity: stratuxHasFix ? .unknown : gpsIntegrity.state,
            traffic: model.aircraft,
            wxTrend: wxPins,
            tfrs: model.tfrs,
            showTFRs: model.showTFRs,
            showAirspace: model.showAirspace,
            showNearby: model.showNearby,
            showAirways: model.showAirways,
            declutter: model.declutter,
            northLocked: model.northLocked,
            plateOverlay: model.plateOverlay,
            routeIdents: Set(route.map { $0.ident }),
            routeLegs: route,                       // idents + crossing restrictions for the dark base
            initialCenter: model.stratuxGPS?.coordinate ?? deviceCoord,
            focus: model.mapFocus,
            restoreCamera: model.lastMapCamera,
            onTapObjects: { objs in
                guard !objs.isEmpty else { return }
                Haptics.impact(.light)
                widgets.mapProbe = MapProbeResult(id: UUID().uuidString, objects: objs)
            },
            onPlateAnchors: { pts in
                let mapped = pts.map { PlateAnchors(tl: $0.0, tr: $0.1) }
                Task { @MainActor in
                    if plateAnchors != mapped { plateAnchors = mapped }
                }
            },
            searchHighlight: model.searchHighlight.map {
                CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon)
            },
            onSearchPoint: { p in Task { @MainActor in if searchPoint != p { searchPoint = p } } },
            mapCommand: model.mapCommand,
            onRenderStalled: {
                // The MapLibre map produced no frames (MLNMapView blank-until-scene-refresh). Remount it
                // first — the stall is usually transient — and only fall back to the classic map once the
                // retry budget is spent, so the pilot always ends up with a working chart.
                Task { @MainActor in model.handleMapRenderStall() }
            },
            onVisibleRegion: { rect in
                // Persist the pilot's pan/zoom so a background→foreground remount restores it, and so the
                // classic-map fallback lands on the same view (M7 camera contract — parity with ChartMapView).
                model.lastMapCamera = SavedMapCamera(rect: rect, now: Date())
                model.recenterADSBForMap()   // GPS-less: poll traffic around what's on screen
                ensureVisibleWeather(rect)   // conditions for the fields on screen → category rings + trend markers
                aimRadarPrefetch(MKCoordinateRegion(rect))   // warm the radar the pilot is looking at
                // …and the winds. This line was on the CLASSIC engine's identical callback but not here —
                // on the shipping engine the wind service therefore only ever learned the viewport twice,
                // at onAppear and at the first fix on a fresh install. `needsFetch` keys on "does the held
                // box still contain the VISIBLE box", and the visible box is exactly what this supplies, so
                // without it the 900 s heartbeat re-downloaded the launch area forever: fly a few hundred
                // miles and the wind layer silently runs out of grid under you while the chip goes on
                // reporting a fresh model run.
                aimWindFetch(MKCoordinateRegion(rect))
            },
            renderMeter: model.renderMeter,   // battery diagnostics: per-frame counter → map fps
            globeProjection: model.useGlobeProjection,   // DEV harness: flat vs globe (inert on stock 6.27.0)
            theme: model.theme,               // live palette re-apply — never a remount
            chartBrightness: model.chartBrightness,   // pilot's raster-brightness slider (layers panel)
            windFields: windFields,           // decoded GFS column (nil until the first fetch lands)
            windLevel: model.windLevelIndex,  // the altitude slider's detent
            windPalette: model.windPalette,   // pilot's sprite-colour choice (contrast)
            // The particle layer is paused unless all of this holds. `live` already covers the tab/route-map/
            // background cases by unmounting the whole engine, so only the toggle and thermal state remain.
            windEnabled: model.showWindAloft && !model.thermalSerious)
    }
    #endif

    /// The stacked map-status pills (chart / traffic / radar), so a slow or absent feed reads as an
    /// ACTIONABLE state instead of a silent blank — "no planes drawn" must be distinguishable between
    /// "still loading", "feed down", and "genuinely no aircraft nearby" (the pilot's explicit ask).
    @ViewBuilder private var statusPills: some View {
        if live {
            VStack(spacing: 6) {
                chartStatusPill
                trafficStatusPill
            }
            // MEASURED chrome, not a guess: with the input strip expanded the chrome is ~280pt, so the
            // old constant 150 buried these pills behind the bars in exactly the states where a "chart
            // feed down" warning matters most.
            .padding(.top, mapTopInset)
        }
    }

    /// Chart download state — engine-agnostic (`store.phase` is set by ChartStore for both engines).
    @ViewBuilder private var chartStatusPill: some View {
        switch store.phase {
        case .loadingCatalog: statusPill("Loading chart index…", "arrow.down.circle", spin: true)
        case .downloading:    statusPill("Loading charts for this area…", "arrow.down.circle", spin: true)
        case .zoomOut where model.chartLayer.isRaster:
            statusPill("Zoom in to load the chart here", "plus.magnifyingglass")
        case .empty where model.chartLayer.isRaster:
            statusPill(route.isEmpty ? "Pan and zoom in to load charts" : "No \(model.chartLayer.title) charts here", "map")
        case .failed:
            statusPill("Chart download failed — tap to retry", "wifi.exclamationmark")
                .onTapGesture { Task { await store.setLayer(model.chartLayer, routeRects: ChartGeo.routeRects(route)) } }
        default: EmptyView()
        }
    }

    /// Online ADS-B traffic state. Hidden while the Stratux link provides traffic (its own widget shows
    /// status) and once aircraft are actually drawn (the planes are their own evidence). Every branch —
    /// including "the poller is not running" — comes from `model.trafficFeed`, so the pill can no longer
    /// spin "Loading…" over a feed that is paused or idle.
    @ViewBuilder private var trafficStatusPill: some View {
        if let text = model.trafficFeed.pillText {
            statusPill(text, model.trafficFeed.pillIcon, spin: model.trafficFeed.pillSpins)
        }
    }

    /// The map's manual camera controls — zoom in (+), zoom out (−), and center-on-aircraft — stacked flush
    /// to the right wall, biased into the lower half (clear of the top-corner Stratux card, the bottom-corner
    /// widgets, and the bottom bars). The bar background is semi-transparent (thin material) while the +/− and
    /// aircraft glyphs stay fully opaque, per the brief. Also a stable tap target for iOS-simulator UI tests.
    private var mapSideControls: some View {
        VStack(spacing: 0) {
            sideButton("plus", id: "map-zoom-in", label: "Zoom in") { model.sendMapCommand(.zoomIn) }
            Divider().frame(width: 28).overlay(model.palette.border)
            sideButton("minus", id: "map-zoom-out", label: "Zoom out") { model.sendMapCommand(.zoomOut) }
            Divider().frame(width: 28).overlay(model.palette.border)
            // North lock. LOCKED (the default) pins the chart north-up and disables the two-finger rotate
            // gesture outright, so the orientation can't be nudged in turbulence; unlocked restores free
            // rotation of the globe. Tinted when locked — the one control here with an on/off state.
            sideButton(model.northLocked ? "location.north.fill" : "location.north",
                       id: "map-north-lock",
                       label: model.northLocked ? "Chart locked north-up — tap to allow rotation"
                                                : "Chart rotation unlocked — tap to lock north-up",
                       active: model.northLocked) {
                model.northLocked.toggle()
            }
            Divider().frame(width: 28).overlay(model.palette.border)
            sideButton("scope", id: "map-center-ownship", label: "Center on aircraft") { model.sendMapCommand(.centerOwnship) }
        }
        .background(model.palette.overlay, in: RoundedRectangle(cornerRadius: DS.Radius.r4))   // flat translucent bar
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(model.palette.border, lineWidth: DS.Stroke.control))
        .padding(.trailing, 12)
        .offset(y: 80)                                    // bias below center → lower-right, clear of the corners
    }

    /// `active` tints the glyph for a control that has an ON state (the north lock); the plain
    /// zoom/center buttons are momentary and leave it false.
    private func sideButton(_ icon: String, id: String, label: String, active: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(active ? model.palette.accent : model.palette.text)  // OPAQUE over the bar
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    private func statusPill(_ text: String, _ icon: String, spin: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spin { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
            Text(text).font(.dsLabel)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(model.palette.overlay, in: Capsule())
        .overlay(Capsule().stroke(model.palette.border, lineWidth: DS.Stroke.hairline))
        .foregroundStyle(model.palette.text)
    }

    private func buildRoute() async {
        // Warm the nav tables off-main so the map's first paint never blocks on a decode — NavMeta too,
        // now that the FAA nav-symbol glyph picks the VOR/VORTAC/NDB shape from NavMeta.navaid(ident).
        await Task.detached(priority: .userInitiated) {
            _ = NavDatabase.count; _ = NavDatabase.airspaceCount; _ = NavMeta.navaidCount
        }.value
        // Draw the full path INCLUDING any loaded SID / STAR / approach (their coded legs), not just the
        // filed departure→enroute→destination — see `ProcedureRoute`.
        route = model.flightPlan.map { ProcedureRoute.resolve($0) } ?? []
        await store.setLayer(model.chartLayer, routeRects: ChartGeo.routeRects(route))
    }
}

/// A highlighted, gently PULSING marker for the current map-search result — shown at the searched
/// airport/navaid/fix even when its normal layer is off, so "I searched for it but don't see it" can't
/// happen. Engine-agnostic (positioned by MapHostView from a streamed screen point). Non-interactive.
struct SearchHighlightMarker: View {
    let kind: MapObjectKind
    var theme: AppTheme = .cockpit
    @State private var pulse = false

    var body: some View {
        let color = Self.color(kind, theme)
        ZStack {
            // Expanding ring that fades out — the "pulse".
            Circle().stroke(color, lineWidth: 2.5)
                .frame(width: 30, height: 30)
                .scaleEffect(pulse ? 2.1 : 1.0)
                .opacity(pulse ? 0 : 0.9)
            // Soft halo + the crisp icon disc (mirrors the search sheet's badge).
            Circle().fill(color.opacity(0.22)).frame(width: 40, height: 40)
            ZStack {
                Circle().fill(color).frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Image(systemName: Self.icon(kind)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    static func color(_ kind: MapObjectKind, _ theme: AppTheme) -> Color {
        switch kind {
        case .airport, .vor, .fix: return EntityTint.color(kind, theme)
        default: return theme == .night ? .hex(0xF5B04E) : .hex(0xF59E0B)
        }
    }
    static func icon(_ kind: MapObjectKind) -> String {
        switch kind {
        case .airport: return "airplane"
        case .vor:     return "hexagon"
        case .fix:     return "triangle"
        default:       return "mappin"
        }
    }
}

/// The weather-radar STATUS chip, pinned to the map's top-trailing CORNER (out of the way of the
/// center-top chart/traffic pills). Shows a buffering %, or the loading / unavailable / paused-when-warm
/// states — and hides once the radar is live + buffered (the loop bar is then the persistent indicator).
/// Shifts inward when a widget is docked as a right side-pane so it's never hidden behind it.
private struct RadarStatusPill: View {
    @ObservedObject var rainViewer: RainViewerService
    @ObservedObject var widgets: WidgetStore
    let show: Bool
    let thermalWarm: Bool
    let palette: Palette
    /// Measured console-chrome height, passed down from MapHostView. Defaulted so the existing call site
    /// keeps compiling if this pill is ever constructed without it.
    var topInset: CGFloat = 150

    var body: some View {
        Group {
            if show, let content = state {
                HStack(spacing: 8) {
                    if content.spin { ProgressView().controlSize(.small) } else { Image(systemName: content.icon) }
                    Text(content.text).font(.dsLabel)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(palette.overlay, in: Capsule())
                .overlay(Capsule().stroke(palette.border, lineWidth: DS.Stroke.hairline))
                .foregroundStyle(palette.text)
                .padding(.top, topInset)                    // MEASURED top chrome (see MapHostView)
                .padding(.trailing, trailingInset)          // clear a docked right side-pane
                .accessibilityIdentifier("radar-status-pill")
            }
        }
    }

    /// Trailing inset so the chip clears a right-docked widget pane (approx its stored/default width).
    private var trailingInset: CGFloat {
        guard widgets.rightPane != nil else { return 12 }
        return (widgets.rightPaneWidth > 0 ? widgets.rightPaneWidth : 320) + 12
    }

    private var state: (text: String, icon: String, spin: Bool)? {
        if let prog = rainViewer.bufferProgress {           // buffering the loop → a real %
            return ("Radar loop \(Int((prog * 100).rounded()))%", "cloud.rain", true)
        }
        if rainViewer.tileTemplate == nil {
            if thermalWarm { return ("Radar paused (device warm)", "thermometer.high", false) }
            if rainViewer.failed { return ("Radar unavailable — retrying", "wifi.exclamationmark", false) }
            return ("Loading radar…", "cloud.rain", true)
        }
        return nil                                          // live + buffered → the loop bar is the indicator
    }
}

/// The weather-radar LOOP scrubber — play/pause, a time-scale slider to jump between frames
/// (past → now → forecast), and the selected frame's time. Insets horizontally to clear docked
/// side-panes, and sits FLUSH on the bottom chrome: directly on the GPS bar when it is shown, else on
/// the tab bar, with the data-currency banner (when it appears) counted too.
private struct RadarLoopBar: View {
    @ObservedObject var rainViewer: RainViewerService
    @ObservedObject var widgets: WidgetStore
    let show: Bool
    let palette: Palette


    var body: some View {
        Group {
            if show, rainViewer.canAnimate {
                let count = rainViewer.frames.count
                let idx = Binding<Double>(
                    get: { Double(min(rainViewer.currentIndex, max(count - 1, 0))) },
                    set: { rainViewer.scrub(to: Int($0.rounded())) })
                HStack(spacing: 12) {
                    Button {
                        Haptics.impact(.light); rainViewer.toggleAnimation()
                    } label: {
                        Image(systemName: rainViewer.animating ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("radar-loop-play")

                    VStack(spacing: 1) {
                        Slider(value: idx, in: 0...Double(max(count - 1, 1)), step: 1)
                            .tint(palette.accent)
                            .accessibilityIdentifier("radar-loop-slider")
                        HStack {
                            Text("past").font(.system(size: 9)).foregroundStyle(palette.textDim)
                            Spacer()
                            Text(rainViewer.frameLabel.isEmpty ? "now" : rainViewer.frameLabel)
                                .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(palette.text)
                            Spacer()
                            Text("forecast").font(.system(size: 9)).foregroundStyle(palette.textDim)
                        }
                    }
                    // Jump back to the live "now" frame.
                    Button { Haptics.impact(.light); rainViewer.resetToNow() } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("radar-loop-now")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(palette.overlay, in: Capsule())
                .overlay(Capsule().stroke(palette.border, lineWidth: DS.Stroke.hairline))
                .foregroundStyle(palette.text)
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
                .padding(.leading, widgets.leftPane != nil ? paneWidth(widgets.leftPaneWidth) : 0)
                .padding(.trailing, widgets.rightPane != nil ? paneWidth(widgets.rightPaneWidth) : 0)
                .accessibilityIdentifier("radar-loop-bar")
            }
        }
    }

    private func paneWidth(_ stored: CGFloat) -> CGFloat { stored > 0 ? stored : 320 }
}

// MARK: - Map chrome that must out-rank the floating widgets

/// The two map controls that render ABOVE the floating-widget canvas instead of underneath it.
///
/// `ConsoleView`'s ZStack is `MapHostView` → `topChrome + homeArea`, and `homeArea` is where the pilot's
/// floating cards live — so every control `MapHostView` overlays on the map sits UNDER any card that
/// happens to be there. For most of that chrome that is fine: the plate gear relocates itself out of
/// occupied bands, the status pills are read-only, and zoom has pinch and double-tap as second routes.
/// These two have no second route, and both were measurably unreachable:
///
///   * **NRST** is the only way into the engine-out list at regular width, and the tapped-object card
///     shares its side of the screen (`.trailing`, 340x440) — so tapping any airport on the map buried
///     the emergency control behind the card that tap produced.
///   * **The winds-aloft altitude slider** runs 333 pt of detents down from the top of the map, and the
///     DEFAULT Transcript card (`.bottomLeading`, 460 tall) reaches up into the last two of them on an
///     11-inch iPad: measured, the `2.5k` tick centre sits at y≈571 pt and the card's top edge at
///     y≈569. Both bottom levels were invisible AND their taps went to the card. It clears on a 13-inch
///     screen, which is exactly why the feature's own UI test passed on that sim and failed on the
///     smaller one — the defect was in the geometry, not in the control.
///
/// The rule this encodes: a card the pilot placed may cover map DECORATION, but never a fixed control
/// they have no other way to reach. The cost is a 64 pt column on the left and a 46 pt button on the
/// right, and only while those layers are actually on.
///
/// Standby is the caller's gate, not this view's — `homeArea` dims and disables itself and floats the
/// Resume banner over the lot, and chrome drawn above that would stay tappable in a mode whose whole
/// promise is that nothing is running.
struct MapChrome: View {
    @EnvironmentObject var model: AppModel
    /// OBSERVED here, unlike in `MapHostView`. The reason `MapHostView` holds the store as a plain
    /// reference is the several-per-second live-data storm mirrored into `AppModel`; `WidgetStore` is
    /// deliberately isolated from that storm (see its type comment), so a view that observes only the
    /// store re-renders on layout changes alone — which is precisely what this needs.
    @ObservedObject var widgets: WidgetStore
    /// `MapHostView.mapTopInset` — the measured console chrome, floored.
    let topInset: CGFloat
    /// `MapHostView.live`: front tab, foregrounded, not behind the full-screen route map.
    let live: Bool
    @Environment(\.horizontalSizeClass) private var hSize

    /// NOTHING IN THIS LAYER MAY BE DRAWN CONTENT. It sits above the whole console, so any filled view
    /// spanning it — a `Color.clear` spacer, a `Rectangle`, a background — would be hit-testable and would
    /// swallow every tap meant for the map underneath: pan, pinch, tap-to-identify, the top bar. The two
    /// controls are therefore positioned by `.frame(maxWidth:maxHeight:alignment:)`, which is pure layout
    /// and adds no hittable surface, rather than by overlaying a spacer view. An empty `ZStack` (nothing
    /// live) collapses to zero size and cannot intercept anything.
    var body: some View {
        ZStack {
            if live { chrome }
        }
    }

    @ViewBuilder private var chrome: some View {
        if !nrstPanelShowing {
            // FULL-WINDOW centring, deliberately — the same coordinate space `mapSideControls` uses, so
            // the -58 offset keeps its documented meaning ("just above the zoom stack's top edge") and
            // the two cannot drift apart. An earlier attempt to inset this by the measured chrome moved
            // it down by half the chrome height and put it INSIDE the zoom stack, which is a collision
            // that actually happens — where the chrome overlap it was guarding against does not: the
            // chrome tops out around 420 pt with the profile strip up, and this sits near 620.
            nrstButton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        // TOP-leading: high altitude belongs at the top of the screen, and the track then grows downward
        // from measured chrome rather than from a guessed centre.
        //
        // MapLibre-only: the particle layer is a sibling of the MLNMapView, so a slider over the classic
        // fallback engine would be a dead control.
        if model.showWindAloft, model.useMapLibreMap, !model.mapLibreRenderFailed {
            WindAltitudeSlider(windAloft: model.windAloft, widgets: widgets,
                               levelIndex: $model.windLevelIndex, palette: model.palette,
                               topInset: topInset, theme: model.theme,
                               layer: model.chartLayer, windPalette: model.windPalette,
                               thermalWarm: model.thermalSerious)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The valid-time stamp rides the CHART, bottom-centre, not the slider — animated particles
            // look live at any age, so the one fact that stops a pilot trusting an eighteen-hour-old field
            // has to sit with the thing it describes. See `WindDataStamp`.
            WindDataStamp(windAloft: model.windAloft, level: WindLevel.at(index: model.windLevelIndex),
                          palette: model.palette, thermalWarm: model.thermalSerious,
                          lonSpan: model.lastMapCamera?.region.span.longitudeDelta ?? 0)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)          // read-only: never take a tap from the map
        }
    }

    /// The panel is already in front of the pilot — floating or docked — so the button has nothing left
    /// to do and would only sit on top of the thing it opens. Safe to read now that the store is
    /// observed: this recomputes the moment the panel opens or closes.
    /// Trailing inset that clears a docked right pane, the same formula every sibling control uses
    /// (`RadarStatusPill.trailingInset`, `RadarLoopBar`, the wind slider's `leftPaneInset`). The NRST
    /// button was the one piece of map chrome without it, and since MapChrome now renders ABOVE the
    /// widget canvas the button landed ON a docked pane — transcript docked right is a common cockpit
    /// layout — and ate the taps and swipes meant for it. `widgets` is observed here, and both
    /// `rightPane` and `rightPaneWidth` are @Published, so this re-lays out live on dock, undock and
    /// resize.
    private var rightPaneInset: CGFloat {
        guard widgets.rightPane != nil else { return 12 }
        return (widgets.rightPaneWidth > 0 ? widgets.rightPaneWidth : 320) + 12
    }

    private var nrstPanelShowing: Bool {
        hSize != .compact
            && (widgets.isVisible(.nrst) || widgets.leftPane == .nrst || widgets.rightPane == .nrst)
    }

    /// The engine-out NRST button. Text rather than a glyph because NRST is the label every GPS in every
    /// panel has used for decades. Regular width shows the panel (or lifts it, if it is already up or
    /// docked in a pane); compact rides a sheet. The panel closes by its own ✕, never by a second tap
    /// here — SHOW, never toggle, so the outcome of a tap in an emergency is never "it went away".
    private var nrstButton: some View {
        Button {
            Haptics.impact(.medium)
            if hSize == .compact { model.showNRSTSheet = true } else { widgets.reveal(.nrst) }
        } label: {
            Text("NRST")
                .font(.dsLabelSBold)
                .foregroundStyle(model.palette.text)
                .frame(width: 46, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .background(model.palette.overlay, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(model.palette.bad.opacity(0.7), lineWidth: DS.Stroke.control))
        .padding(.trailing, rightPaneInset)
        .offset(y: -58)                                   // just above the zoom stack's top edge
        .accessibilityIdentifier("map-nrst")
        .accessibilityLabel("Nearest airports — engine-out glide ranking")
    }
}
