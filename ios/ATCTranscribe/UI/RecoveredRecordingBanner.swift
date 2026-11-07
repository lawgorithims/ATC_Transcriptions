import SwiftUI

/// "Your last flight is still here" — the prompt that gives back a recording the app died in the
/// middle of.
///
/// # Why this exists
///
/// `FlightRecorder` has mirrored every in-progress recording to disk since it was written, and
/// `recoverOnLaunch` has always reloaded it into `RecordingState.recovered`. Nothing ever read that
/// state. So after a crash the pilot was shown a REC button reading "not recording", over a trail
/// that was sitting in memory and on disk, and the first tap of that button reset the accumulators
/// and overwrote the file — the recovery destroyed what the crash had spared. The machinery was all
/// there; the last six inches of wire were missing. This is the wire.
///
/// # Why it has no Discard
///
/// Every other advisory in this stack can be waved away, and this one deliberately cannot. The others
/// describe something the pilot can go and look at for themselves — weather, a restriction, a GPS
/// state. This one IS the data: dismissing it is the only irreversible action on the screen, and a
/// single stray tap on a bar that appears unannounced at launch is a poor way to lose a flight you
/// have already nearly lost once. **Save** ends it in the logbook, where deleting it is deliberate,
/// visible and unhurried. `FlightRecorder.discardRecovered()` still exists for a caller that has
/// asked the question properly.
struct RecoveredRecordingBanner: View {
    let recovered: RecoveredRecording
    let palette: Palette
    /// Carry on recording into the same flight — the common case, because an app that died in the air
    /// is usually relaunched in the air.
    var onResume: () -> Void
    /// Close it off and send it to the save prompt as it stands.
    var onSave: () -> Void

    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()

    /// "42m · 18.4 NM · 1,240 points" — what is actually being offered back, so the choice between
    /// resuming and saving is made on the size of the thing rather than on faith.
    private var detail: String {
        let d = Self.duration.string(from: recovered.duration) ?? "—"
        return String(format: "%@ · %.1f NM · %d points", d, recovered.distanceNM, recovered.points)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle").font(.dsHeadline).foregroundStyle(palette.warn)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording recovered")
                    .font(.dsHeadline).foregroundStyle(palette.text)
                    .accessibilityIdentifier("recovered-recording-headline")
                Text(detail).font(.dsLabelS).foregroundStyle(palette.textDim).lineLimit(1)
                Text("The app closed before this flight was saved.")
                    .font(.dsLabelS).foregroundStyle(palette.textDim.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Resume") { Haptics.impact(.medium); onResume() }
                .font(.dsLabelBold)
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("recovered-recording-resume")
            Button("Save") { Haptics.impact(.light); onSave() }
                .font(.dsLabelBold).foregroundStyle(palette.accent)
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("recovered-recording-save")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.warn.opacity(0.5)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recovered-recording-banner")
    }
}
