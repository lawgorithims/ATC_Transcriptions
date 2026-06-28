import SwiftUI

/// The live transcript card: each transmission with its timestamp, stream offset,
/// latency, and any correction edits. Order is user-selectable (newest at bottom — the default,
/// auto-scrolled down — or newest at top); a jump-to-newest button snaps to the latest line.
struct TranscriptCard: View {
    @EnvironmentObject var model: AppModel
    /// True while the user is pinned to the newest end (so we follow new transmissions); false once
    /// they scroll into history (auto-scroll pauses, the jump-to-newest button appears).
    @State private var atNewest = true

    /// Records in display order: reversed (newest first) when the user prefers it, else as stored.
    private var orderedRecords: [TranscriptRecord] {
        model.transcriptNewestFirst ? Array(model.records.reversed()) : model.records
    }

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Transcript").font(.headline).foregroundStyle(p.text)
                Spacer(minLength: 4)
                Text(model.sourceLabel).font(.caption).foregroundStyle(p.textDim).lineLimit(1)
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

            if model.records.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            newestMarker(isTop: true)
                            ForEach(orderedRecords) { TranscriptRow(record: $0) }
                            newestMarker(isTop: false)
                        }
                    }
                    // Follow new transmissions only while pinned to the newest end, so scrolling
                    // back to read history isn't yanked away every few seconds (a live feed appends
                    // constantly). A sort-order flip always snaps to (and re-pins) the newest line.
                    .onChange(of: model.records.count) { _ in if atNewest { scrollToNewest(proxy) } }
                    .onChange(of: model.transcriptNewestFirst) { _ in atNewest = true; scrollToNewest(proxy) }
                    .overlay(alignment: model.transcriptNewestFirst ? .topTrailing : .bottomTrailing) {
                        if !atNewest { jumpButton(proxy) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
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
}

struct TranscriptRow: View {
    @EnvironmentObject var model: AppModel
    let record: TranscriptRecord

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let spk = record.speaker {
                        Text("S\(spk + 1)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(speakerColor(spk).opacity(0.22))
                            .foregroundStyle(speakerColor(spk))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(speakerColor(spk).opacity(0.5), lineWidth: 1))
                            .accessibilityIdentifier("speaker-chip")
                    }
                    if let cs = record.adsbCallsign {
                        HStack(spacing: 2) {
                            Image(systemName: "airplane").font(.system(size: 8))
                            Text(cs).font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(p.accent.opacity(0.18)).foregroundStyle(p.accent)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("adsb-chip")
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
                Text(highlighted(record.display,
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

    /// Distinct color per diarization speaker id (cycles for many speakers).
    private func speakerColor(_ i: Int) -> Color {
        let colors: [Color] = [.hex(0x3B9EFF), .hex(0x2EE6A6), .hex(0xF5C451),
                               .hex(0xC58CFF), .hex(0xFF8FB1), .hex(0x5AD1E6)]
        return colors[((i % colors.count) + colors.count) % colors.count]
    }
}
