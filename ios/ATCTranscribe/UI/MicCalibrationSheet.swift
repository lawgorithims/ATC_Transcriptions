import SwiftUI

/// Guided microphone squelch calibration: stay quiet while it measures the room, then say a test call
/// while it measures the voice, and it sets the squelch to a gate between the two (see
/// `SquelchCalibration` / `MicCalibrator`). Only offered while stopped — calibration needs the mic to
/// itself. All the real work is device-side; this is just the two-step flow around `AppModel`.
struct MicCalibrationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card(title: "Calibrate microphone") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Set the squelch for your device and room. First stay quiet while it listens to the background, then say a short test call at your normal volume — it sets the threshold to sit between the two, so the quiet room is ignored and your voice comes through.")
                                .font(.caption).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)

                            if !model.canCalibrateMic {
                                Label("Stop the feed first — calibration needs the microphone to itself.",
                                      systemImage: "stop.circle")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            stageView
                        }
                    }
                }
                .padding(16)
            }
            .background(p.bg.ignoresSafeArea())
            .navigationTitle("Microphone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { model.resetCalibration() }
            .onDisappear { model.resetCalibration() }
        }
    }

    @ViewBuilder private var stageView: some View {
        switch model.calibrationStage {
        case .idle:
            step(1, "Stay quiet", "Don't talk — let it hear the background for a couple of seconds.")
            actionButton("Record background", icon: "waveform", enabled: model.canCalibrateMic) {
                model.recordCalibrationAmbient()
            }
        case .measuringAmbient:
            progressRow("Listening to the room…")
        case .ambientDone:
            step(2, "Say a test call", "At your normal volume, say something like “Boston Tower, Skyhawk one-two-three-four-five.”")
            actionButton("Record my voice", icon: "mic.fill", enabled: model.canCalibrateMic) {
                model.recordCalibrationVoice()
            }
        case .measuringVoice:
            progressRow("Listening to your voice…")
        case .success:
            resultRow("checkmark.circle.fill", .green, "Calibrated",
                      "The squelch is set for your room and voice. Fine-tune it anytime with the slider, then start the microphone to use it.")
            actionButton("Re-calibrate", icon: "arrow.clockwise", enabled: model.canCalibrateMic) {
                model.resetCalibration()
            }
        case .failed(let msg):
            resultRow("exclamationmark.triangle.fill", .orange, "Couldn't calibrate", msg)
            actionButton("Try again", icon: "arrow.clockwise", enabled: model.canCalibrateMic) {
                model.resetCalibration()
            }
        }
    }

    // MARK: pieces

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        let p = model.palette
        return HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(p.bg)
                .frame(width: 22, height: 22).background(p.accent).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.text)
                Text(detail).font(.caption).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progressRow(_ label: String) -> some View {
        let p = model.palette
        return HStack(spacing: 10) {
            ProgressView()
            Text(label).font(.subheadline).foregroundStyle(p.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func resultRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        let p = model.palette
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.text)
                Text(detail).font(.caption).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let p = model.palette
        return Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(enabled ? p.accent : p.surfaceAlt)
                .foregroundStyle(enabled ? p.bg : p.textDim)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plainHaptic).disabled(!enabled)
        .accessibilityIdentifier("mic-calibration-action")
    }
}
