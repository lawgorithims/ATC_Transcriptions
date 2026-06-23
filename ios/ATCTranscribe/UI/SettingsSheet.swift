import SwiftUI

/// Model & settings sheet — port of the browser console's settings modal: pick the
/// transcription model and the adaptive real-time-speed threshold.
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card(title: "Transcription model") {
                        VStack(spacing: 10) {
                            KV("Active model", model.activeModel)
                            if let s = model.measuredSpeed {
                                KV("Measured speed", String(format: "%.1f× real-time", s))
                            }
                            HStack(spacing: 8) {
                                modelButton("turbo", "Large (turbo)")
                                modelButton("small", "Small (fast)")
                            }
                        }
                    }
                    Card(title: "Adaptive selection") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Minimum real-time speed").font(.caption).foregroundStyle(p.textDim)
                                Spacer()
                                Text(String(format: "%.1f×", model.minRealtimeSpeed))
                                    .font(.caption.monospaced()).foregroundStyle(p.text)
                            }
                            Slider(value: $model.minRealtimeSpeed, in: 0.5...10, step: 0.1)
                            Text("On startup the larger model is benchmarked on this device. If it runs slower than this, the smaller model loads automatically.")
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
        return Button { model.activeModel = id } label: {
            Text(label).font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(model.activeModel == id ? p.accent : p.surfaceAlt)
                .foregroundStyle(model.activeModel == id ? p.bg : p.text)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
