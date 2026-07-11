import SwiftUI

/// The live transcript card: each transmission with its timestamp, stream offset,
/// latency, and any correction edits. Order is user-selectable (newest at bottom — the default,
/// auto-scrolled down — or newest at top); a jump-to-newest button snaps to the latest line.
struct TranscriptCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.floatingSurface) private var floating   // true when hosted in a FloatingWidgetContainer
    /// True while the user is pinned to the newest end (so we follow new transmissions); false once
    /// they scroll into history (auto-scroll pauses, the jump-to-newest button appears).
    @State private var atNewest = true
    /// Drives the squelch popover from the input-level meter, which now lives in this always-visible
    /// header (moved out of the old controls bar) so proof-of-audio survives collapsing the strips.
    @State private var showSquelch = false

    /// Records in display order: filtered to one aircraft's conversation when a callsign filter is
    /// active, then reversed (newest first) when the user prefers it.
    private var orderedRecords: [TranscriptRecord] {
        let base = model.callsignFilter.map { f in model.records.filter { $0.callsign == f } } ?? model.records
        return model.transcriptNewestFirst ? Array(base.reversed()) : base
    }

    /// The id of the currently-newest RENDERED line (top in newest-first mode, else bottom) — the
    /// auto-follow trigger, so it ignores the 500-record cap and off-filter arrivals.
    private var newestRenderedID: TranscriptRecord.ID? {
        model.transcriptNewestFirst ? orderedRecords.first?.id : orderedRecords.last?.id
    }

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Transcript").font(.headline).foregroundStyle(p.text)
                Spacer(minLength: 4)
                Text(model.sourceLabel).font(.caption).foregroundStyle(p.textDim).lineLimit(1)
                // Live run status, moved here from the old controls bar so it stays visible no matter
                // which heading-bar strips are open: the "Transcribing…" pulse and the input-level
                // meter (tap → squelch). Both appear only during a live session.
                if model.transcribing { TranscribingIndicator() }
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
                Button { model.transcriptNewestFirst.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: model.transcriptNewestFirst ? "arrow.up" : "arrow.down")
                        Text("Newest")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(p.textDim)
                .accessibilityIdentifier("transcript-sort")
                .accessibilityLabel(model.transcriptNewestFirst ? "Newest first" : "Newest last")
                // When the sidebar is empty it's hidden (transcript fills the width), so offer the
                // widget re-add menu here — the only entry point back to the widgets in that state.
                if model.widgets.isEmpty {
                    Menu {
                        ForEach(model.availableWidgets) { w in
                            Button { withAnimation { model.addWidget(w) } } label: {
                                Label(w.title, systemImage: w.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(p.textDim)
                    .accessibilityIdentifier("transcript-add-widget")
                    .accessibilityLabel("Add widget")
                }
                Button("Clear") { model.clear() }
                    .font(.caption).foregroundStyle(p.textDim).buttonStyle(.plain)
            }
            .padding(14)
            Rectangle().fill(p.border).frame(height: 1)

            if let cs = model.callsignFilter {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.caption)
                    Text("Showing ").font(.caption).foregroundStyle(p.textDim)
                        + Text(cs).font(.caption.weight(.semibold)).foregroundStyle(p.text)
                        + Text("  ·  \(orderedRecords.count) msg\(orderedRecords.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(p.textDim)
                    Spacer(minLength: 4)
                    Button("Clear") { model.callsignFilter = nil }
                        .font(.caption.weight(.semibold)).foregroundStyle(p.accent).buttonStyle(.plain)
                        .accessibilityIdentifier("callsign-filter-clear")
                }
                .foregroundStyle(p.accent)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(p.accent.opacity(0.10))
                Rectangle().fill(p.border).frame(height: 1)
            }

            if model.records.isEmpty {
                if model.loadingModel != nil { ModelLoadingView() }   // initial model load in progress
                else { emptyState }
            } else if orderedRecords.isEmpty {
                filteredEmptyState                         // an active filter with zero matches
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            newestMarker(isTop: true)
                            ForEach(orderedRecords) { TranscriptRow(record: $0) }
                            newestMarker(isTop: false)
                        }
                    }
                    // Follow new transmissions only while pinned to the newest end. Drive off the
                    // RENDERED newest line's id (not records.count, which a 500-cap pins and which an
                    // off-filter arrival jolts), so it fires exactly when the visible newest changes.
                    .onChange(of: newestRenderedID) { _, _ in if atNewest { scrollToNewest(proxy) } }
                    .onChange(of: model.transcriptNewestFirst) { _, _ in atNewest = true; scrollToNewest(proxy) }
                    .onChange(of: model.callsignFilter) { _, _ in atNewest = true; scrollToNewest(proxy) }
                    .overlay(alignment: model.transcriptNewestFirst ? .topTrailing : .bottomTrailing) {
                        if !atNewest { jumpButton(proxy) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        // When floating over the map, the container owns the (opacity-adjustable) background.
        .background(floating ? Color.clear : p.surface)
        .clipShape(RoundedRectangle(cornerRadius: floating ? 0 : 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: floating ? 0 : 1))
    }

    /// A 1pt scroll anchor at one end of the list. The marker at the *newest* end (top when
    /// newest-first, else bottom) drives `atNewest`: on screen → the user is following the latest
    /// line; scrolled off → they're reading history, so auto-scroll pauses and the jump button shows.
    @ViewBuilder private func newestMarker(isTop: Bool) -> some View {
        Color.clear.frame(height: 1).id(isTop ? "top" : "bottom")
            .onAppear { if isTop == model.transcriptNewestFirst { atNewest = true } }
            .onDisappear { if isTop == model.transcriptNewestFirst { atNewest = false } }
    }

    /// Scroll to whichever end holds the newest transmission (top when newest-first, else bottom).
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        let newestIsTop = model.transcriptNewestFirst
        withAnimation { proxy.scrollTo(newestIsTop ? "top" : "bottom", anchor: newestIsTop ? .top : .bottom) }
    }

    /// Floating button that snaps to the newest line — only shown while scrolled into history, and
    /// pinned by the end where the newest line lives.
    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        let p = model.palette
        return Button { atNewest = true; scrollToNewest(proxy) } label: {
            Image(systemName: model.transcriptNewestFirst ? "arrow.up.to.line" : "arrow.down.to.line")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(p.accent).foregroundStyle(p.bg)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityIdentifier("transcript-jump-newest")
        .accessibilityLabel("Jump to newest")
    }

    private var emptyState: some View {
        let p = model.palette
        return VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34)).foregroundStyle(p.textDim.opacity(0.7))
            Text("No transmissions yet.").foregroundStyle(p.textDim)
            Text("Pick a source above and press Start.")
                .font(.caption).foregroundStyle(p.textDim.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    /// Shown when a callsign filter is active but no transmission matches it (e.g. after switching
    /// feeds) — so the user sees why the list is empty instead of a blank box.
    private var filteredEmptyState: some View {
        let p = model.palette
        return VStack(spacing: 10) {
            Image(systemName: "airplane.circle").font(.system(size: 30)).foregroundStyle(p.textDim.opacity(0.7))
            Text("No messages for \(model.callsignFilter ?? "this aircraft") yet.").foregroundStyle(p.textDim)
            Button("Clear filter") { model.callsignFilter = nil }
                .font(.caption.weight(.semibold)).foregroundStyle(p.accent).buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

struct TranscriptRow: View {
    @EnvironmentObject var model: AppModel
    let record: TranscriptRecord

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    // ONE fused speaker label per line (the runtime `speaker_label`), mirroring the
                    // website: "ATC" (→ addressed aircraft) for a controller, the callsign for a
                    // pilot, a muted "Pilot" when the role is known but no callsign was recovered,
                    // and nothing when we honestly don't know.
                    fusedSpeakerChip(p)
                    // The raw acoustic cluster id is now a fusion INPUT, not the answer — keep the
                    // colored "S1/S2" chip for developers only.
                    if model.showDebug, let spk = record.speaker {
                        Text("S\(spk + 1)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(speakerColor(spk).opacity(0.22))
                            .foregroundStyle(speakerColor(spk))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(speakerColor(spk).opacity(0.5), lineWidth: 1))
                            .accessibilityIdentifier("speaker-chip")
                    }
                    if let cs = record.callsign {
                        // For an ATC line the callsign is the ADDRESSED aircraft — draw the site's
                        // "tower → callsign" connector. For a pilot line it stands alone as the speaker.
                        if case .atc = record.speakerLabel {
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(p.textDim)
                        }
                        // Tap to filter the transcript to this aircraft's conversation. Green +
                        // filled-airplane = currently in range on the live ADS-B feed — derived at
                        // render time so the badge tracks the feed instead of freezing at decode time.
                        let inRange = record.callsignKey.map { model.inRangeCallsignKeys.contains($0.uppercased()) } ?? false
                        let color = inRange ? p.good : p.accent
                        let on = model.callsignFilter == cs
                        Button { model.toggleCallsignFilter(cs) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: inRange ? "airplane.circle.fill" : "airplane")
                                    .font(.system(size: 8))
                                Text(cs).font(.caption2.weight(.bold))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(on ? color : color.opacity(0.18))
                            .foregroundStyle(on ? p.bg : color)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("callsign-chip")
                    }
                    Text(record.timestamp).font(.caption2.monospaced()).foregroundStyle(p.accent)
                    Text(String(format: "stream %.1fs", record.streamStartS))
                        .font(.caption2.monospaced()).foregroundStyle(p.textDim)
                    Spacer()
                    if model.showDebug {
                        let speed = record.realTimeFactor > 0 ? 1.0 / record.realTimeFactor : 0
                        (Text(String(format: "%.0f ms · ", record.transcribeMs)).foregroundStyle(p.textDim)
                            + Text(speedLabel(record.realTimeFactor)).foregroundStyle(p.speedColor(realtime: speed)))
                            .font(.caption2.monospaced())
                    }
                }
                // Corrected words are tinted amber inline so they stand out at a glance. Highlight
                // only the tier actually shown: the LLM's edits when the LLM-refined text is on
                // screen, otherwise the inline corrector's.
                Text(highlighted(record.normalizedDisplay,
                                 edits: record.llmCorrected.isEmpty ? record.corrections : record.llmEdits,
                                 color: p.warn))
                    .font(.callout).foregroundStyle(p.text)
                    .textSelection(.enabled)
                refinementStatus(p)
                if !record.allEdits.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.caption2)
                        Text(record.allEdits.map { "\($0.from) → \($0.to)" }.joined(separator: ",  "))
                            .font(.caption2)
                    }
                    .foregroundStyle(p.warn)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(p.border.opacity(0.6)).frame(height: 1)
        }
    }

    /// The AI-fixer status line under the transcript: a live "running…" spinner, then the
    /// outcome with how long the AI fixer actually took (its real-time cost, on screen).
    @ViewBuilder private func refinementStatus(_ p: Palette) -> some View {
        let ms = String(format: "%.0f ms", record.llmMs)
        switch record.refinementState {
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("AI fixer running…").font(.caption2)
            }
            .foregroundStyle(p.textDim)
        case .refined:
            statusLine("wand.and.stars", "AI fixed · \(ms)", p.warn)
        case .clean:
            statusLine("checkmark.seal", "AI checked · \(ms)", p.textDim)
        case .skippedConfident:
            statusLine("checkmark.seal", "high confidence", p.textDim)
        case .none, .skipped:
            EmptyView()
        }
    }

    private func statusLine(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2)
            Text(text).font(.caption2)
        }
        .foregroundStyle(color)
    }

    /// Per-transmission speed as a human-friendly multiple of real time (inverse of RTF).
    private func speedLabel(_ rtf: Double) -> String {
        guard rtf > 0 else { return "—" }
        return String(format: "%.1f× real-time", 1.0 / rtf)
    }

    /// Build an attributed transcript where each correction's replacement (`to`) is tinted, so
    /// corrected words pop inline. Plain text when there are no edits.
    private func highlighted(_ text: String, edits: [CorrectionEdit], color: Color) -> AttributedString {
        var attr = AttributedString(text)
        let targets = Set(edits.map(\.to).filter { !$0.isEmpty })
        for target in targets {
            var idx = attr.startIndex
            while idx < attr.endIndex, let r = attr[idx...].range(of: target) {
                idx = r.upperBound
                // Whole-token only: skip a match glued to an alphanumeric on either side, so a
                // replacement like "9" doesn't tint inside "390" and "left" not inside "leftover".
                let chars = attr.characters
                let before = r.lowerBound == attr.startIndex ? nil : chars[chars.index(before: r.lowerBound)]
                let after = r.upperBound == attr.endIndex ? nil : chars[r.upperBound]
                if (before.map(isAlnum) ?? false) || (after.map(isAlnum) ?? false) { continue }
                attr[r].foregroundColor = color
                attr[r].font = .callout.weight(.semibold)
            }
        }
        return attr
    }

    private func isAlnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// The single fused speaker label for this line. Controller → "ATC"; pilot-with-callsign renders
    /// as the callsign chip alone (so this returns nothing); pilot-without-callsign → a muted "Pilot";
    /// unknown → nothing (honest — we don't guess). A voice-inferred ATC label (filled from the
    /// acoustic cluster, `fusedFrom == .acoustic`) is drawn deliberately lower-confidence: outline
    /// only, dimmed, with a waveform glyph — never presented as certain.
    @ViewBuilder private func fusedSpeakerChip(_ p: Palette) -> some View {
        switch record.speakerLabel {
        case .atc:
            let inferred = record.fusedFrom == .acoustic
            HStack(spacing: 3) {
                Image(systemName: inferred ? "waveform" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 8))
                Text("ATC").font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(inferred ? Color.clear : p.accent.opacity(0.18))
            .foregroundStyle(inferred ? p.accent.opacity(0.7) : p.accent)
            .clipShape(Capsule())
            .overlay { if inferred { Capsule().stroke(p.accent.opacity(0.5), lineWidth: 1) } }
            .accessibilityIdentifier("fused-label-chip")
            .accessibilityLabel(inferred ? "ATC, inferred from voice" : "ATC")
        case .pilot:
            Label("Pilot", systemImage: "airplane")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(p.good.opacity(0.18))
                .foregroundStyle(p.good)
                .clipShape(Capsule())
                .accessibilityIdentifier("fused-label-chip")
                .accessibilityLabel("Pilot")
        case .callsign, .unknown:
            EmptyView()
        }
    }

    /// Distinct color per diarization speaker id (cycles for many speakers).
    private func speakerColor(_ i: Int) -> Color {
        let colors: [Color] = [.hex(0x3B9EFF), .hex(0x2EE6A6), .hex(0xF5C451),
                               .hex(0xC58CFF), .hex(0xFF8FB1), .hex(0x5AD1E6)]
        return colors[((i % colors.count) + colors.count) % colors.count]
    }
}

