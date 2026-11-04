import SwiftUI

/// The storm-penetration warning: a full-width bar in the console's stack, never a modal.
///
/// Same rule as every other advisory in this app — an EFB must not take a modal over the moving map in
/// flight (`UI/ConsoleView.swift` records what a non-dismissible cover cost this app once). It is silent
/// unless the projected track actually reaches something, so it means something when it appears.
///
/// # What the wording has to do
///
/// Two numbers, and the honest limits of both. The headline is when the aircraft arrives; the detail is
/// how high the storm goes, where it is going, and **how old the bulletin is** — because every time on
/// screen is the output of an extrapolation, and a 25-minute-old motion vector deserves to be read as
/// one. The source line names the product rather than claiming to be a storm detector: a Convective
/// SIGMET is issued for significant convection, so an isolated cell may not have one, and a pilot who
/// thinks this sees all thunderstorms is worse off than one who knows what it reads.
struct ConvectiveAlertBanner: View {
    let threats: [ConvectiveThreat]
    let palette: Palette
    let onDismiss: () -> Void

    private var lead: ConvectiveThreat? { threats.first }

    /// Red for a track that enters the cell, amber for one that only comes too close. The distinction is
    /// worth a colour: one of them has to be turned away from, the other may be acceptable.
    private var tint: Color {
        guard let lead else { return palette.textDim }
        return lead.kind == .penetration ? palette.bad : palette.warn
    }

    private var icon: String {
        guard let lead else { return "cloud.bolt.fill" }
        return lead.kind == .penetration ? "cloud.bolt.rain.fill" : "exclamationmark.triangle.fill"
    }

    /// What produced the cell on the banner, and the caveat that belongs with THAT source.
    ///
    /// A Convective SIGMET is a forecaster's product and can miss an isolated cell; a radar-derived cell
    /// is a measurement nobody has vetted, and its motion is inferred rather than reported. Those are
    /// different kinds of limitation and a single generic line would misdescribe one of them.
    static func sourceLine(_ t: ConvectiveThreat) -> String {
        switch t.cell.source {
        case .sigmet:
            return "Convective SIGMET (AWC) · forecaster-issued · not an official briefing"
        case .cwa:
            return "Center Weather Advisory (AWC) · forecaster-issued · not an official briefing"
        case .warning:
            return "NWS severe thunderstorm warning · tops not stated · not an official briefing"
        case .radar:
            return t.cell.motionKt == nil
                ? "Radar echo tops (MRMS) · no bulletin issued · movement unknown"
                : "Radar echo tops (MRMS) · no bulletin issued · movement estimated from radar"
        }
    }

    private var headline: String {
        guard let lead else { return "Convective weather nearby" }
        let more = threats.count > 1 ? " (+\(threats.count - 1) more)" : ""
        return ConvectiveAlertText.headline(lead) + more
    }

    var body: some View {
        if let lead {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.dsHeadline).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.dsHeadline).foregroundStyle(palette.text).lineLimit(1)
                        .accessibilityIdentifier("convective-headline")
                    // ⚠️ THREE LINES, NOT TWO, SINCE THE CLEARANCE RULE CAN ADD A CLAUSE. The detail is
                    // truncated from the END, and the end is where the age and the drift allowance sit —
                    // the two facts that say how much of the rest to believe. "AIM wants 9,300 ft (93 kt
                    // at tops)" is ~34 characters, which at phone width pushed both of them off a
                    // two-line label. The label still takes only the lines it needs, so the banner is
                    // unchanged in every case that fitted before.
                    Text(ConvectiveAlertText.detail(lead))
                        .font(.dsLabelS).foregroundStyle(palette.textDim).lineLimit(3)
                        .accessibilityIdentifier("convective-detail")
                    // Named, not hidden. See the type comment: what this reads determines what it can
                    // miss, and the pilot is entitled to know which it is — which now varies per cell,
                    // because a radar-derived cell and a bulletin are known to different depths.
                    Text(Self.sourceLine(lead))
                        .font(.dsLabelS).foregroundStyle(palette.textDim.opacity(0.8)).lineLimit(1)
                        .accessibilityIdentifier("convective-source")
                }
                Spacer(minLength: 4)
                Button { Haptics.impact(.light); onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textDim)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("convective-dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(palette.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.5)).frame(height: 1) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headline). \(ConvectiveAlertText.detail(lead))")
            .accessibilityIdentifier("convective-banner")
        }
    }
}
