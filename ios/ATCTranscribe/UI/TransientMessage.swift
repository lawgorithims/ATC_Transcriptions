import SwiftUI

/// Something the app says ONCE, about something that has already happened.
///
/// ⚠️ WHY THIS EXISTS AT ALL. Stopping a recording that captured no fixes returned nil and said
/// nothing: `toggleFlightRecording` set `pendingLoggedFlight` to nil, no sheet appeared, and the
/// pilot had no way to tell "saved to the logbook" from "there was nothing to save". Reported from
/// the air as flights not saving. The app had no mechanism for a one-off statement — every piece of
/// text in it was either a persistent banner or a sheet, and neither can say "that did nothing, and
/// here is why" without either demanding an answer or staying on screen forever.
///
/// ⚠️ NEVER USE THIS FOR ANYTHING THE PILOT MUST ACT ON. It leaves on a timer, so anything carrying
/// a decision, a deadline or unsaved data belongs in the banner stack above the map instead.
/// `RecoveredRecordingBanner` is the example and is deliberately NOT a toast: it guards unsaved
/// flight data and has to still be there when the pilot looks up. This is for statements of fact
/// that are already true and need no reply.
struct TransientMessage: Identifiable, Equatable {
    /// Colour only — never the sole carrier of meaning, since the Night theme is red-only emission
    /// and the whole palette collapses toward one hue.
    enum Tone: Equatable { case neutral, good, warn }

    let id = UUID()
    let text: String
    let icon: String
    let tone: Tone

    /// How long it stays. A warning gets longer because it is usually the longer sentence AND the
    /// one a pilot reads while also flying; both numbers are "time to read it twice", not a guess at
    /// attention span. There is no shorter setting: a message too brief to read is the same bug as
    /// no message at all, which is what this type exists to fix.
    var visibleSec: TimeInterval { tone == .warn ? 7 : 4.5 }
}

/// The toast itself — a capsule over the bottom of the map, matching the chart/traffic pills.
///
/// Tapping it dismisses it early. There is no close button: a target that small beside text this
/// short is harder to hit than the whole capsule, and dismissing early is never important enough to
/// need its own affordance.
struct TransientMessageView: View {
    let message: TransientMessage
    let palette: Palette
    let onDismiss: () -> Void

    var body: some View {
        let p = palette
        return Button(action: onDismiss) {
            HStack(spacing: 8) {
                Image(systemName: message.icon).font(.dsLabel).foregroundStyle(tint(p))
                Text(message.text)
                    .font(.dsLabel).foregroundStyle(p.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            // Sized for the NARROWEST phone, not for the iPad: a capsule wider than the window is
            // the one failure mode a pilot cannot work around, and this one carries the sentence
            // explaining why something did not happen.
            .frame(maxWidth: 320, alignment: .leading)
            .background(p.overlay)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r4))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(tint(p), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transient-message")
        .accessibilityLabel(message.text)
        .accessibilityHint("Tap to dismiss")
    }

    private func tint(_ p: Palette) -> Color {
        switch message.tone {
        case .neutral: return p.textDim
        case .good:    return p.good
        case .warn:    return p.warn
        }
    }
}
