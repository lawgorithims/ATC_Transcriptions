import SwiftUI

/// Non-modal GPS integrity advisory over the map. Silent while the fix is good — it appears only at
/// `degraded` or worse, so it means something when it does.
///
/// Deliberately NOT an alert: an EFB must never take a modal over the moving map in flight. The wording
/// tells the pilot what to DO (cross-check a navaid) rather than reciting a metre count, and the
/// `unreliable` / `suspect` copy says outright that ownship has been removed — a symbol quietly
/// vanishing with no explanation is worse than the degraded fix it was hiding.
struct GPSIntegrityBanner: View {
    let assessment: GPSIntegrityAssessment
    let palette: Palette
    /// The interference verdict layered on the integrity state. When it names jamming or spoofing it
    /// takes over the headline, because "GPS accuracy degraded" and "your position is being faked" call
    /// for completely different actions in the cockpit.
    var threat: GPSThreatAssessment = GPSThreatAssessment()

    private var showsThreat: Bool { threat.threat.isInterference }

    private var tint: Color {
        if showsThreat { return .red }
        switch assessment.state {
        case .degraded:             return .orange
        case .unreliable, .suspect: return .red
        case .unknown, .nominal:    return palette.textDim
        }
    }

    private var icon: String {
        if showsThreat { return threat.threat == .spoofing ? "exclamationmark.shield.fill" : "antenna.radiowaves.left.and.right.slash" }
        switch assessment.state {
        case .suspect:              return "exclamationmark.triangle.fill"
        case .unreliable:           return "location.slash.fill"
        default:                    return "location.circle"
        }
    }

    private var headline: String {
        if showsThreat {
            let conf = threat.confidence == .high ? "" : " (possible)"
            return (threat.threat == .spoofing ? "GPS spoofing suspected" : "GPS interference / jamming suspected") + conf
        }
        switch assessment.state {
        case .suspect:    return "GPS position suspect"
        case .unreliable: return "GPS position unusable"
        case .degraded:   return "GPS accuracy degraded"
        default:          return "GPS"
        }
    }

    private var detail: String {
        if showsThreat { return threat.advisory }
        switch assessment.state {
        case .suspect:    return "Ownship hidden — do not navigate by GPS. Cross-check navaids."
        case .unreliable: return "Ownship hidden. Cross-check navaids."
        case .degraded:   return "Cross-check with other navaids."
        default:          return ""
        }
    }

    var body: some View {
        if assessment.state >= .degraded || showsThreat {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.callout.weight(.semibold)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(headline).font(.caption.weight(.semibold)).foregroundStyle(palette.text)
                        if let m = assessment.horizontalAccuracyM, assessment.state != .suspect, !showsThreat {
                            Text("±\(Int(m.rounded())) m").font(.caption2.monospacedDigit())
                                .foregroundStyle(palette.textDim)
                        }
                    }
                    Text(detail).font(.caption2).foregroundStyle(palette.textDim)
                    let why = showsThreat ? threat.reasonText : assessment.reasonText
                    if !why.isEmpty {
                        Text(why).font(.caption2).foregroundStyle(tint.opacity(0.9))
                    }
                }
                Spacer(minLength: 0)
            }
            // Full-width bar matching the hazard / EFB banners above it, not a floating card: it is a
            // sibling of those in the console's bar stack.
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(palette.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.5)).frame(height: 1) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headline). \(detail)")
            .accessibilityIdentifier("gps-integrity-banner")
        }
    }
}
