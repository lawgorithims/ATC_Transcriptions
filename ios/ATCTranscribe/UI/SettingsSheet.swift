import SwiftUI

/// Model & settings sheet — port of the browser console's settings modal: pick the
/// transcription model, tune correction, and manage downloads.
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
                    Card(title: "Display") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $model.showDebug) {
                                Text("Show performance data").font(.caption).foregroundStyle(p.text)
                            }
                            Text("Shows the per-transmission speed and latency (RTF) next to each line, color-coded green / amber / red as the device keeps up or falls behind. Off by default. The Latency widget can also be added to the sidebar by long-pressing it.")
                                .font(.caption2).foregroundStyle(p.textDim)
                        }
                    }
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
                    Card(title: "Live traffic") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $model.adsbStreamingEnabled) {
                                Text("Online ADS-B streaming").font(.caption).foregroundStyle(p.text)
                            }
                            .accessibilityIdentifier("adsb-toggle")
                            Text("Fetches aircraft within 30 NM of the airport from a public ADS-B feed so the AI fixer can lock a misheard callsign onto a plane actually on frequency. Needs a network connection and an airport; only runs while transcribing; off by default. Live data only — stale contacts are dropped and never used.")
                                .font(.caption2).foregroundStyle(p.textDim)
                            Text(ADSBService.attribution)
                                .font(.caption2).foregroundStyle(p.textDim.opacity(0.8))
                        }
                    }
                    Card(title: "Offline charts") {
                        OfflineChartsControls()
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
                                Label(model.remoteFixerURLValid ? "Cloud second-pass enabled" : "Not a valid http(s) URL — ignored",
                                      systemImage: model.remoteFixerURLValid ? "checkmark.circle" : "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(model.remoteFixerURLValid ? p.accent : p.textDim)
                            }
                            Text("Optional. When set, the on-device fixer runs first, then a larger model at this URL gets a second pass within the same 2–3 second budget (abandoned if slow). It sees the same grounded ATC context and passes the identical safety guardrails — it can never change a number, runway, or direction the on-device model preserved. Leave blank to stay fully on-device.")
                                .font(.caption2).foregroundStyle(p.textDim)
                                .opacity(model.correctionEnabled ? 1 : 0.5)
                        }
                    }
                    Card(title: "About") {
                        VStack(alignment: .leading, spacing: 10) {
                            KV("Version", "\(WhatsNew.currentVersion()) (build \(WhatsNew.currentBuild()))")
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
                .padding(16)
            }
            .background(p.bg)
            .navigationTitle("Model & settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
    }
}
