import SwiftUI

/// The right-hand column: latency stats, proof-of-life, and host/device info.
struct SidebarColumn: View {
    var body: some View {
        VStack(spacing: 14) {
            LatencyCard()
            ProofOfLifeCard()
            HostCard()
        }
    }
}

struct LatencyCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Latency") {
            let ct = model.stats.captureToTextSummary
            let tr = model.stats.transcribeSummary
            let rtf = model.stats.realTimeFactorSummary
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatCell(value: "\(model.stats.count)", key: "transmissions")
                StatCell(value: ct.map { "\(Int($0.p50.rounded())) ms" } ?? "—", key: "capture→text p50")
                StatCell(value: tr.map { "\(Int($0.p50.rounded())) ms" } ?? "—", key: "transcribe p50")
                StatCell(value: rtf.map { String(format: "%.2f", $0.mean) } ?? "—", key: "RTF mean")
            }
        }
    }
}

struct StatCell: View {
    @EnvironmentObject var model: AppModel
    let value: String
    let key: String
    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(p.text)
            Text(key).font(.caption2).foregroundStyle(p.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProofOfLifeCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        Card(title: "Proof of life") {
            if let pol = model.proofOfLife {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: pol.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(pol.passed ? p.good : p.bad)
                        Text(pol.passed ? "PASS" : "FAIL").font(.subheadline.weight(.bold))
                            .foregroundStyle(pol.passed ? p.good : p.bad)
                    }
                    if let wer = pol.meanWER {
                        KV("mean WER", String(format: "%.1f%%", wer * 100))
                    }
                    if let rt = pol.realtimeSpeed {
                        KV("speed", String(format: "%.1f× real-time", rt))
                    }
                    KV("model", pol.activeModel ?? "—")
                }
            } else {
                Text("Not checked yet.").font(.callout).foregroundStyle(p.textDim)
            }
            Button {
                model.runProofOfLife()
            } label: {
                Label("Run proof-of-life", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(p.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
            }
            .buttonStyle(.plain).foregroundStyle(p.text)
            .padding(.top, 2)
        }
    }
}

struct HostCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Host") {
            VStack(spacing: 8) {
                KV("Device", model.deviceLabel)
                KV("Model", model.activeModel)
                KV("Platform", "iOS / iPadOS")
            }
        }
    }
}

/// A key/value row used inside the sidebar cards.
struct KV: View {
    @EnvironmentObject var model: AppModel
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    var body: some View {
        let p = model.palette
        HStack {
            Text(key).font(.caption).foregroundStyle(p.textDim)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(p.text)
        }
    }
}
