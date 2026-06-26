import SwiftUI

/// First-launch gate: when no Whisper model is present (not bundled, not yet downloaded) the app
/// shows this full-screen step so testers can't miss it. It downloads the **required** model with
/// a live progress bar, confirms with a green checkmark, then unlocks the console. A secondary
/// "Skip" keeps today's demo-mode fallback for anyone who wants to look around first.
struct OnboardingDownloadView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager

    private var entry: ModelEntry { ModelCatalog.required }
    private var state: DownloadState { downloads.state(entry.id) }
    private var isReady: Bool { if case .ready = state { return true } else { return false } }

    var body: some View {
        let p = model.palette
        ZStack {
            p.bg.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                VStack(spacing: 10) {
                    Text("ATC")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(p.accent).foregroundStyle(p.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("ATC_Transcribe").font(.title2.weight(.bold)).foregroundStyle(p.text)
                    Text("On-device ATC transcription runs a speech model that lives on your device. Download it once to get started — it stays offline afterward.")
                        .font(.subheadline).foregroundStyle(p.textDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }

                ModelDownloadRow(entry: entry).padding(.horizontal, 4)

                VStack(spacing: 10) {
                    Button {
                        if isReady { model.finishOnboarding() } else { downloads.download(entry) }
                    } label: {
                        Text(primaryLabel)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(primaryEnabled ? p.accent : p.surfaceAlt)
                            .foregroundStyle(primaryEnabled ? p.bg : p.textDim)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!primaryEnabled)
                    .accessibilityIdentifier("gate-primary")

                    Button("Skip — explore with demo data") { model.finishOnboarding() }
                        .font(.caption).foregroundStyle(p.textDim)
                        .accessibilityIdentifier("gate-skip")
                }
                .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: 460)
            .padding(20)
        }
        .preferredColorScheme(model.theme == .day ? .light : .dark)
    }

    private var primaryLabel: String {
        switch state {
        case .ready: return "Continue"
        case .downloading: return "Downloading…"
        case .failed: return "Retry download"
        case .notDownloaded: return "Download model (\(entry.sizeLabel))"
        }
    }

    private var primaryEnabled: Bool {
        if case .downloading = state { return false }
        return true
    }
}

/// Reusable row showing one model's name/size and a status-driven control: a Download button →
/// a progress bar with percentage → a green "Ready ✓" confirmation. Used by both the onboarding
/// gate and the Settings model manager.
struct ModelDownloadRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    let entry: ModelEntry

    private var state: DownloadState { downloads.state(entry.id) }

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(p.text)
                    Text("\(entry.sizeLabel) · \(entry.detail)")
                        .font(.caption2).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing(p)
            }
            if case .downloading(let f) = state {
                HStack(spacing: 8) {
                    ProgressView(value: f).tint(p.accent)
                    Text("\(Int(f * 100))%")
                        .font(.caption2.monospaced()).foregroundStyle(p.textDim)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            if case .failed(let msg) = state {
                Text(msg).font(.caption2).foregroundStyle(p.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(p.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
    }

    @ViewBuilder private func trailing(_ p: Palette) -> some View {
        switch state {
        case .ready:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text("Ready").font(.caption.weight(.semibold))
            }
            .foregroundStyle(p.good)
        case .downloading:
            Button("Cancel") { downloads.cancel(entry) }
                .font(.caption.weight(.semibold)).foregroundStyle(p.bad)
                .buttonStyle(.plain)
        case .notDownloaded, .failed:
            Button { downloads.download(entry) } label: {
                Text(entry.required ? "Download" : "Get")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(p.accent).foregroundStyle(p.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}
