import SwiftUI

/// The "What's new" popup — shown once after the app updates to a newer build (see
/// `AppModel.evaluateWhatsNew`), and re-openable from Settings → About. It lists each new build's
/// features in plain English so a tester (or any user) knows what changed and what to try.
struct WhatsNewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header(p)
                    WhatsNewContent(entries: model.whatsNewEntries)
                }
                .padding(16)
                .padding(.bottom, 8)
            }
            .background(p.bg)
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("Got it")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(p.accent).foregroundStyle(p.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plainHaptic)
                .padding(.horizontal, 16).padding(.bottom, 10)
                .accessibilityIdentifier("whats-new-dismiss")
            }
            .navigationTitle("What’s new")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .accessibilityIdentifier("whats-new-sheet")
        // Record the running build as "seen" however the sheet is dismissed (button or swipe), so the
        // popup doesn't reappear until the next update (a `--whats-new` preview is exempted inside).
        .onDisappear { model.whatsNewDismissed() }
    }

    private func header(_ p: Palette) -> some View {
        VStack(spacing: 8) {
            Image("BrandMark")
                .resizable().scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("What’s new in CommSight").font(.title3.weight(.bold)).foregroundStyle(p.text)
                .multilineTextAlignment(.center)
            Text("Version \(WhatsNew.currentVersion()) · build \(WhatsNew.currentBuild())")
                .font(.caption.monospaced()).foregroundStyle(p.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

/// The scrollable list of release notes — shared by the popup sheet and the Settings → About
/// "What's new" screen (which pushes it as a NavigationLink so there's no sheet-over-sheet).
struct WhatsNewContent: View {
    @EnvironmentObject var model: AppModel
    let entries: [ReleaseNote]

    var body: some View {
        let p = model.palette
        VStack(spacing: 18) {
            if entries.isEmpty {
                Text("You’re on the latest version. Check back after the next update.")
                    .font(.callout).foregroundStyle(p.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(entries) { note in
                    releaseCard(note, p)
                }
            }
        }
    }

    private func releaseCard(_ note: ReleaseNote, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(note.headline).font(.headline).foregroundStyle(p.text)
                Spacer(minLength: 4)
                Text("build \(note.build)")
                    .font(.caption2.monospaced()).foregroundStyle(p.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(p.surfaceAlt).clipShape(Capsule())
            }
            ForEach(note.highlights) { h in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: h.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(p.accent)
                        .frame(width: 26, height: 26)
                        .background(p.accent.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.text)
                        Text(h.detail).font(.caption).foregroundStyle(p.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
    }
}