/// Shown in the transcript area while the speech model loads (initial load). A big model can take a
/// while the first time CoreML compiles it for this device, so this gives live feedback — the model
/// being loaded, an elapsed timer (so it reads as progressing, not frozen), and the device thermal
/// state — instead of a frozen "Loading model…" with no diagnostics.
struct ModelLoadingView: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    @State private var thermal: ProcessInfo.ThermalState = .nominal
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = model.palette
        let elapsed = model.modelLoadStartedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        return VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(p.accent)
            Text("Loading \(model.activeModelLabel)…").font(.headline).foregroundStyle(p.text)
            if let elapsed {
                Text(elapsed >= 60 ? String(format: "%d:%02d elapsed", elapsed / 60, elapsed % 60) : "\(elapsed)s elapsed")
                    .font(.caption.monospaced()).foregroundStyle(p.textDim)
            }
            Text("Large models can take a few minutes to load the first time as your device compiles them. Keep CommSight open — it speeds up after the first load.")
                .font(.caption).foregroundStyle(p.textDim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").font(.caption2)
                Text("Device temperature: \(thermal.label)").font(.caption.monospaced())
            }
            .foregroundStyle(thermalColor(p))
            if thermal == .serious || thermal == .critical {
                Text("Your device is warming up while it loads — this eases once the model is ready. A smaller model (Small) loads far faster and runs cooler.")
                    .font(.caption2).foregroundStyle(p.warn)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        .accessibilityIdentifier("model-loading")
        .onAppear { thermal = DeviceLoad.thermalState() }
        .onReceive(tick) { now = $0; thermal = DeviceLoad.thermalState() }
    }

    private func thermalColor(_ p: Palette) -> Color {
        switch thermal {
        case .nominal: return p.textDim
        case .fair: return p.text
        case .serious, .critical: return p.warn
        @unknown default: return p.textDim
        }
    }
}
