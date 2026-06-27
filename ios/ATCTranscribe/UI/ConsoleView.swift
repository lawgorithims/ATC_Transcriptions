import SwiftUI

/// The live console — a SwiftUI port of the browser UI (`server/static/*`): brand +
/// status pills, a source/controls bar, the live transcript, and a latency/host
/// sidebar. Adapts to a 2-column layout on iPad (regular width) and a stacked scroll
/// on iPhone (compact).
struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let p = model.palette
        ZStack {
            p.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
                StatusBar()
                ControlsBar()
                hairline
                mainArea
            }
            // Standby dims + disables the console (transcript stays readable) rather than covering
            // it, and floats a Resume control on top.
            .opacity(model.standby ? 0.35 : 1)
            .disabled(model.standby)
            .animation(.easeInOut(duration: 0.2), value: model.standby)
            if model.standby { StandbyBanner().environmentObject(model) }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet().environmentObject(model).environmentObject(downloads)
        }
        .fullScreenCover(isPresented: $model.needsOnboarding) {
            OnboardingDownloadView().environmentObject(model).environmentObject(downloads)
        }
        .animation(.easeInOut(duration: 0.25), value: model.theme)
        .onAppear {
            // Bridge a finished download back to the model so it can load a model that wasn't
            // present at launch (lean TestFlight build → first-run download → live console).
            downloads.onReady = { entry in model.modelDidDownload(entry) }
        }
    }

    private var hairline: some View { Rectangle().fill(model.palette.border).frame(height: 1) }

    @ViewBuilder private var mainArea: some View {
        if hSize == .regular {
            HStack(alignment: .top, spacing: 14) {
                TranscriptCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                SidebarColumn().frame(width: 300)
            }
            .padding(14)
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    TranscriptCard().frame(minHeight: 360)
                    SidebarColumn()
                }
                .padding(14)
            }
        }
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
            Button { model.enterStandby() } label: {
                Image(systemName: "moon.fill").font(.system(size: 16))
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

// MARK: - Status strip (pills + badges)

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusPill(label: "Proof of life",
                           state: model.proofOfLife == nil ? .idle : (model.proofOfLife?.passed == true ? .good : .bad))
                StatusPill(label: "Stream", state: streamState)
                Badge(text: "device · \(model.deviceLabel)")
                Badge(text: "model · \(model.activeModel)")
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

// MARK: - Controls

struct ControlsBar: View {
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
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))

                Spacer(minLength: 0)

                if model.isRunning { InputLevelMeter() }

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

            HStack {
                Text(model.detail).font(.caption).foregroundStyle(p.textDim)
                Spacer()
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
                    Image(systemName: "moon.zzz.fill").foregroundStyle(p.accent)
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
            .padding(.bottom, 36)
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
        .accessibilityIdentifier("input-level-meter")
        .accessibilityLabel("Input level")
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
