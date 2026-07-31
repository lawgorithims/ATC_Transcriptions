import SwiftUI

/// The "when is this wind from" stamp, on the chart itself.
///
/// The altitude slider's status chip already carried the model run, but it is attached to the SLIDER —
/// which is off on the classic engine, off on a compact layout, and easy to read as chrome rather than as
/// a property of what is drawn. Animated particles look live whatever their age: a field decoded from a
/// cycle eighteen hours old drifts exactly as convincingly as one decoded ten minutes ago. So the valid
/// time belongs ON the chart, next to the thing it describes, wherever the sprites are.
///
/// It states the VALID TIME in Zulu — the clock every other time on an aeronautical chart uses — not the
/// fetch age. "GFS 06z +9h" is provenance and makes the pilot do the addition; "1500Z" is the answer.
/// The offset beside it is signed on purpose: a forecast valid in the future is normal and must not be
/// dressed up as an age, and a forecast that has fallen behind must say so plainly.
struct WindDataStamp: View {
    @ObservedObject var windAloft: WindAloftService
    let level: WindLevel
    let palette: Palette
    /// True while `thermalSerious` has the layer paused — the stamp must not keep describing a field that
    /// has stopped drawing (same rule as the slider's chip and the radar pill).
    let thermalWarm: Bool
    /// Visible longitude span, degrees. The renderer blanks the layer past `cutoffSpan` because one
    /// affine stops describing the globe there — and a stamp that goes on naming a valid time over an
    /// empty chart reads as "the wind really is calm", which is the whole failure this stamp exists to
    /// prevent. It has to know the same gate the renderer uses.
    let lonSpan: Double

    /// Re-render the relative offset without polling: the whole stamp is cheap and this only fires while
    /// the layer is up.
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wind").font(.system(size: 10, weight: .semibold))
            Text(text).font(.dsLabelS)
        }
        .foregroundStyle(palette.textDim)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(palette.overlay, in: Capsule())
        .overlay(Capsule().stroke(palette.border, lineWidth: DS.Stroke.hairline))
        .onReceive(tick) { now = $0 }
        .accessibilityElement()
        .accessibilityIdentifier("wind-data-stamp")
        .accessibilityLabel("Winds aloft. \(text)")
    }

    private var text: String {
        if thermalWarm { return "Winds paused — device warm" }
        if lonSpan >= WindParticleRenderer.cutoffSpan { return "Winds — zoom in to show" }
        guard let set = windAloft.fieldSet else {
            if windAloft.failed { return "Winds unavailable" }
            return windAloft.fetching ? "Loading winds…" : "Winds off"
        }
        return "\(level.shortLabel) · valid \(set.validLabel) · \(set.validOffsetLabel(now: now))"
    }
}
