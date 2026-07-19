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
        return HStack(spacing: 8) {
            signalBox(r)
            metricBox("ALT", r.altitudeFtMSL.map { "\(Int($0.rounded())) ft" } ?? "—")
            metricBox("GS", r.groundSpeedKt.map { "\(Int($0.rounded())) kt" } ?? "—")
            metricBox("TRK", r.trackDeg.map { String(format: "%03.0f°", $0) } ?? "—")
            Spacer(minLength: 0)
            if model.isRecording {
                RecordingIndicator(startedAt: model.recordingStartedAt, palette: p).modifier(BoxCell(p: p))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)   // ~25% taller than before (was vertical 6, no boxes)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 0.5) }
        .accessibilityIdentifier("gps-bottom-bar")
        .onReceive(model.deviceLocation.$fix) { deviceFix = $0 }
    }

    /// Signal box: the 4-bar indicator + the quality WORD (No signal / Weak / Marginal / Good) + the source.
    private func signalBox(_ r: GPSReadout) -> some View {
        let p = model.palette
        return HStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < r.fixQuality.bars ? Self.qualityColor(r.fixQuality, p) : p.textDim.opacity(0.25))
                        .frame(width: 4, height: 6 + CGFloat(i) * 4)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.signalWord(r.fixQuality)).font(.caption.weight(.semibold)).foregroundStyle(p.text)
                Text(sourceBadge(r.source)).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.textDim).tracking(0.5)
            }
        }
        .modifier(BoxCell(p: p))
    }

    private func metricBox(_ label: String, _ value: String) -> some View {
        let p = model.palette
        return VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.textDim).tracking(0.5)
            Text(value).font(.callout.monospaced().weight(.semibold)).foregroundStyle(p.text)
        }
        .modifier(BoxCell(p: p))
    }

    private func sourceBadge(_ s: GPSReadout.Source) -> String {
        switch s { case .stratux: return "STRATUX"; case .device: return "DEVICE"; case .none: return "—" }
    }
    /// The plain-English signal word the pilot asked for, collapsing the 5 quality tiers to 4 words.
    static func signalWord(_ q: FixQuality) -> String {
        switch q {
        case .none: return "No signal"
        case .poor: return "Weak"
        case .fair: return "Marginal"
        case .good, .excellent: return "Good"
        }
    }
    private static func qualityColor(_ q: FixQuality, _ p: Palette) -> Color {
        switch q { case .none: return p.textDim; case .poor, .fair: return p.warn; default: return p.good }
    }
}

/// One boxed cell in the GPS bar — a subtle rounded chip so each datapoint reads as its own box.
private struct BoxCell: ViewModifier {
    let p: Palette
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(p.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 0.5))
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
