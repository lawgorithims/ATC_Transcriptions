import SwiftUI

/// The live transcript card: each transmission with its timestamp, stream offset,
/// latency, and any correction edits. Newest at the bottom (auto-scrolled).
struct TranscriptCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.headline).foregroundStyle(p.text)
                Spacer()
                Text(model.sourceLabel).font(.caption).foregroundStyle(p.textDim)
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
                            ForEach(model.records) { TranscriptRow(record: $0) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .onChange(of: model.records.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
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
                    Text(record.timestamp).font(.caption2.monospaced()).foregroundStyle(p.accent)
                    Text(String(format: "stream %.1fs", record.streamStartS))
                        .font(.caption2.monospaced()).foregroundStyle(p.textDim)
                    Spacer()
                    Text(String(format: "%.0f ms · RTF %.2f", record.transcribeMs, record.realTimeFactor))
                        .font(.caption2.monospaced()).foregroundStyle(p.textDim)
                }
                Text(record.display).font(.callout).foregroundStyle(p.text)
                    .textSelection(.enabled)
                if record.refinementState == .pending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("refining…").font(.caption2)
                    }
                    .foregroundStyle(p.textDim)
                } else if record.refinementState == .skippedConfident {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal").font(.caption2)
                        Text("high confidence").font(.caption2)
                    }
                    .foregroundStyle(p.textDim)
                }
                if !record.allEdits.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.caption2)
                        Text(record.allEdits.map { "\($0.from) → \($0.to)" }.joined(separator: ",  "))
                            .font(.caption2)
                    }
                    .foregroundStyle(p.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(p.border.opacity(0.6)).frame(height: 1)
        }
    }
}
