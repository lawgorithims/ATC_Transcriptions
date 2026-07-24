import SwiftUI

/// Settings sheet — organized into category sub-pages (Transcription & AI, Audio & speakers, Traffic &
/// connections, Charts & downloads, General) so the many controls aren't one long wall. Each category is
/// a NavigationLink that pushes a page of the relevant `Card`s; the Done button is reachable from every
/// page. Model picking, correction tuning, downloads, connections, and the buried test-bench unlock all
/// live under their category.
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    @Environment(\.dismiss) private var dismiss

    /// Taps on the version row — 7 unlocks the buried test bench. Transient (not persisted); the
    /// unlock itself persists via `model.diagnosticsEnabled`.
    @State private var versionTaps = 0

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    categoryLink("Transcription & AI", "waveform", "Speech models · active model · correction",
                                 id: "settings-cat-transcription") {
                        categoryPage("Transcription & AI") { transcriptionCategory }
                    }
                    categoryLink("Audio & speakers", "mic", "Squelch · calibrate mic · speaker separation",
                                 id: "settings-cat-audio") {
                        categoryPage("Audio & speakers") { audioCategory }
                    }
                    categoryLink("Traffic & connections", "dot.radiowaves.up.forward", "ADS-B · Stratux · ForeFlight",
                                 id: "settings-cat-connections") {
                        categoryPage("Traffic & connections") { connectionsCategory }
                    }
                    categoryLink("Charts & downloads", "map", "Offline VFR/IFR charts & approach plates",
                                 id: "settings-cat-downloads") {
                        DownloadsView(bag: model.plateBag).environmentObject(model)
                    }
                    categoryLink("Satellites", "antenna.radiowaves.left.and.right",
                                 "Predicted GPS geometry · interference check",
                                 id: "settings-cat-satellites") {
                        SatellitesView().environmentObject(model)
                    }
                    categoryLink("General", "gearshape", "Display · version · what’s new",
                                 id: "settings-cat-general") {
                        categoryPage("General") { generalCategory }
                    }
                    // Hidden Developer section — unlocked by the same 7-tap version gesture as the test bench.
                    if model.diagnosticsEnabled {
                        categoryLink("Developer · Globe", "globe.americas.fill", "Experimental globe engine · battery A/B",
                                     id: "settings-cat-developer") {
                            categoryPage("Developer · Globe") { developerCategory }
                        }
                    }
                }
                .padding(16)
            }
            .background(p.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
    }

    // MARK: Category navigation

    /// A top-level category row that pushes `destination`. Mirrors the existing Downloads/What's-new
    /// NavigationLink idiom (icon + title + subtitle + chevron).
    private func categoryLink<D: View>(_ title: String, _ icon: String, _ subtitle: String, id: String,
                                       @ViewBuilder destination: @escaping () -> D) -> some View {
        let p = model.palette
        return NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body).foregroundStyle(p.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(p.text)
                    Text(subtitle).font(.caption2).foregroundStyle(p.textDim)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(p.textDim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier(id)
    }

    /// A pushed category page: a scroll of its Cards with the title + a Done button (so Done is reachable
    /// without popping back to the category list first).
    @ViewBuilder
    private func categoryPage<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(spacing: 16) { content() }.padding(16)
        }
        .background(model.palette.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    /// DEVELOPER-ONLY globe test harness (hidden behind the 7-tap unlock). Flip the Map tab between flat
    /// Mercator and the experimental globe engine, and open the live battery readout for the on-device A/B —
    /// the vehicle for validating the MapLibre-globe fork (see ios/docs/GLOBE_FORK_PLAN.md).
    @ViewBuilder private var developerCategory: some View {
        let p = model.palette
        #if canImport(MapLibre)
        Card(title: "Map projection") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.useGlobeProjection) {
                    Text("Globe projection (experimental)").font(.caption).foregroundStyle(p.text)
                }
                .tint(p.accent)
                .accessibilityIdentifier("globe-projection-toggle")
                Text(model.useMapLibreMap
                     ? "Curves the chart onto a sphere (custom globe fork). Turn on, then on the Map PINCH-ZOOM OUT until the chart curves into a full globe — drag to rotate it, pinch back in and it flattens seamlessly to the flat chart. Curvature shows below ~z6; at normal chart zooms it's imperceptible by design. Flipping remounts the map."
                     : "Requires the New GPU map (MapLibre) engine — turn it on in General → Map engine first.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
        #else
        Card(title: "Map projection") {
            Text("MapLibre is not linked in this build.").font(.caption2).foregroundStyle(p.textDim)
        }
        #endif
        Card(title: "Battery A/B") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Compare globe vs flat idle cost with transcription OFF. mapFPS ≈ 0 at idle is the goal.")
                    .font(.caption2).foregroundStyle(p.textDim)
                NavigationLink { BatteryDiagnosticsView().environmentObject(model) } label: {
                    HStack {
                        Text("Live battery diagnostics").font(.callout).foregroundStyle(p.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(p.textDim)
                    }
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("dev-battery-diagnostics")
            }
        }
    }

    // MARK: Categories

    @ViewBuilder private var transcriptionCategory: some View {
        let p = model.palette
        // Opt-in on-device transcript log. Lives in this category (not the old flat settings list) since
        // the settings sheet was reorganized into categories upstream — it is a transcription setting.
        Card(title: "Transcript log") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.transcriptLoggingEnabled) {
                    Text("Save transcript log").font(.caption).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("transcript-log-toggle")
                Text("Saves every transmission — raw text, corrections, the parsed instruction, its confidence, and the GPS integrity at the time — to a private file on this device for QA and to improve the model. Off by default. Stays on this device; never uploaded.")
                    .font(.caption2).foregroundStyle(p.textDim)
                if let url = model.transcriptLogFileURL {
                    ShareLink(item: url) {
                        Label("Export transcript log", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold)).foregroundStyle(p.accent)
                    }
                    .accessibilityIdentifier("transcript-log-export")
                }
            }
            .task(id: model.transcriptLoggingEnabled) { await model.flushTranscriptLog() }
        }
        Card(title: "Models") {
            VStack(spacing: 10) {
                ForEach(ModelCatalog.all) { entry in
                    ModelDownloadRow(entry: entry)
                }
                Text("Models download once over Wi-Fi and are stored on this device. The required speech model is needed to transcribe; the others are optional (higher-accuracy model, a stock model for accuracy comparison, on-device AI fixer).")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Card(title: "Transcription model") {
            VStack(spacing: 10) {
                KV("Active model", model.activeModelLabel)
                if let s = model.measuredSpeed {
                    KV("Measured speed", String(format: "%.1f× real-time", s))
                }
                VStack(spacing: 8) {
                    ForEach(ModelCatalog.whisperEntries) { e in
                        modelButton(e.id, e.shortLabel)
                    }
                }
            }
        }
        Card(title: "Transcript correction") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $model.correctionEnabled) {
                    Text("Vocabulary correction").font(.caption).foregroundStyle(p.text)
                }
                Text("Normalizes spoken numbers, collapses repetition loops, and snaps near-miss callsign / runway / waypoint names onto the airport vocabulary. On-device, instant, zero dependencies.")
                    .font(.caption2).foregroundStyle(p.textDim)
                Rectangle().fill(p.border).frame(height: 1)
                Text("AI context fixer").font(.caption).foregroundStyle(p.text)
                HStack(spacing: 8) {
                    backendButton(.off, "Off")
                    backendButton(.local, "On-device")
                    backendButton(.foundation, "Apple Intel.")
                }
                .disabled(!model.correctionEnabled)
                .opacity(model.correctionEnabled ? 1 : 0.5)
                Text("A language model corrects semantic mishears, ICAO phraseology, repetition, and stray non-English words the dictionary can't — using retrieved ATC context (callsigns, phraseology, this facility's names). On-device runs on the CPU in the background so it never slows transcription; Apple Intelligence needs a capable device. Either falls back to vocabulary-only when unavailable. The raw transcript is always kept and every edit is shown.")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .opacity(model.correctionEnabled ? 1 : 0.5)

                Rectangle().fill(p.border).frame(height: 1)
                Toggle(isOn: $model.skipWhenConfident) {
                    Text("Skip the AI fixer when confident").font(.caption).foregroundStyle(p.text)
                }
                .disabled(!model.correctionEnabled || model.llmBackend == .off)
                HStack(spacing: 8) {
                    sensitivityButton(.conservative, "Conservative")
                    sensitivityButton(.balanced, "Balanced")
                    sensitivityButton(.aggressive, "Aggressive")
                }
                .disabled(!model.correctionEnabled || model.llmBackend == .off || !model.skipWhenConfident)
                .opacity((model.correctionEnabled && model.llmBackend != .off && model.skipWhenConfident) ? 1 : 0.5)
                Text("Runs the AI fixer only on transmissions that look suspicious (low speech-model confidence, a callsign/runway near-miss, non-English, or repetition) and skips clearly-clean ones — saving CPU and battery. Conservative runs it more often (safest); Aggressive skips more. Skipped transmissions still show the raw + vocabulary-corrected text.")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .opacity(model.correctionEnabled ? 1 : 0.5)

                Rectangle().fill(p.border).frame(height: 1)
                Text("Cloud fixer (advanced)").font(.caption).foregroundStyle(p.text)
                TextField("https://your-server/fix", text: $model.remoteFixerURL)
                    .font(.caption2).foregroundStyle(p.text)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(!model.correctionEnabled || model.llmBackend == .off)
                if !model.remoteFixerURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label(model.remoteFixerURLValid ? "Cloud second-pass enabled"
                                                    : "Needs https, or http on a private LAN host — ignored",
                          systemImage: model.remoteFixerURLValid ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(model.remoteFixerURLValid ? p.accent : p.textDim)
                }
                Text("Optional. When set, the on-device fixer runs first, then a larger model at this URL gets a second pass within the same 2–3 second budget (abandoned if slow). It sees the same grounded ATC context and passes the identical safety guardrails — it can never change a number, runway, or direction the on-device model preserved. Leave blank to stay fully on-device.")
                    .font(.caption2).foregroundStyle(p.textDim)
                    .opacity(model.correctionEnabled ? 1 : 0.5)
            }
        }
    }

    @ViewBuilder private var audioCategory: some View {
        let p = model.palette
        Card(title: "Squelch") {
            SquelchControls()
        }
        Card(title: "Speakers") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.diarizationEnabled) {
                    Text("Separate speakers").font(.caption).foregroundStyle(p.text)
                }
                Text("Splits a transmission at push-to-talk / squelch breaks and tags each speaker (S1, S2…) on its own line — so ATC and the aircraft don't share a line. Heuristic and on-device; it can't separate people talking over each other simultaneously.")
                    .font(.caption2).foregroundStyle(p.textDim)
                Divider().padding(.vertical, 2)
                Toggle(isOn: $model.acousticFillEnabled) {
                    Text("Guess speaker by voice (experimental)").font(.caption).foregroundStyle(p.text)
                }
                .disabled(!model.diarizationEnabled)
                .accessibilityIdentifier("acoustic-fill-toggle")
                Text("When the words alone don't reveal who's talking, CommSight can guess from the sound of the voice. On a single radio frequency every voice shares the same channel, so this is unreliable and may mislabel lines — it's off by default. Needs \"Separate speakers\" on. Lines it guesses are shown dimmed as voice-inferred.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
    }

    @ViewBuilder private var connectionsCategory: some View {
        let p = model.palette
        Card(title: "Live traffic") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.adsbStreamingEnabled) {
                    Text("Online ADS-B streaming").font(.caption).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("adsb-toggle")
                Text("Streams nearby aircraft (within ~30 NM of your position) from a public ADS-B feed and draws them on the map — and helps the AI fixer lock a misheard callsign onto a plane actually on frequency. Runs whenever it's on and the app is open (no transcription needed); needs a network connection; off by default. If a Stratux receiver is connected, its on-board traffic is used instead. You can also toggle this from the map's Layers menu. Live data only — stale contacts are dropped.")
                    .font(.caption2).foregroundStyle(p.textDim)
                Text(ADSBService.attribution)
                    .font(.caption2).foregroundStyle(p.textDim.opacity(0.8))
            }
        }
        Card(title: "Stratux receiver") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.stratuxEnabled) {
                    Text("Stratux link").font(.caption).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("stratux-enable")
                Text("Connect to a Stratux ADS-B/GPS receiver over its Wi-Fi for cockpit audio plus on-board traffic and GPS — no internet needed in flight. Turn the Stratux link on (here or in the Stratux bar on the console) to stream traffic + GPS; pick “Stratux receiver” as the input source to transcribe its audio.")
                    .font(.caption2).foregroundStyle(p.textDim)
                HStack(spacing: 10) {
                    Text("Address").font(.caption).foregroundStyle(p.textDim)
                        .frame(width: 84, alignment: .leading)
                    TextField("192.168.10.1", text: $model.stratuxHost)
                        .textFieldStyle(.plain).autocorrectionDisabled()
                        .textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
                        .accessibilityIdentifier("stratux-host")
                }
                HStack(spacing: 10) {
                    Text("Audio port").font(.caption).foregroundStyle(p.textDim)
                        .frame(width: 84, alignment: .leading)
                    TextField("8090", value: $model.stratuxAudioPort, format: .number.grouping(.never))
                        .textFieldStyle(.plain).keyboardType(.numberPad).font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
                        .frame(maxWidth: 120)
                    Spacer(minLength: 0)
                }
                Text("Traffic + GPS use the receiver's web API on \(model.stratuxHost); cockpit audio streams from the sidecar on port \(String(model.stratuxAudioPort)) at /audio.raw. Set the sidecar up with the guide in Tools/stratux. iOS will ask once for permission to find devices on your local network.")
                    .font(.caption2).foregroundStyle(p.textDim)
                Text(StratuxService.attribution).font(.caption2).foregroundStyle(p.textDim.opacity(0.8))
            }
        }
        Card(title: "ForeFlight") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.foreflightEnabled) {
                    Text("ForeFlight hand-off").font(.caption).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("foreflight-toggle")
                Text("Offer to load amended flight plans into ForeFlight — an “Accept ➔ ForeFlight” button on clearance suggestions and a send button in the flight bag. App-to-app on this device, so it works offline (no cell or internet needed). Loaded departures and arrivals are sent as their individual fixes; approaches are not sent (load those in ForeFlight itself). Review the route in ForeFlight before using it.")
                    .font(.caption2).foregroundStyle(p.textDim)
                if !model.foreflightInstalled {
                    Text("ForeFlight isn't installed on this device — the buttons stay hidden until it is.")
                        .font(.caption2).foregroundStyle(p.textDim.opacity(0.8))
                }
            }
        }
    }

    @ViewBuilder private var generalCategory: some View {
        let p = model.palette
        Card(title: "Display") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.showDebug) {
                    Text("Show performance data").font(.caption).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("show-debug-toggle")
                Text("Shows the per-transmission speed and latency (RTF) next to each line, color-coded green / amber / red as the device keeps up or falls behind. Off by default. The Latency widget can also be added to the sidebar by long-pressing it.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
        #if canImport(MapLibre)
        Card(title: "Map engine") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.useMapLibreMap) {
                    Text("New GPU map (MapLibre)").font(.caption).foregroundStyle(p.text)
                }
                .tint(model.palette.accent)
                .accessibilityIdentifier("maplibre-engine-toggle")
                Text("On (default): the new MapLibre GPU/globe chart engine. Off: the classic map — a fallback that also carries a few features not yet on the new engine (procedure preview line, hazard/smoke overlays, the full-screen Route map). Both render your offline FAA charts + route + airspace + traffic + plates.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
        #endif
        Card(title: "Battery") {
            NavigationLink {
                BatteryDiagnosticsView().environmentObject(model)
            } label: {
                HStack {
                    Label("Battery diagnostics", systemImage: "battery.100.bolt")
                        .font(.caption).foregroundStyle(p.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                }
            }
            .accessibilityIdentifier("settings-battery-diag")
        }
        Card(title: "About") {
            VStack(alignment: .leading, spacing: 10) {
                KV("Version", "\(WhatsNew.currentVersion()) (build \(WhatsNew.currentBuild()))")
                    .contentShape(Rectangle())
                    .onTapGesture { revealTestBenchAfterSevenTaps() }
                    .accessibilityIdentifier("settings-version")
                // Buried developer test bench — revealed only after 7 deliberate taps on the
                // version, because it edits flight data. Hidden again is impossible by design
                // (persisted), but it never surfaces to a user who hasn't gone looking.
                if model.diagnosticsEnabled {
                    NavigationLink {
                        ClearanceTestBenchView().environmentObject(model)
                    } label: {
                        HStack {
                            Label("Clearance test bench", systemImage: "airplane.circle")
                                .font(.caption).foregroundStyle(p.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                        }
                    }
                    .accessibilityIdentifier("settings-test-bench")
                }
                NavigationLink {
                    ScrollView {
                        WhatsNewContent(entries: WhatsNew.releaseNotes)
                            .environmentObject(model)
                            .padding(16)
                    }
                    .background(p.bg)
                    .navigationTitle("What’s new")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Label("What’s new in CommSight", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(p.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
                    }
                }
                .accessibilityIdentifier("settings-whats-new")
                Text("See what changed in recent builds. The “What’s new” popup also appears once, automatically, after each update.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
    }

    /// Count taps on the version row; the 7th unlocks the clearance test bench (with a firm haptic).
    /// Once unlocked it stays available — but a user who never taps 7 times never sees it.
    private func revealTestBenchAfterSevenTaps() {
        guard !model.diagnosticsEnabled else { return }
        versionTaps += 1
        if versionTaps >= 7 {
            model.diagnosticsEnabled = true
            Haptics.impact(.rigid)
        }
    }

    private func modelButton(_ id: String, _ label: String) -> some View {
        let p = model.palette
        let available = model.modelDownloaded(id)
        let isLoading = model.loadingModel == id
        // While a swap loads, highlight the model being loaded (optimistic) so the tap is reflected
        // instantly; otherwise highlight the model that's actually active.
        let isActive = isLoading || (model.loadingModel == nil && model.activeModel == id)
        return Button { model.switchModel(id) } label: {
            HStack(spacing: 6) {
                if isLoading { ProgressView().controlSize(.small).tint(p.bg) }
                Text(available ? (isLoading ? "\(label) — loading…" : label) : "\(label) — not downloaded")
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(isActive ? p.accent : p.surfaceAlt)
            .foregroundStyle(isActive ? p.bg : p.text)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plainHaptic)
        // Any in-flight compile locks the WHOLE picker: WhisperKit/CoreML compiles are heavy and
        // non-interruptible, and stacking picks mid-compile risked two multi-GB models resident at
        // once (OOM kill). This never wedges — `loadingModel` is cleared by the 30 s swap watchdog,
        // the 60 s initial-load watchdog, both load-task completions, and cancelModelLoad — so the
        // picker unlocks on its own even if a compile stalls. See AppModel.switchModel (task
        // chaining) for the in-code serialization this backs up.
        .disabled(!available || model.loadingModel != nil)
        .opacity(available ? 1 : 0.5)
    }

    private func backendButton(_ b: LLMBackend, _ label: String) -> some View {
        let p = model.palette
        return Button { model.llmBackend = b } label: {
            Text(label).font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(model.llmBackend == b ? p.accent : p.surfaceAlt)
                .foregroundStyle(model.llmBackend == b ? p.bg : p.text)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plainHaptic)
    }

    private func sensitivityButton(_ s: GateSensitivity, _ label: String) -> some View {
        let p = model.palette
        return Button { model.gateSensitivity = s } label: {
            Text(label).font(.caption2.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(model.gateSensitivity == s ? p.accent : p.surfaceAlt)
                .foregroundStyle(model.gateSensitivity == s ? p.bg : p.text)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plainHaptic)
    }
}
