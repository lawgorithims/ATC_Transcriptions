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
}
