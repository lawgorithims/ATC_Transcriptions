import SwiftUI

/// The live console — a SwiftUI port of the browser UI (`server/static/*`): brand +
/// status pills, a source/controls bar, the live transcript, and a latency/host
/// sidebar. Adapts to a 2-column layout on iPad (regular width) and a stacked scroll
/// on iPhone (compact).
struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let p = model.palette
        ZStack {
            p.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
                NotificationCarousel()
                ControlsBar()
                hairline
                mainArea
            }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet().environmentObject(model).environmentObject(downloads)
        }
        .sheet(isPresented: $model.showFlightBag) {
            FlightBagSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showWhatsNew) {
            WhatsNewSheet().environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.needsOnboarding) {
            OnboardingDownloadView().environmentObject(model).environmentObject(downloads)
        }
        .animation(.easeInOut(duration: 0.25), value: model.theme)
        .onAppear {
            // Bridge a finished download back to the model so it can load a model that wasn't
            // present at launch (lean TestFlight build → first-run download → live console).
            downloads.onReady = { entry in
                model.modelDidDownload(entry)
                // The AI context fixer rides along with whichever speech model the user downloads,
                // so correction works regardless of which model they picked. Idempotent — a no-op
                // if the fixer is already present or downloading.
                if entry.kind == .whisperKit, !ModelStore.isReady(ModelCatalog.llm) {
                    downloads.download(ModelCatalog.llm)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Backgrounding stops capture + releases audio (no background streaming/drain); ADS-B is
            // paused/cleared; foregrounding resumes what was running.
            model.handleScenePhase(newPhase)
        }
    }

    private var hairline: some View { Rectangle().fill(model.palette.border).frame(height: 1) }

    @ViewBuilder private var mainArea: some View {
        // When every widget is removed, drop the sidebar so the transcript reclaims the full width
        // (re-add widgets from the "+" in the transcript header). Keep the column while editing so
        // drag-to-reorder still works.
        let showSidebar = !model.widgets.isEmpty || model.editingWidgets
        if hSize == .regular {
            HStack(alignment: .top, spacing: 14) {
                transcriptArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showSidebar { SidebarColumn().frame(width: 300) }
            }
            .padding(14)
            .animation(.easeInOut(duration: 0.2), value: showSidebar)
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    transcriptArea.frame(minHeight: 360)
                    if showSidebar { SidebarColumn() }
                }
                .padding(14)
                .animation(.easeInOut(duration: 0.2), value: showSidebar)
            }
        }
    }

    /// Standby dims + disables ONLY the transcript box (the rest of the console stays usable) and
    /// floats the Resume banner over it.
    private var transcriptArea: some View {
        TranscriptCard()
            .opacity(model.standby ? 0.4 : 1)
            .disabled(model.standby)
            .overlay { if model.standby { StandbyBanner().environmentObject(model) } }
            .animation(.easeInOut(duration: 0.2), value: model.standby)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        HStack(spacing: 12) {
            Image("BrandMark")
                .resizable().scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("CommSight").font(.headline).foregroundStyle(p.text)
                Text("On-device ATC transcription").font(.caption2).foregroundStyle(p.textDim)
            }
            Spacer()
            ThemeSwitcher()
            // Electronic Flight Bag: file/edit a flight plan. A yellow warning rides the briefcase
            // when the saved plan is over a week old (refile recommended before the next flight).
            Button { model.showFlightBag = true } label: {
                Image(systemName: "briefcase.fill").font(.system(size: 15))
                    .overlay(alignment: .topTrailing) {
                        if model.flightPlan?.isStale == true {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9)).foregroundStyle(p.warn)
                                .offset(x: 6, y: -5)
                        }
                    }
            }
            .buttonStyle(.plain).foregroundStyle(p.textDim)
            .accessibilityIdentifier("flight-bag-button")
            .accessibilityLabel("Flight bag")
            Button { model.enterStandby() } label: {
                Image(systemName: "power").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(p.textDim)
            .accessibilityIdentifier("standby-button")
            .accessibilityLabel("Standby")
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 17))
            }
            .buttonStyle(.plain).foregroundStyle(p.textDim)
            .accessibilityIdentifier("settings-button")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.surface)
    }
}

