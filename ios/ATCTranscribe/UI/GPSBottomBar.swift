import SwiftUI

/// A semitransparent live-GPS strip pinned just above the bottom tab bar (app-wide, toggle in the Widgets
/// menu). Same merged source as the GPS widget — Stratux-preferred, on-device fallback — laid out as a
/// compact row. Reads only; never a 2nd GPS session.
struct GPSBottomBar: View {
    @EnvironmentObject var model: AppModel
    @State private var deviceFix: DeviceFix?

    var body: some View {
        let p = model.palette
        let r = GPSReadout.merge(stratux: model.stratuxGPS, device: deviceFix)
        return HStack(spacing: 12) {
            signalCell(r)
            Divider().frame(height: 22)
            metric("ALT", r.altitudeFtMSL.map { "\(Int($0.rounded())) ft" } ?? "—")
            metric("GS", r.groundSpeedKt.map { "\(Int($0.rounded())) kt" } ?? "—")
            metric("TRK", r.trackDeg.map { String(format: "%03.0f°", $0) } ?? "—")
            Spacer(minLength: 0)
            if model.isRecording { RecordingIndicator(startedAt: model.recordingStartedAt, palette: p) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 0.5) }
        .accessibilityIdentifier("gps-bottom-bar")
        .onReceive(model.deviceLocation.$fix) { deviceFix = $0 }
    }

    @ViewBuilder private func signalCell(_ r: GPSReadout) -> some View {
        let p = model.palette
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < r.fixQuality.bars ? Self.qualityColor(r.fixQuality, p) : p.textDim.opacity(0.25))
                        .frame(width: 3.5, height: 5 + CGFloat(i) * 3.5)
                }
            }
            Text(sourceBadge(r.source)).font(.caption2.weight(.semibold)).foregroundStyle(p.textDim).tracking(0.5)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        let p = model.palette
        return VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.textDim).tracking(0.5)
            Text(value).font(.caption.monospaced().weight(.semibold)).foregroundStyle(p.text)
        }
    }
    private func sourceBadge(_ s: GPSReadout.Source) -> String {
        switch s { case .stratux: return "STX"; case .device: return "GPS"; case .none: return "—" }
    }
    private static func qualityColor(_ q: FixQuality, _ p: Palette) -> Color {
        switch q { case .none: return p.textDim; case .poor: return p.warn; case .fair: return p.warn; default: return p.good }
    }
}

/// The blinking red dot + elapsed M:SS driven by ONE TimelineView (shared by the GPS bar and the REC button).
/// Mounted only while recording, so there's no idle timer.
struct RecordingIndicator: View {
    let startedAt: Date?
    let palette: Palette

    var body: some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 0.5)) { ctx in
            let elapsed = max(ctx.date.timeIntervalSince(startedAt ?? ctx.date), 0)
            HStack(spacing: 5) {
                Circle().fill(palette.bad)
                    .frame(width: 8, height: 8)
                    .opacity(Int(elapsed / 0.5) % 2 == 0 ? 1 : 0.25)
                Text(LoggedFlight.hms(elapsed)).font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(palette.text)
            }
        }
    }
}

/// The REC / stop control for the Map top bar — always visible on the map surface; becomes the blinking
/// indicator + elapsed timer while recording.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.palette
        let rec = model.isRecording
        return Button {
            Haptics.impact(.medium); model.toggleFlightRecording()
        } label: {
            if rec {
                RecordingIndicator(startedAt: model.recordingStartedAt, palette: p)
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(p.bad.opacity(0.16), in: Capsule())
            } else {
                Image(systemName: "record.circle").font(.system(size: 19, weight: .semibold))
                    .frame(width: 30, height: 30).foregroundStyle(p.bad)
            }
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("record-button")
        .accessibilityLabel(rec ? "Stop recording" : "Record flight")
    }
}
