import SwiftUI

/// The live console — a SwiftUI port of the browser UI (`server/static/*`): brand +
/// status pills, a source/controls bar, the live transcript, and a latency/host
/// sidebar. Adapts to a 2-column layout on iPad (regular width) and a stacked scroll
/// on iPhone (compact).
struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    @EnvironmentObject var widgets: WidgetStore
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase

    /// Strips slide in from under the heading bar and fade — a "drop-down" reveal that pushes the
    /// transcript down (it's maxHeight:.infinity below) rather than covering it. The toggles are
    /// wrapped in `withAnimation` at the tap site, which is what drives these transitions.
    static let barTransition: AnyTransition = .move(edge: .top).combined(with: .opacity)

    var body: some View {
        let p = model.palette
        ZStack {
            // The map is the home screen — always behind everything, with the widgets floating over it.
            MapHostView(widgets: widgets).environmentObject(model)
            VStack(spacing: 0) {
                TopBar()
                // The Input strip (source picker + setup) is the one genuinely bar-shaped control; it stays
                // as a toggleable strip under the top bar. Everything else is now a floating widget.
                if model.showInputBar { InputBar().transition(Self.barTransition) }
                if model.showFlightPlanBar { FlightPlanBar().transition(Self.barTransition) }
                if let proc = model.previewedProcedure { procedureStrip(proc) }
                if let sug = model.efbSuggestion { efbSuggestionBanner(sug) }
                if let hz = model.hazardAlert, !hz.isEmpty { hazardBanner(hz) }
                homeArea
            }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet().environmentObject(model).environmentObject(downloads)
        }
        .sheet(isPresented: $model.showWhatsNew) {
            WhatsNewSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showMicCalibration) {
            MicCalibrationSheet().environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.needsOnboarding) {
            OnboardingDownloadView().environmentObject(model).environmentObject(downloads)
        }
        .fullScreenCover(isPresented: $model.showRouteMap) {
            RouteMapSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showMapSearch) {
            MapSearchSheet(onPick: { model.selectMapObject($0); model.showMapSearch = false }, initialQuery: "")
                .environmentObject(model)
        }
        // On compact width the tapped-object info is a bottom sheet; on regular it's a floating side panel.
        .sheet(item: compactProbe) { result in
            MapObjectSheet(result: result).environmentObject(model)
        }
        .animation(.easeInOut(duration: 0.25), value: model.theme)
        .onAppear {
            // Bridge a finished download back to the model so it can load a model that wasn't
            // present at launch (lean TestFlight build → first-run download → live console).
            downloads.onReady = { entry in
                model.modelDidDownload(entry)
                // The AI context fixer rides along with whichever speech model the user downloads, so
                // correction works regardless of which model they picked. Idempotent, and skipped when
                // the fixer is bundled into the app.
                if entry.kind == .whisperKit, !ModelStore.isReady(ModelCatalog.llm), bundledLLMModelPath() == nil {
                    downloads.download(ModelCatalog.llm)
                }
                // The fixer just landed → rebuild the corrector so a running session starts using it
                // (otherwise it's only picked up on the next model swap / relaunch).
                if entry.id == ModelCatalog.llm.id { model.refreshLLMAfterDownload() }
            }
            // Build 21+: pull the required Small model in the background when a downloaded install lacks
            // it (variant bump left the old Small stale). No-op when Small is bundled (modelSource then
            // reads "bundled") or already present.
            if model.modelSource == "downloaded", !ModelStore.isReady(ModelCatalog.required) {
                downloads.download(ModelCatalog.required)
            }
            // The AI fixer isn't bundled in the speech-model-only build — fetch it on first launch if it
            // isn't present yet, so correction works. The app transcribes without it (vocabulary-only)
            // until it lands, then `refreshLLMAfterDownload` switches it on.
            if !ModelStore.isReady(ModelCatalog.llm), bundledLLMModelPath() == nil {
                downloads.download(ModelCatalog.llm)
            }
            // Warm the FAA chart catalog + prefetch the packs around the device and the filed route in the
            // background, so opening the route map is instant instead of a cold catalog fetch + download.
            model.prefetchChartsOnLaunch()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Backgrounding stops capture + releases audio (no background streaming/drain); ADS-B is
            // paused/cleared; foregrounding resumes what was running.
            model.handleScenePhase(newPhase)
        }
    }

    private var hairline: some View { Rectangle().fill(model.palette.border).frame(height: 1) }

    /// Below the top bar: floating widgets over the map (regular width), or a bottom transcript card with
    /// the map showing above it (compact). The area is transparent, so taps on the open map reach it.
    ///
    /// Standby dims + disables this whole area (the top bar above it stays usable) and floats the Resume
    /// banner over it — on BOTH layouts. The overlay lives here, not on `transcriptArea`, because the
    /// transcript card only exists on the compact path; hanging standby off it meant entering standby on
    /// iPad (regular width) set `model.standby` but showed no Resume screen at all.
    @ViewBuilder private var homeArea: some View {
        Group {
            if hSize == .regular {
                FloatingCanvas(palette: model.palette).environmentObject(model)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    transcriptArea.frame(height: 340).padding(10)
                }
            }
        }
        .opacity(model.standby ? 0.4 : 1)
        .disabled(model.standby)
        .overlay { if model.standby { StandbyBanner().environmentObject(model) } }
        .animation(.easeInOut(duration: 0.2), value: model.standby)
    }

    /// Only surface the tapped-object bottom sheet on compact width; on regular it's a floating side panel.
    private var compactProbe: Binding<MapProbeResult?> {
        Binding(get: { hSize == .compact ? widgets.mapProbe : nil }, set: { widgets.mapProbe = $0 })
    }

    /// A strip shown while a coded procedure is drawn on the map — its name + a clear button.
    private func procedureStrip(_ proc: CIFPProcedure) -> some View {
        let p = model.palette
        return HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(Color(red: 0.16, green: 0.78, blue: 0.94))
            Text("\(proc.airport) · \(proc.name)").font(.caption.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
            Spacer(minLength: 4)
            Button { Haptics.impact(.light); model.previewedProcedure = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(p.textDim)
            }
            .buttonStyle(.plain).accessibilityIdentifier("clear-procedure")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(p.surface)
        .transition(Self.barTransition)
    }

    /// One-tap EFB suggestion parsed from a controller clearance addressed to the pilot's aircraft
    /// (Phase 4, suggest-and-confirm). Accept applies it via the existing mutators; Dismiss clears it.
    /// Nothing changes until a tap.
    private func efbSuggestionBanner(_ sug: EFBSuggestion) -> some View {
        let p = model.palette
        return HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.callout).foregroundStyle(p.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(sug.title).font(.callout.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                Text(sug.source).font(.caption2).foregroundStyle(p.textDim).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { Haptics.impact(.light); model.dismissEFBSuggestion() } label: {
                Text("Dismiss").font(.caption.weight(.semibold)).foregroundStyle(p.textDim)
                    .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("efb-dismiss")
            Button { model.acceptEFBSuggestion() } label: {
                Text("Accept").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.plain).accessibilityIdentifier("efb-accept")
            // One-tap hand-off: accept the amendment AND load the amended route into ForeFlight
            // (offline URL scheme). Only offered when the integration is on and ForeFlight is
            // installed; skipped when accepting turns out not to change the plan.
            if model.offersForeFlight {
                Button { model.acceptEFBSuggestionSendingToForeFlight() } label: {
                    Text("Accept ➔ ForeFlight").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain).accessibilityIdentifier("efb-accept-foreflight")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(p.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(p.accent.opacity(0.5)).frame(height: 1) }
        .transition(Self.barTransition)
        .accessibilityIdentifier("efb-suggestion")
    }

    /// Satellite-observed hazards near the filed route or ownship (NASA EONET). Details opens the
    /// hits in the tap-to-identify flow; X mutes exactly these events until the plan changes. NOT a
    /// NOTAM substitute — the copy says so, and the detail card repeats it.
    private func hazardBanner(_ hz: HazardAlert) -> some View {
        let p = model.palette
        let lead = hz.routeHits.first ?? hz.vicinityHits.first
        let total = hz.routeHits.count + hz.vicinityHits.count
        let headline: String = {
            guard let lead else { return "Hazards nearby" }
            let place = hz.routeHits.isEmpty ? "within \(Int(HazardCorridor.vicinityNm)) nm of you"
                                             : "\(Int(lead.distanceNm.rounded())) nm from route"
            let more = total > 1 ? " (+\(total - 1) more)" : ""
            return "\(lead.category.label) “\(lead.title)” — \(place)\(more)"
        }()
        return HStack(spacing: 10) {
            Image(systemName: lead?.category.glyph ?? "flame.fill")
                .font(.callout)
                .foregroundStyle(Color(uiColor: HazardAnnotation.tint(lead?.category ?? .wildfires)))
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.callout.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                Text("Satellite-observed (NASA EONET) · not an official NOTAM")
                    .font(.caption2).foregroundStyle(p.textDim).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { Haptics.impact(.light); model.showHazardAlertDetails() } label: {
                Text("Details").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.plain).accessibilityIdentifier("hazard-details")
            Button { Haptics.impact(.light); model.dismissHazardAlert() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(p.textDim)
            }
            .buttonStyle(.plain).accessibilityIdentifier("hazard-dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(p.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: HazardAnnotation.tint(lead?.category ?? .wildfires)).opacity(0.5)).frame(height: 1)
        }
        .transition(Self.barTransition)
        .accessibilityIdentifier("hazard-banner")
    }

    /// The live transcript card at the bottom of the compact (iPhone) layout. Standby dimming and the
    /// Resume banner are applied one level up in `homeArea` so they cover the iPad layout too.
    private var transcriptArea: some View {
        TranscriptCard()
    }
}

// MARK: - Heading bar

/// The heading bar is the console's control surface: it toggles the collapsible strips (input,
/// diagnostics, flight plan, Stratux) in and out, picks the screen theme, and holds the single
/// Start/Stop power button. Icons run ~10% larger with ~15% more spacing than before (easier to hit
/// on a bumpy flight deck) and every button gives a light haptic tap. On iPhone the brand collapses
/// to the logo alone so the larger control icons fit one row; the wordmark returns on iPad.
struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize

    // Centralized sizing so the whole bar scales together (the "bigger + roomier" ask).
    private let iconSize: CGFloat = 19        // ~+10% over the old 15–17pt icons
    private let barSpacing: CGFloat = 14      // ~+15% over the old 12pt
    private let hit = CGSize(width: 30, height: 30)

    var body: some View {
        let p = model.palette
        HStack(spacing: 0) {
            brand(p)
            Spacer(minLength: 8)
            HStack(spacing: barSpacing) {
                toggle(p, "slider.horizontal.3", on: model.showInputBar,
                       id: "input-toggle", label: "Input controls") { model.showInputBar.toggle() }
                flightPlanToggle(p)   // briefcase — the ForeFlight-style flight-plan strip
                iconButton(p, "magnifyingglass", id: "map-search", label: "Search") { Haptics.impact(.light); model.showMapSearch = true }
                MapLayersMenu(iconSize: iconSize).foregroundStyle(p.text)   // base map + overlays
                WidgetsMenu(iconSize: iconSize).foregroundStyle(p.text)     // show/hide floating widgets
                ThemeMenu()
                PowerButton()
                iconButton(p, "gearshape.fill", id: "settings-button", label: "Settings") {
                    model.showSettings = true
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(p.surface)
    }

    // MARK: brand

    @ViewBuilder private func brand(_ p: Palette) -> some View {
        HStack(spacing: 10) {
            Image("BrandMark").resizable().scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            // Wordmark + subtitle only where there's room (iPad / regular width). On iPhone the logo
            // stands alone so the larger control icons fit one row.
            if hSize == .regular {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CommSight").font(.headline).foregroundStyle(p.text)
                    Text("On-device ATC transcription").font(.caption2).foregroundStyle(p.textDim)
                }
            }
        }
    }

    // MARK: heading buttons

    /// A strip-toggle icon: tints accent + gets a soft fill while its strip is open, and animates the
    /// strip in/out (the withAnimation here is what drives the drop-down reveal + transcript reflow).
    private func toggle(_ p: Palette, _ symbol: String, on: Bool, id: String, label: String,
                        _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: hit.width, height: hit.height)
                .foregroundStyle(on ? p.accent : p.textDim)
                .background(on ? p.accent.opacity(0.16) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// A plain icon action button (no toggle state) — e.g. Settings.
    private func iconButton(_ p: Palette, _ symbol: String, id: String, label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: hit.width, height: hit.height)
                .foregroundStyle(p.textDim)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    /// Flight-plan strip toggle — lives on the briefcase (per the brief), keeping the stale ⚠ badge.
    private func flightPlanToggle(_ p: Palette) -> some View {
        let on = model.showFlightPlanBar
        return Button {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.22)) { model.showFlightPlanBar.toggle() }
        } label: {
            Image(systemName: "briefcase.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: hit.width, height: hit.height)
                .foregroundStyle(on ? p.accent : p.textDim)
                .background(on ? p.accent.opacity(0.16) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if model.flightPlan?.isStale == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(p.warn)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flight-bag-button")
        .accessibilityLabel("Flight plan")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Stratux strip toggle — the icon itself is tinted by live link health (idle/connecting/
    /// connected/error) so the connection state reads at a glance from the heading bar.
    private func stratuxToggle(_ p: Palette) -> some View {
        let on = model.showStratuxBar
        return Button {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.22)) { model.showStratuxBar.toggle() }
        } label: {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: hit.width, height: hit.height)
                .foregroundStyle(stratuxTint(p))
                .background(on ? p.accent.opacity(0.16) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stratux-toggle")
        .accessibilityLabel("Stratux strip")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Stratux icon colour — live link health when the always-on link is enabled, neutral otherwise.
    private func stratuxTint(_ p: Palette) -> Color {
        guard model.stratuxEnabled else { return model.showStratuxBar ? p.accent : p.textDim }
        switch model.stratuxStatus {
        case .idle:       return p.textDim
        case .connecting: return p.warn
        case .connected:  return p.good
        case .error:      return p.bad
        }
    }
}

// MARK: - Theme menu

/// Screen-colour picker collapsed into a single heading-bar dropdown (was a 3-button inline switcher)
/// — the label is the current theme's glyph; the menu offers all three. Keeps the `theme-*` ids so
/// the theme UI test still drives it (after opening the menu).
struct ThemeMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        Menu {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    Haptics.impact(.light)
                    model.theme = theme
                } label: {
                    Label(theme.label, systemImage: theme.symbol)
                }
                .accessibilityIdentifier("theme-\(theme.rawValue)")
            }
        } label: {
            Image(systemName: model.theme.symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(p.textDim)
        }
        .accessibilityIdentifier("theme-menu")
        .accessibilityLabel("Screen color")
    }
}

// MARK: - Power button (Start / Stop / long-press Standby)

/// The one control that runs the app: tap to Start/Stop capture, touch-and-hold for low-power
/// Standby. Colour-coded by state (accent = ready to start, amber = connecting, red = live/stop) —
/// the same at-a-glance colour idea the old Start/Stop button used. `accessibilityLabel` stays
/// "Start"/"Stop" so the run-toggle UI test keeps working.
struct PowerButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        let running = model.isRunning
        let (bg, symbol): (Color, String) = {
            switch model.status {
            case .connecting, .starting: return (p.warn, "power")
            case .live:                  return (p.bad, "stop.fill")
            default:                     return (p.accent, "play.fill")
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 18, weight: .bold))
            .frame(width: 40, height: 32)
            .background(bg)
            .foregroundStyle(p.bg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture {
                Haptics.impact(.medium)
                running ? model.stop() : model.start()
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                Haptics.impact(.rigid)
                model.enterStandby()
            }
            .accessibilityIdentifier("start-stop-button")
            .accessibilityLabel(running ? "Stop" : "Start")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Touch and hold for standby")
    }
}

// MARK: - Collapsible strips
//
// The old swipeable carousel is gone: its three pages are now independent strips, each toggled by a
// heading-bar icon and rendered directly in the console VStack (see `ConsoleView.body`). Diagnostics
// reuses `StatusBar` verbatim; `FlightPlanBar` and `StratuxBar` are the former carousel pages resized
// to sit as strips; `InputBar` is the source/controls half of the old controls bar.

private extension View {
    /// A 1pt bottom rule so stacked heading-bar strips read as distinct rows.
    func barSeparator(_ p: Palette) -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

// MARK: - Diagnostics strip (pills + badges)

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusPill(label: "Performance check",
                           state: model.proofOfLife == nil ? .idle : (model.proofOfLife?.passed == true ? .good : .bad))
                StatusPill(label: "Stream", state: streamState)
                Badge(text: "device · \(model.deviceLabel)")
                Badge(text: "model · \(model.activeModelLabel)")
                Badge(text: "src · \(model.modelSource)")
                if let s = model.measuredSpeed { Badge(text: String(format: "%.1f× real-time", s)) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(p.bg)
        .barSeparator(p)
        .accessibilityIdentifier("diagnostics-bar")
    }

    private var streamState: StatusPill.State {
        switch model.status {
        case .live: return .good
        case .connecting, .starting: return .pending
        case .error: return .bad
        default: return .idle
        }
    }
}

struct StatusPill: View {
    enum State { case good, warn, bad, idle, pending }
    @EnvironmentObject var model: AppModel
    let label: String
    let state: State

    var body: some View {
        let p = model.palette
        HStack(spacing: 6) {
            Circle().fill(color(p)).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(p.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(p.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(p.border, lineWidth: 1))
    }

    private func color(_ p: Palette) -> Color {
        switch state {
        case .good: return p.good
        case .warn: return p.warn
        case .bad: return p.bad
        case .pending: return p.warn
        case .idle: return p.textDim
        }
    }
}

struct Badge: View {
    @EnvironmentObject var model: AppModel
    let text: String
    var body: some View {
        let p = model.palette
        Text(text)
            .font(.caption2.monospaced()).foregroundStyle(p.textDim)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(p.surfaceAlt)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(p.border, lineWidth: 1))
    }
}

/// Compact live status for the Stratux link: connecting / linked (with GPS fix + sat count + traffic
/// count) / error. Only meaningful while the Stratux source is running; idle otherwise.
struct StratuxStatusChip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        let (text, color): (String, Color) = {
            switch model.stratuxStatus {
            case .idle:        return ("Stratux idle", p.textDim)
            case .connecting:  return ("Linking…", p.warn)
            case .connected:
                let tfc = "\(model.aircraft.count) tfc"
                if let g = model.stratuxGPS, g.hasFix {
                    return ("\(g.fixLabel) · \(g.satellites) sat · \(tfc)", p.good)
                }
                return ("Linked · acquiring GPS · \(tfc)", p.good)
            case .error(let m): return ("Stratux: \(m)", p.bad)
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: "dot.radiowaves.up.forward").font(.caption2)
            Text(text).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
        .accessibilityIdentifier("stratux-status")
    }
}

// MARK: - Flight-plan strip

/// THE flight-plan editor — a ForeFlight-style FPL panel as a collapsible strip (briefcase toggle):
/// aircraft + altitude boxes on the left, the free-form route field with live colour-coded entity
/// chips in the middle (airports purple-pink, VORs green, RNAV/GPS fixes blue, airways amber),
/// actions on the right, and the DIST/ETE/ETA/FUEL/WIND trip overview beneath. Edits commit LIVE
/// (debounced) to `AppModel.flightPlan` — there is no Save button, so Send-to-ForeFlight always
/// sends exactly what's on screen. Replaces the old flight-bag popup editor and flight-plan widget.
struct FlightPlanBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    @Environment(\.horizontalSizeClass) private var hSize

    // Strip-local editing state, reconciled with the model on every plan change — see
    // `reconcileWithModel` for who wins when a clearance lands while the pilot is typing.
    @State private var routeText = ""
    @State private var altitudeText = ""
    @State private var alternateText = ""
    @State private var editingAircraft: AircraftProfile?
    @State private var confirmClear = false
    @State private var fplURL: URL?
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var routeFocused: Bool
    @FocusState private var altitudeFocused: Bool
    @FocusState private var alternateFocused: Bool

    /// Debounce for live route commits — long enough to type between fixes, short enough that the
    /// plan (grounding, map, Send) is current the moment the pilot pauses.
    static let commitDelayNS: UInt64 = 800_000_000

    private var contextReady: Bool {
        if case .ready = downloads.state(ModelCatalog.llm.id) { return true }
        return ModelStore.isReady(ModelCatalog.llm)
    }

    var body: some View {
        let p = model.palette
        Group {
            if hSize == .compact { compactContent(p) } else { regularContent(p) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bg)
        .barSeparator(p)
        .accessibilityIdentifier("flight-plan-bar")
        .onAppear { syncFromModel() }
        .onChange(of: model.flightPlan) { _, _ in reconcileWithModel() }
        .onChange(of: routeText) { _, text in scheduleRouteCommit(text) }
        .onChange(of: routeFocused) { _, focused in if !focused { commitRouteNow() } }
        .onChange(of: altitudeFocused) { _, focused in if !focused { commitAltitude() } }
        .onChange(of: alternateFocused) { _, focused in if !focused { commitAlternate() } }
        .task(id: model.flightPlan) { fplURL = await model.writeFPLFile() }
        .sheet(item: $editingAircraft) { AircraftSheet(profile: $0).environmentObject(model) }
        .alert("Clear flight plan?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.flightPlan = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the route, altitude, and loaded procedures. Saved aircraft are kept.")
        }
    }

    /// iPad / regular width — the ForeFlight FPL arrangement: boxes left, route center, actions right.
    private func regularContent(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    aircraftChip(p)
                    altitudeBox(p)
                    alternateBox(p)
                }
                .frame(width: 150)
                centerColumn(p)
                rightColumn(p)
            }
            statsRow(p)
        }
    }

    /// iPhone / compact width — the same pieces stacked so nothing clips at 320–430pt.
    private func compactContent(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                aircraftChip(p)
                altitudeBox(p)
                alternateBox(p)
            }
            centerColumn(p)
            HStack(spacing: 10) {
                if model.foreflightEnabled { sendButton(p) }
                Spacer(minLength: 4)
                actionIcons(p)
            }
            ScrollView(.horizontal, showsIndicators: false) { statsRow(p) }
        }
    }

    // MARK: left column — aircraft + altitude (the ForeFlight boxes)

    /// The callsign box: shows the filed aircraft; tapping picks another saved aircraft or adds one.
    private func aircraftChip(_ p: Palette) -> some View {
        Menu {
            ForEach(model.aircraftProfiles) { profile in
                Button {
                    Haptics.impact(.light)
                    model.selectAircraft(profile)
                } label: {
                    Label(profile.displayLine,
                          systemImage: model.selectedAircraft?.id == profile.id ? "checkmark" : "airplane")
                }
            }
            if !model.aircraftProfiles.isEmpty { Divider() }
            Button { editingAircraft = AircraftProfile() } label: {
                Label("Add aircraft…", systemImage: "plus")
            }
            if let selected = model.selectedAircraft {
                Button { editingAircraft = selected } label: {
                    Label("Edit \(selected.callsign)…", systemImage: "pencil")
                }
            }
        } label: {
            box(p) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane").font(.caption2).foregroundStyle(p.textDim)
                    Text(model.flightPlan?.callsign.isEmpty == false
                         ? model.flightPlan!.callsign : "Aircraft")
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(model.flightPlan?.callsign.isEmpty == false ? p.text : p.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(p.textDim)
                }
            }
        }
        .accessibilityIdentifier("plan-aircraft")
        .accessibilityLabel("Aircraft")
    }

    /// The cruise-altitude box, e.g. "16000 ft". Commits on focus loss / collapse / Send (the
    /// number pad has no return key, so there is no submit event to hook).
    private func altitudeBox(_ p: Palette) -> some View {
        box(p) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(p.textDim)
                TextField("Altitude", text: $altitudeText)
                    .textFieldStyle(.plain).keyboardType(.numberPad)
                    .font(.caption.weight(.semibold).monospaced())
                    .focused($altitudeFocused)
                    .accessibilityIdentifier("plan-altitude")
                Text("ft").font(.caption2).foregroundStyle(p.textDim)
            }
        }
    }

    /// The alternate-airport box (the plan's `alternate` — grounding + the old editor's field).
    private func alternateBox(_ p: Palette) -> some View {
        box(p) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(p.textDim)
                TextField("Alternate", text: $alternateText)
                    .textFieldStyle(.plain).autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .font(.caption.weight(.semibold).monospaced())
                    .focused($alternateFocused)
                    .onSubmit { commitAlternate() }
                    .accessibilityIdentifier("plan-alternate")
            }
        }
    }

    // MARK: center — the free-form route field + live entity chips

    private func centerColumn(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            box(p) {
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption2).foregroundStyle(p.textDim)
                    TextField("Route — e.g. KMSP GEP KAMMA KORD", text: $routeText)
                        .textFieldStyle(.plain).autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .font(.caption.weight(.semibold).monospaced())
                        .focused($routeFocused)
                        .onSubmit { commitRouteNow() }
                        .accessibilityIdentifier("plan-route")
                    if !routeText.isEmpty || model.flightPlan != nil {   // clearable even when only
                        Button { Haptics.impact(.light); confirmClear = true } label: {  // altitude/procedures remain
                            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(p.textDim)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("plan-clear")
                    }
                }
            }
            chipsRow(p)
        }
    }

    /// The recognized entities of the committed plan as colour-coded pills (the ForeFlight look) +
    /// any loaded SID/STAR/approach as clearable chips. Recognition is `RouteLeg.classify` — KXXX
    /// airports, 3-letter VORs, 5-letter fixes, letter+digit airways — applied as soon as a commit
    /// lands (typing pause / return / focus loss).
    private func chipsRow(_ p: Palette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if let fp = model.flightPlan {
                    ForEach(Array(fp.fullRoute.enumerated()), id: \.offset) { i, leg in
                        if i > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption2).foregroundStyle(p.textDim.opacity(0.5))
                        }
                        Text(leg.ident)
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(legColor(leg.kind, p))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(legColor(leg.kind, p).opacity(0.14)))
                    }
                    ForEach(fp.loadedProcedures, id: \.kind) { proc in
                        HStack(spacing: 4) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.caption2)
                            Text(proc.displayLine).font(.caption2.weight(.semibold)).lineLimit(1)
                            Button { Haptics.impact(.light); model.clearLoadedProcedure(kind: proc.kind) } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption2)
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("clear-loaded-\(proc.kind)")
                        }
                        .foregroundStyle(p.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(p.accent.opacity(0.14)))
                    }
                } else {
                    Text("Type a route above — airports, fixes, VORs, and airways are recognized as you go.")
                        .font(.caption2).foregroundStyle(p.textDim)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(minHeight: 18)
    }

    // MARK: right column — actions

    private func rightColumn(_ p: Palette) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if model.foreflightEnabled { sendButton(p) }
            actionIcons(p)
        }
    }

    /// The small action icons (.fpl share / map / collapse) — shared by both layouts.
    private func actionIcons(_ p: Palette) -> some View {
        HStack(spacing: 10) {
            if let fplURL {
                ShareLink(item: fplURL) {
                    Image(systemName: "square.and.arrow.up").font(.caption).foregroundStyle(p.accent)
                }
                .buttonStyle(.plain).accessibilityIdentifier("plan-share-fpl")
            }
            Button { Haptics.impact(.light); model.showRouteMap = true } label: {
                Image(systemName: "map").font(.caption).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flight-plan-map").accessibilityLabel("View route on map")
            Button {
                Haptics.impact(.light)
                commitPendingEdits()   // the number-pad altitude has no submit — don't lose it
                withAnimation(.easeInOut(duration: 0.22)) { model.showFlightPlanBar = false }
            } label: {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan-bar-done").accessibilityLabel("Collapse flight plan")
        }
    }

    /// One-tap hand-off of the CURRENT strip contents (pending edits are committed first).
    private func sendButton(_ p: Palette) -> some View {
        let enabled = model.offersForeFlight && model.flightPlan != nil
        return Button {
            Haptics.impact(.medium)
            commitPendingEdits()
            model.openInForeFlight()
        } label: {
            Label("ForeFlight", systemImage: "paperplane.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(enabled ? .white : p.textDim)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(enabled ? p.accent : p.surfaceAlt))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityIdentifier("plan-send-foreflight")
    }

    // MARK: stats row — the ForeFlight trip overview

    /// DIST / ETE / ETA / FUEL / WIND, exactly like ForeFlight's FPL header. ETE/FUEL need the
    /// selected aircraft's cruise speed / burn (edit the aircraft to set them); WIND has no
    /// offline data source, so it reads "–" just as ForeFlight does without wind data.
    private func statsRow(_ p: Palette) -> some View {
        HStack(alignment: .top, spacing: 18) {
            stat(p, "DIST", model.tripStats?.distanceText ?? "–")
            stat(p, "ETE", model.tripStats?.eteText ?? "–")
            TimelineView(.everyMinute) { context in
                stat(p, "ETA", model.tripStats?.etaText(from: context.date) ?? "–")
            }
            stat(p, "FUEL", model.tripStats?.fuelText ?? "–")
            stat(p, "WIND", "–")
            Spacer(minLength: 4)
            if model.flightPlan?.isStale == true {
                Label("Update plan", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(p.warn)
            } else if model.flightPlan != nil, !contextReady {
                Label("AI context downloading", systemImage: "arrow.down.circle")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
        .accessibilityIdentifier("plan-stats")
    }

    private func stat(_ p: Palette, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.textDim)
            Text(value).font(.caption.weight(.semibold).monospaced()).foregroundStyle(p.text)
        }
    }

    // MARK: commit plumbing (live editing — no Save button)

    /// The committed plan as the route string the field shows (dep + enroute + dest).
    private var canonicalRoute: String {
        guard let fp = model.flightPlan else { return "" }
        return ([fp.departure] + fp.route + [fp.destination]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Pull the model's state into the fields — skipped for a field the pilot is typing in.
    private func syncFromModel() {
        if !routeFocused { routeText = canonicalRoute }
        if !altitudeFocused { altitudeText = model.flightPlan?.cruiseAltitudeFt.map(String.init) ?? "" }
        if !alternateFocused { alternateText = model.flightPlan?.alternate ?? "" }
    }

    /// Called on every model plan change. If the field's current text re-parses to exactly the
    /// plan the model now holds, the change was (or is equivalent to) our own commit — leave the
    /// pilot's raw text alone. Otherwise the model moved UNDER the field (an accepted EFB
    /// clearance, a map edit): the clearance wins, even mid-typing — a stale field must never
    /// silently revert an accepted amendment on blur, so the pending commit is cancelled and the
    /// field re-seeded from the plan.
    private func reconcileWithModel() {
        let parsed = FlightPlan.parseRoute(routeText)
        let field = (parsed.departure ?? "", parsed.destination ?? "", parsed.route)
        let plan = (model.flightPlan?.departure ?? "", model.flightPlan?.destination ?? "",
                    model.flightPlan?.route ?? [])
        if field != plan {
            commitTask?.cancel()
            routeText = canonicalRoute            // the model (clearance / map edit) wins
        }
        if !altitudeFocused { altitudeText = model.flightPlan?.cruiseAltitudeFt.map(String.init) ?? "" }
        if !alternateFocused { alternateText = model.flightPlan?.alternate ?? "" }
    }

    /// Debounced live commit: (re)arm on every keystroke; fires after the pilot pauses.
    private func scheduleRouteCommit(_ text: String) {
        guard routeFocused else { return }              // programmatic sync, not a pilot edit
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.commitDelayNS)
            guard !Task.isCancelled else { return }
            commitRouteNow()
        }
    }

    /// Commit the route field now (pause / return / focus loss / Send). No-op when unchanged, so
    /// the flightPlan didSet chain (save, grounding, prefetch) doesn't churn.
    private func commitRouteNow() {
        commitTask?.cancel()
        let text = routeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != canonicalRoute else { return }
        model.commitRouteString(text)
    }

    /// Commit the altitude box (digits only; empty clears).
    private func commitAltitude() {
        let digits = altitudeText.filter(\.isNumber)
        model.setCruiseAltitude(digits.isEmpty ? nil : Int(digits))
    }

    /// Commit the alternate box (empty clears).
    private func commitAlternate() {
        model.setAlternate(alternateText)
    }

    /// Flush every pending field edit — Send and Collapse call this so what leaves the strip is
    /// exactly what's on screen.
    private func commitPendingEdits() {
        commitRouteNow()
        commitAltitude()
        commitAlternate()
    }

    /// A ForeFlight-style field box (matches InputBar.field styling).
    private func box(_ p: Palette, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
    }

    /// Colour per route-leg kind (airports purple-pink, VOR green, GPS blue, airways amber).
    private func legColor(_ kind: RouteKind, _ p: Palette) -> Color {
        switch kind {
        case .airport:  return .hex(0xE879F9)   // purple-pink — departure / destination
        case .vor:      return .hex(0x34D399)   // green — VOR / navaid
        case .waypoint: return .hex(0x60A5FA)   // blue — RNAV / GPS named fix
        case .airway:   return .hex(0xF5C451)   // amber — airway designator
        case .other:    return p.text           // DCT / procedure / unknown
        }
    }
}

// MARK: - Stratux / traffic strip

/// Live ADS-B traffic in range — from the **Stratux receiver** when its link is enabled, otherwise
/// airplanes.live. The always-on link toggle (top of the strip) streams traffic + GPS independent of
/// the input source (that only gates cockpit audio + Start). Renders `model.aircraft` verbatim
/// (freshness is the service actor's job). While the link is on it shows the LINK state:
/// idle → connecting → **connected** (green) → error. Shown/hidden by the Stratux heading icon
/// (itself tinted by link state). (Was carousel page 3.)
struct StratuxBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 8) {
            // The always-on Stratux link: traffic + GPS stream whenever this is on and the app is
            // foregrounded — independent of the input source (that only gates cockpit audio + Start).
            Toggle(isOn: linkBinding) {
                Text("Stratux link").font(.caption.weight(.semibold)).foregroundStyle(p.text)
            }
            .tint(p.accent)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("stratux-enable-bar")
            Group {
                if model.stratuxEnabled {
                    stratux(p)
                } else if !model.adsbStreamingEnabled {
                    offState(p, "antenna.radiowaves.left.and.right.slash", "Online ADS-B off — enable in Settings")
                } else if model.aircraft.isEmpty {
                    offState(p, "antenna.radiowaves.left.and.right", emptyText)
                } else {
                    traffic(p, icon: "antenna.radiowaves.left.and.right", iconColor: p.accent, titleColor: p.text,
                            title: "\(model.aircraft.count) in range", trailing: model.aircraftUpdatedAt.map(updatedLabel))
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bg)
        .barSeparator(p)
        .accessibilityIdentifier("stratux-bar")
    }

    /// Toggle binding that adds a haptic tap on change; `AppModel.stratuxEnabled`'s didSet stays the
    /// source of truth (persists + reconciles the traffic providers).
    private var linkBinding: Binding<Bool> {
        Binding(get: { model.stratuxEnabled }, set: { Haptics.impact(.light); model.stratuxEnabled = $0 })
    }

    /// The Stratux ADS-B link state.
    @ViewBuilder private func stratux(_ p: Palette) -> some View {
        switch model.stratuxStatus {
        case .idle:
            offState(p, "dot.radiowaves.up.forward", "Stratux link on — waiting for the receiver")
        case .connecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.mini).tint(p.warn)
                Text("Connecting to Stratux…").font(.caption.weight(.semibold)).foregroundStyle(p.warn)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("stratux-connecting")
        case .connected:
            traffic(p, icon: "dot.radiowaves.up.forward", iconColor: p.good, titleColor: p.good,
                    title: "Stratux ADS-B connected",
                    trailing: model.stratuxGPS.flatMap { $0.hasFix ? "\($0.fixLabel) · \($0.satellites) sat" : nil },
                    emptyNote: "Connected — no traffic in range yet")
                .accessibilityIdentifier("stratux-connected")
        case .error(let msg):
            offState(p, "antenna.radiowaves.left.and.right.slash", "Stratux link: \(msg) — retrying", color: p.bad)
        }
    }

    /// Shared header + nearest-aircraft chips for a populated/connected traffic state.
    @ViewBuilder private func traffic(_ p: Palette, icon: String, iconColor: Color, titleColor: Color,
                                      title: String, trailing: String?, emptyNote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.caption2).foregroundStyle(iconColor)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(titleColor)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.caption2).foregroundStyle(p.textDim).lineLimit(1) }
            }
            if model.aircraft.isEmpty {
                Text(emptyNote ?? "No traffic in range").font(.caption2).foregroundStyle(p.textDim)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(model.aircraft.prefix(20)) { ac in
                            Text(ac.label ?? ac.hex)
                                .font(.caption2.weight(.semibold).monospaced()).foregroundStyle(p.text)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(p.surfaceAlt).clipShape(Capsule())
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyText: String {
        if case .error = model.adsbStatus { return "ADS-B feed unavailable — retrying" }
        let icao = model.airport.isEmpty ? "KDFW" : model.airport.uppercased()
        return "Searching for traffic near \(icao)…"
    }

    /// Manual "updated …" stamp — avoids the future-tense flicker ("in 0 seconds") that the relative
    /// formatter emits on a sub-second-old snapshot.
    private func updatedLabel(_ at: Date) -> String {
        let s = max(0, Date().timeIntervalSince(at))
        return s < 2 ? "updated just now" : "updated \(Int(s))s ago"
    }

    private func offState(_ p: Palette, _ icon: String, _ text: String, color: Color? = nil) -> some View {
        let c = color ?? p.textDim
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.callout).foregroundStyle(c)
            Text(text).font(.caption).foregroundStyle(c).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Input strip

/// The input controls, extracted from the old controls bar into a collapsible strip (toggled by the
/// heading-bar input icon; the ✓ collapses it). Start/Stop moved to the heading power button and the
/// live input meter moved to the transcript header, so this strip is purely "what am I listening to
/// and how": source picker, feed monitor, and the link/airport/frequency context for the chosen
/// source. Nothing here changes the capture pipeline — same bindings as before.
struct InputBar: View {
    @EnvironmentObject var model: AppModel
    static let freqs = ["auto", "approach", "departure", "tower", "ground", "clearance", "center", "ctaf"]

    var body: some View {
        let p = model.palette
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("Input").font(.caption).foregroundStyle(p.textDim)
                    Picker("Input", selection: $model.source) {
                        ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(p.text)
                    // Locked while a REAL capture is live: the audio source is bound into the pipeline at
                    // Start, so switching it mid-run would leave the run pulling from the old provider (a
                    // Stratux↔feed split-brain). Stop to change inputs — mirrors the model picker's gate.
                    // (Not locked in the model-less demo, which shows `.live` but binds no source.)
                    .disabled(model.isLiveCapturing)
                    .accessibilityIdentifier("source-picker")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))

                Spacer(minLength: 0)

                // Listen to the live feed / Stratux cockpit audio through the speakers (verify it's
                // arriving). Feed/Stratux only — mic/USB would feed back.
                if model.source == .liveFeed || model.source == .stratux {
                    Button {
                        Haptics.impact(.light)
                        model.monitorEnabled.toggle()
                    } label: {
                        Image(systemName: model.monitorEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(model.monitorEnabled ? p.accent : p.textDim)
                            .frame(width: 30, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("monitor-toggle")
                    .accessibilityLabel("Listen to feed")
                }

                // Collapse the strip to tidy the screen — mirrors the heading-bar input toggle.
                Button {
                    Haptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.22)) { model.showInputBar = false }
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.accent).frame(width: 30, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("input-bar-done")
                .accessibilityLabel("Collapse input")
            }

            // The link + airport/frequency context apply ONLY to the internet live feed;
            // they are hidden for the microphone and USB-audio inputs.
            if model.source.needsLink {
                field(icon: "link", placeholder: "LiveATC link or stream URL", text: $model.streamURL)
                HStack(spacing: 10) {
                    field(icon: "airplane", placeholder: "Airport context (e.g. KDFW)", text: $model.airport)
                    Picker("Frequency", selection: $model.frequency) {
                        ForEach(Self.freqs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(p.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
                }
            }

            // Stratux: cockpit audio + on-board traffic/GPS over the receiver's Wi-Fi. The airport sets
            // the corrector's facility phraseology; the chip shows the live link/GPS/traffic state. The
            // receiver address lives in Settings › Stratux receiver.
            if model.source == .stratux {
                HStack(spacing: 10) {
                    field(icon: "airplane", placeholder: "Airport context (e.g. KBOS)", text: $model.airport)
                    StratuxStatusChip()
                }
            }

            HStack(spacing: 8) {
                Text(model.detail).font(.caption).foregroundStyle(p.textDim).lineLimit(1)
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.bg)
        .barSeparator(p)
        .accessibilityIdentifier("input-bar")
    }

    private func field(icon: String, placeholder: String, text: Binding<String>) -> some View {
        let p = model.palette
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(p.textDim)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Standby

/// Floating low-power banner shown over a dimmed (but still visible) console while in standby.
/// Capture is stopped and the audio session released (see `AppModel.enterStandby`) so an unattended
/// quiet feed stops draining the battery; the transcript stays on screen. Resume restarts whatever
/// was running.
struct StandbyBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let p = model.palette
        VStack {
            Spacer()
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "power").foregroundStyle(p.accent)
                    Text("Standby — capture paused").font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.text)
                }
                Button { model.exitStandby() } label: {
                    Text(model.resumeSourceLabel.map { "Resume \($0)" } ?? "Resume")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(p.accent).foregroundStyle(p.bg)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("standby-resume")
            }
            .padding(20)
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

// MARK: - Input level meter

/// A compact live audio-level meter shown next to Start/Stop while a source is running.
/// Source-agnostic (mic, USB, internet feed, replay) — proof that audio is actually flowing.
struct InputLevelMeter: View {
    @EnvironmentObject var model: AppModel
    private let bars = 7

    var body: some View {
        let p = model.palette
        let level = model.inputLevel
        let active = level > 0.02
        return HStack(spacing: 4) {
            Image(systemName: model.source == .liveFeed ? "dot.radiowaves.left.and.right" : "mic.fill")
                .font(.caption2)
                .foregroundStyle(active ? p.accent : p.textDim)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let threshold = Float(i + 1) / Float(bars)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level >= threshold ? p.accent : p.border)
                        .frame(width: 3, height: 5 + CGFloat(i) * 1.6)
                }
            }
            .frame(height: 18, alignment: .bottom)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(p.surfaceAlt).clipShape(Capsule())
        .overlay(Capsule().stroke(p.border, lineWidth: 1))
        .accessibilityLabel("Input level")
    }
}

// MARK: - Transcribing indicator

/// A small "Transcribing… Ns" pill shown while a transmission is being decoded. The elapsed time makes
/// a slow model legible: if it climbs to many seconds per transmission, the model is the bottleneck
/// (not a stalled pipeline). Disappears between transmissions.
struct TranscribingIndicator: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = model.palette
        let secs = model.transcribeStartedAt.map { max(0, now.timeIntervalSince($0)) }
        return HStack(spacing: 5) {
            ProgressView().controlSize(.mini).tint(p.accent)
            Text(secs.map { $0 >= 1 ? String(format: "Transcribing… %.0fs", $0) : "Transcribing…" } ?? "Transcribing…")
                .font(.caption2.monospaced()).foregroundStyle(p.textDim)
        }
        .onReceive(tick) { now = $0 }
        .accessibilityIdentifier("transcribing-indicator")
    }
}

// MARK: - Squelch controls

/// Reusable squelch editor — used in Settings AND in the popover from the input meter. The
/// threshold slider is ALWAYS visible (disabled while Auto is on) so there's a clear way to set the
/// minimum energy that wakes the transcriber, with a live input-level reference while running.
struct SquelchControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.squelchAuto) {
                Text("Auto squelch").font(.caption).foregroundStyle(p.text)
            }
            Text("Auto learns the channel's noise floor from the gaps between transmissions and only wakes the transcriber on real speech. Turn it off to set the minimum energy yourself.")
                .font(.caption2).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.1").font(.caption2).foregroundStyle(p.textDim)
                Slider(value: $model.manualSquelch, in: 0...1)
                Image(systemName: "speaker.wave.3").font(.caption2).foregroundStyle(p.textDim)
            }
            .disabled(model.squelchAuto)
            .opacity(model.squelchAuto ? 0.4 : 1)
            .accessibilityIdentifier("squelch-slider")
            Text(model.squelchAuto
                 ? "Threshold is automatic — turn off Auto to set it manually."
                 : "Higher = needs a louder signal to start transcribing (fewer false wakes); lower = more sensitive.")
                .font(.caption2).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.showMicCalibration = true } label: {
                Label("Calibrate microphone…", systemImage: "mic.badge.plus")
                    .font(.caption.weight(.semibold)).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("calibrate-mic-button")
            if !model.squelchAuto, model.calibratedGateRMS != nil {
                Label("Calibrated to your mic — move the slider to override.", systemImage: "checkmark.seal.fill")
                    .font(.caption2).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Records your background noise, then your voice, and sets the threshold between them — best when Auto isn't gating a noisy room.")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isRunning {
                HStack(spacing: 8) {
                    Text("Live input").font(.caption2).foregroundStyle(p.textDim)
                    InputLevelMeter()
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Floating widget canvas (regular width)

/// Lays out every visible floating widget over the map. Each card is a `FloatingWidgetContainer`
/// positioned from its persisted `WidgetFrame`; the canvas itself is transparent, so taps between cards
/// fall through to the map behind it.
struct FloatingCanvas: View {
    /// Observe ONLY the widget store (layout + probe) — never `AppModel` — so the several-per-second
    /// live-data storm doesn't re-run this body (and rebuild every card) while one is being dragged. The
    /// palette is passed in as a value so a theme switch still restyles the cards, and each card's live
    /// content (transcript, etc.) keeps its own `AppModel` subscription from the environment.
    @EnvironmentObject var widgets: WidgetStore
    let palette: Palette

    private var frames: [WidgetFrame] {
        widgets.layout.items.filter { $0.kind == .objectInfo ? (widgets.mapProbe != nil) : $0.visible }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(frames) { frame in
                    FloatingWidgetContainer(frame: frame, container: geo.size, palette: palette, widgets: widgets) {
                        widget(frame.kind)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Stable reference frame for the card drag/resize gestures (Issue 3). Measuring the drag
            // in the card's OWN (.local) space fed back into `.position`, which moves that same space —
            // an oscillation most visible when the finger is nearly still. This canvas space doesn't
            // move, so the translation is the pure finger delta and the card tracks 1:1.
            .coordinateSpace(.named(Self.dragSpace))
        }
    }

    static let dragSpace = "floatingCanvas"

    @ViewBuilder private func widget(_ kind: FloatingWidgetKind) -> some View {
        switch kind {
        case .transcript:  TranscriptCard()
        case .flightPlan:  EmptyView()   // retired — the flight plan is the strip under the top bar now
        case .objectInfo:  if let probe = widgets.mapProbe { MapObjectView(result: probe, onClose: { widgets.mapProbe = nil }) }
        case .proofOfLife: SidebarWidget.proofOfLife.card
        case .stratux:     SidebarWidget.stratux.card
        case .host:        SidebarWidget.host.card
        case .latency:     SidebarWidget.latency.card
        case .diagnostics: SidebarWidget.diagnostics.card
        }
    }
}

/// Top-bar menu to show/hide the floating widgets and reset the layout (replaces the old bar toggles).
struct WidgetsMenu: View {
    @EnvironmentObject var widgets: WidgetStore
    var iconSize: CGFloat = 19
    var body: some View {
        Menu {
            ForEach(widgets.layout.items.filter { $0.kind.userManageable }) { f in
                Button {
                    Haptics.impact(.light)
                    if f.visible { widgets.update(f.kind) { $0.visible = false } } else { widgets.show(f.kind) }
                } label: { Label(f.kind.title, systemImage: f.visible ? "checkmark" : f.kind.symbol) }
            }
            Divider()
            Button { Haptics.impact(.light); widgets.reset() } label: {
                Label("Reset layout", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "rectangle.3.group").font(.system(size: iconSize)).frame(width: 30, height: 30)
        }
        .accessibilityIdentifier("widgets-menu").accessibilityLabel("Widgets")
    }
}

// MARK: - Reusable card

struct Card<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.floatingSurface) private var floating   // hosted in a FloatingWidgetContainer?
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(p.textDim)
                .tracking(0.8)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // When floating, the container owns the (opacity-adjustable) background — drop our own chrome.
        .background(floating ? Color.clear : p.surface)
        .clipShape(RoundedRectangle(cornerRadius: floating ? 0 : 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: floating ? 0 : 1))
    }
}

#Preview {
    ConsoleView()
        .environmentObject(AppModel())
        .environmentObject(ModelDownloadManager())
}