struct ThemeSwitcher: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        HStack(spacing: 2) {
            ForEach(AppTheme.allCases) { theme in
                Button { model.theme = theme } label: {
                    Image(systemName: theme.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .background(model.theme == theme ? p.accent.opacity(0.22) : .clear)
                        .foregroundStyle(model.theme == theme ? p.accent : p.textDim)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("theme-\(theme.rawValue)")
                .accessibilityLabel("\(theme.label) theme")
            }
        }
        .padding(3)
        .background(p.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border, lineWidth: 1))
    }
}

// MARK: - Notification carousel (paged: status · flight plan · flight data)

/// The top notification strip is a swipeable, paged carousel: page 1 is the live status pills,
/// page 2 summarizes the filed flight plan, page 3 is reserved for live flight data (GPS). A
/// fixed height is required — `TabView(.page)` has no intrinsic height.
struct NotificationCarousel: View {
    @EnvironmentObject var model: AppModel
    @State private var page = 0
    private let pageCount = 3

    var body: some View {
        let p = model.palette
        TabView(selection: $page) {
            StatusBar().tag(0)
            FlightPlanPage().tag(1)
            FlightDataPage().tag(2)
        }
        // Custom dots (the system page indicator ran ~33% larger); ~5.5pt circles.
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 84)
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Circle()
                        .fill(i == page ? p.text : p.textDim.opacity(0.4))
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .padding(.bottom, 5)
        }
        .background(p.bg)
    }
}

// MARK: - Status strip (pills + badges) — carousel page 1

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

// MARK: - Carousel page 2: flight plan summary

/// The filed flight plan shown as the full, colour-coded route (departure → fixes/airways →
/// destination), or a prompt to file one. Airports are purple-pink, VOR navaids green, RNAV/GPS
/// fixes blue, airways amber. The route is greyed until the on-device AI context (the fixer GGUF)
/// has downloaded — until then the plan can't actually bias corrections. Tapping opens the editor.
struct FlightPlanPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager

    private var contextReady: Bool {
        if case .ready = downloads.state(ModelCatalog.llm.id) { return true }
        return ModelStore.isReady(ModelCatalog.llm)
    }

    var body: some View {
        let p = model.palette
        Group {
            if let fp = model.flightPlan, !fp.fullRoute.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "briefcase.fill").font(.caption2).foregroundStyle(p.textDim)
                        if !fp.callsign.isEmpty {
                            Text(fp.callsign).font(.caption.weight(.semibold)).foregroundStyle(p.text)
                        }
                        if !fp.aircraftType.isEmpty {
                            Text(fp.aircraftType).font(.caption2).foregroundStyle(p.textDim).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if fp.isStale {
                            Label("Update", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.semibold)).foregroundStyle(p.warn)
                        } else if !contextReady {
                            Label("AI context downloading", systemImage: "arrow.down.circle")
                                .font(.caption2).foregroundStyle(p.textDim)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(fp.fullRoute.enumerated()), id: \.offset) { i, leg in
                                if i > 0 {
                                    Image(systemName: "chevron.compact.right")
                                        .font(.caption2).foregroundStyle(p.textDim.opacity(0.5))
                                }
                                Text(leg.ident)
                                    .font(.caption.weight(.semibold).monospaced())
                                    .foregroundStyle(contextReady ? legColor(leg.kind, p) : p.textDim.opacity(0.7))
                            }
                        }
                        .padding(.trailing, 16)
                    }
                    .opacity(contextReady ? 1 : 0.55)
                }
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "briefcase.fill").font(.callout).foregroundStyle(p.textDim)
                    Text("No flight plan — tap to file one").font(.caption).foregroundStyle(p.textDim)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.showFlightBag = true }
        .accessibilityIdentifier("carousel-flight-plan")
    }

    /// Colour per route-leg kind (see the user's spec: airports purple-pink, VOR green, GPS blue).
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

