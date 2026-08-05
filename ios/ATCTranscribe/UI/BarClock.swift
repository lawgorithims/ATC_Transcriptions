import SwiftUI

/// Local and UTC time in the top bar.
///
/// UTC IS THE ONE THAT MATTERS AND IT READS FIRST. Every clearance, every METAR, every NOTAM window
/// and every flight plan in this app is in Zulu; local time is the one a pilot can reconstruct and
/// Zulu is the one they are held to. So Zulu gets the monospaced digits and the "Z", and local sits
/// under it in the dimmer style — the same hierarchy the rest of the chrome uses for "the number"
/// versus "the context for the number".
///
/// MONOSPACED ON PURPOSE. A proportional clock shifts every digit as the minute rolls, which turns a
/// glanceable readout into something the eye has to re-find. Same reason the GPS bar is monospaced.
///
/// Ticks on a `TimelineView(.periodic)` at one second rather than a `Timer` publishing into the view
/// tree: SwiftUI drives it from the display link and stops it when the view is off screen, so a
/// backgrounded map does not keep a timer alive. `AppModel` is deliberately not involved — a clock
/// republishing a large observed object once a second would invalidate every view that observes it.
struct BarClock: View {
    @EnvironmentObject var model: AppModel
    /// Compact width hides the local line; there is no room for two rows beside the icons.
    var compact: Bool = false

    private static let zulu: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        let p = model.palette
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 2) {
                    Text(Self.zulu.string(from: now))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(p.text)
                    Text("Z").font(.dsLabelS).foregroundStyle(p.textDim)
                }
                if !compact {
                    Text(Self.local.string(from: now) + " " + Self.localAbbrev)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(p.textDim)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Self.zulu.string(from: now)) Zulu, "
                                + "\(Self.local.string(from: now)) local")
            .accessibilityIdentifier("bar-clock")
        }
    }

    /// The device's own zone abbreviation (MDT, PST…). Read once — it changes on a zone change, and
    /// a view that recomputes it every second would allocate a formatter per tick for a label that
    /// is stable for months.
    private static let localAbbrev: String =
        TimeZone.current.abbreviation() ?? ""
}
