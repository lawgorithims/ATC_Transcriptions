import SwiftUI

/// First-launch gate: when no Whisper model is present (not bundled, not yet downloaded) the app
/// shows this full-screen step so testers can't miss it. It downloads the **required** model with
/// a live progress bar, confirms with a green checkmark, then unlocks the console. A secondary
/// "Skip" keeps today's demo-mode fallback for anyone who wants to look around first.
struct OnboardingDownloadView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager

    private var entry: ModelEntry { ModelCatalog.required }
    /// Any speech model present is enough to enter the console — not just the required Small — so a
    /// user who grabbed only the Large / Large V2 model can Continue instead of being forced to also
    /// download Small (or Skip). Checks both the live download state and what's already on disk.
    private func isDownloaded(_ e: ModelEntry) -> Bool {
        if case .ready = downloads.state(e.id) { return true }
        return ModelStore.isReady(e)
    }
    private var isReady: Bool { ModelCatalog.whisperEntries.contains(where: isDownloaded) }

    var body: some View {
        let p = model.palette
        ZStack {
            p.bg.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                VStack(spacing: 10) {
                    Image("BrandMark")
                        .resizable().scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Text("CommSight").font(.title2.weight(.bold)).foregroundStyle(p.text)
                    Text("On-device air-traffic-control transcription runs a speech model that lives on your device. Download it once to get started — it stays offline afterward.")
                        .font(.subheadline).foregroundStyle(p.textDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }

                VStack(spacing: 10) {
                    ModelDownloadRow(entry: entry)
                    // Optional higher-accuracy model — offered up front so testers can grab it
                    // without digging into Settings. Not required to continue.
                    ModelDownloadRow(entry: ModelCatalog.turbo)
                    // Optional stock (non-fine-tuned) model for real-world A/B comparison. Offered
                    // here for testers but kept OUT of "Download recommended" (large, niche), so the
                    // first-launch bulk action stays lean — grabbed via its own row button.
                    ModelDownloadRow(entry: ModelCatalog.cleanturbo)
                    // The AI context fixer ships alongside whichever speech model is downloaded, so
                    // correction works out of the box. Shown here for transparency; not required.
                    ModelDownloadRow(entry: ModelCatalog.llm)
                    Text("Optional speech models: Large is higher accuracy; Large V2 is the stock OpenAI model, offered for accuracy comparison. The AI context fixer installs automatically with the speech model. Download recommended grabs the required model, Large, and the fixer — add Large V2 from its own button. You can manage all of these later in Settings.")
                        .font(.caption2).foregroundStyle(p.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    Button {
                        if isReady { model.finishOnboarding() }
                        else { allEntries.forEach { downloads.download($0) } }
                    } label: {
                        Text(primaryLabel)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(primaryEnabled ? p.accent : p.surfaceAlt)
                            .foregroundStyle(primaryEnabled ? p.bg : p.textDim)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plainHaptic)
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

    /// The "recommended" artifacts the big button grabs in bulk — the required model, the
    /// higher-accuracy fine-tuned model, and the AI fixer (so correction works on the first run).
    /// The optional stock "Large V2" is deliberately excluded (large, niche; grabbed from its own
    /// row). Each row can still grab one on its own. The Continue gate keys off the required speech
    /// model only (`isReady`), so any other download in flight never blocks entry.
    private var allEntries: [ModelEntry] { [ModelCatalog.small, ModelCatalog.turbo, ModelCatalog.llm] }

    private var anyDownloading: Bool {
        allEntries.contains { if case .downloading = downloads.state($0.id) { return true } else { return false } }
    }

    private var allSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: allEntries.reduce(0) { $0 + $1.approxBytes }, countStyle: .file)
    }

    private var primaryLabel: String {
        if isReady { return "Continue" }               // required model present → unlock the console
        if anyDownloading { return "Downloading…" }
        return "Download recommended (\(allSizeLabel))"
    }

    /// Allow Continue as soon as the required model is ready, even while the larger one downloads.
    private var primaryEnabled: Bool { isReady || !anyDownloading }
}

/// Reusable row showing one model's name/size and a status-driven control: a Download button →
/// a progress bar with percentage → a green "Ready ✓" confirmation. Used by both the onboarding
/// gate and the Settings model manager.
struct ModelDownloadRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: ModelDownloadManager
    let entry: ModelEntry

    private var state: DownloadState { downloads.state(entry.id) }

    /// True when this model ships inside the app (bundled) — it shows "Built in" and has no download,
    /// re-download, or delete controls (you can't remove a model baked into the signed app bundle).
    private var isBundled: Bool {
        switch entry.kind {
        case .whisperKit: return entry.id == ModelCatalog.required.id && AppModel.bundledModelDir() != nil
        case .ggufFile:   return bundledLLMModelPath() != nil
        }
    }

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
        if isBundled {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                Text("Built in").font(.caption.weight(.semibold))
            }
            .foregroundStyle(p.good)
        } else {
            switch state {
            case .ready:
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Ready").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(p.good)
                    // Recover a corrupt/partial download without leaving Settings.
                    Menu {
                        Button { downloads.redownload(entry) } label: { Label("Re-download", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { downloads.delete(entry) } label: { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.callout).foregroundStyle(p.textDim)
                    }
                    .accessibilityIdentifier("model-manage-\(entry.id)")
                }
            case .downloading:
                Button("Cancel") { downloads.cancel(entry) }
                    .font(.caption.weight(.semibold)).foregroundStyle(p.bad)
                    .buttonStyle(.plainHaptic)
            case .notDownloaded, .failed:
                Button { downloads.download(entry) } label: {
                    Text("Download")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(p.accent).foregroundStyle(p.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plainHaptic)
            }
        }
    }
}