// MARK: - Carousel page 3: live flight data (location) — placeholder

/// Live ADS-B traffic in range (airplanes.live). Renders `model.aircraft` verbatim — the freshness
/// authority is the `ADSBService` actor, not this view — across three states: off, searching/empty,
/// and populated (count + nearest callsigns + a live "updated … ago" stamp).
struct FlightDataPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        Group {
            if !model.adsbStreamingEnabled {
                offState(p, "antenna.radiowaves.left.and.right.slash", "Online ADS-B off — enable in Settings")
            } else if model.aircraft.isEmpty {
                offState(p, "antenna.radiowaves.left.and.right", emptyText)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.caption2).foregroundStyle(p.accent)
                        Text("\(model.aircraft.count) in range").font(.caption.weight(.semibold)).foregroundStyle(p.text)
                        Spacer(minLength: 4)
                        if let at = model.aircraftUpdatedAt {
                            Text(updatedLabel(at)).font(.caption2).foregroundStyle(p.textDim).lineLimit(1)
                        }
                    }
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
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("carousel-flight-data")
    }

    private var emptyText: String {
        if case .error = model.adsbStatus { return "ADS-B feed unavailable — retrying" }
        let icao = model.airport.isEmpty ? "KDFW" : model.airport.uppercased()
        return "Searching for traffic near \(icao)…"
    }

    /// Manual "updated …" stamp — avoids the future-tense flicker ("in 0 seconds") that the relative
    /// formatter emits on a sub-second-old snapshot. Refreshes each poll (every ~5 s).
    private func updatedLabel(_ at: Date) -> String {
        let s = max(0, Date().timeIntervalSince(at))
        return s < 2 ? "updated just now" : "updated \(Int(s))s ago"
    }

    private func offState(_ p: Palette, _ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.callout).foregroundStyle(p.textDim)
            Text(text).font(.caption).foregroundStyle(p.textDim).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Controls

struct ControlsBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showSquelch = false
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
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))

                Spacer(minLength: 0)

                // Listen to the live feed / Stratux cockpit audio through the speakers (verify it's
                // arriving). Feed/Stratux only — mic/USB would feed back.
                if model.source == .liveFeed || model.source == .stratux {
                    Button { model.monitorEnabled.toggle() } label: {
                        Image(systemName: model.monitorEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(model.monitorEnabled ? p.accent : p.textDim)
                            .frame(width: 30, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("monitor-toggle")
                    .accessibilityLabel("Listen to feed")
                }

                // Tap the input meter to open squelch (set the minimum energy that wakes Whisper).
                if model.isRunning {
                    Button { showSquelch = true } label: { InputLevelMeter() }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("input-level-meter")
                        .accessibilityLabel("Input level / squelch")
                        .popover(isPresented: $showSquelch) {
                            SquelchControls().environmentObject(model)
                                .padding(16).frame(width: 300)
                                .presentationCompactAdaptation(.popover)
                        }
                }

                Button { model.isRunning ? model.stop() : model.start() } label: {
                    Label(model.isRunning ? "Stop" : "Start",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(model.isRunning ? p.bad.opacity(0.18) : p.accent)
                        .foregroundStyle(model.isRunning ? p.bad : p.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("start-stop-button")
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
                if model.transcribing { TranscribingIndicator() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.bg)
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

// MARK: - Reusable card

struct Card<Content: View>: View {
    @EnvironmentObject var model: AppModel
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
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
    }
}

#Preview {
    ConsoleView()
        .environmentObject(AppModel())
        .environmentObject(ModelDownloadManager())
}
