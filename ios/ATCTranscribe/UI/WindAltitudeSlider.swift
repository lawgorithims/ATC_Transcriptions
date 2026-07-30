import SwiftUI

/// The map's left-edge altitude control for the winds-aloft overlay: ten detents from the surface to
/// FL390, plus a status chip carrying the model run, its age, and the speed colour key.
///
/// Vertical, on the left, because that is the shape of the question — the pilot is asking "what is the wind
/// doing at my altitude, and would climbing help?", and a vertical track answers it in the same geometry as
/// an altimeter. It costs nothing to move: one download carries the whole column, so switching levels
/// re-reads memory.
///
/// Three layout constraints, each learned the hard way elsewhere in this file:
///   * inset from the screen edge, or the drag fights the system back-swipe gesture;
///   * inset again for a docked left widget pane (the `RadarLoopBar` pattern);
///   * clear the MEASURED top chrome rather than a constant, which is what buried the status pills once.
struct WindAltitudeSlider: View {
    @ObservedObject var windAloft: WindAloftService
    @ObservedObject var widgets: WidgetStore
    @Binding var levelIndex: Int
    let palette: Palette
    let topInset: CGFloat
    let theme: AppTheme
    /// The selected base layer — the ramp resolves through it (`.smartDark` forces the night ramp),
    /// so the legend key matches the particles it describes.
    let layer: ChartLayer
    /// True while `thermalSerious` has the overlay paused. The control stays on screen (hiding it would
    /// leave the layers menu showing "Winds aloft" ON with nothing to explain the empty chart) and says
    /// so instead — the same doctrine as the radar pill, which was fixed once for lying about a stopped
    /// feed. Without this the chip went on naming a GFS cycle and its age for a layer that had stopped
    /// drawing, which reads as "the wind really is calm here".
    let thermalWarm: Bool

    /// Track geometry. The track is tall enough for ten legible detents on an iPad and still fits an
    /// iPhone in landscape.
    private static let trackHeight: CGFloat = 300
    private static let trackWidth: CGFloat = 4
    private static let thumbSize: CGFloat = 26
    /// Clear of the system left-edge back-swipe band.
    private static let edgeInset: CGFloat = 22

    @State private var dragging = false

    private var levels: [WindLevel] { WindLevel.allCases }
    private var level: WindLevel { WindLevel.at(index: levelIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            track
            statusChip
        }
        .padding(.leading, Self.edgeInset + leftPaneInset)
        .padding(.top, topInset)
    }

    // MARK: track

    /// Detent 0 sits at the BOTTOM (the ground) and 9 at the top, so the control reads like an altitude.
    private var track: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .top) {
                Capsule()
                    .fill(palette.border)
                    .frame(width: Self.trackWidth, height: Self.trackHeight)
                Capsule()
                    .fill(palette.accent.opacity(0.85))       // filled from the ground up to the selection
                    .frame(width: Self.trackWidth, height: max(Self.trackHeight - offset(for: levelIndex), 2))
                    .offset(y: offset(for: levelIndex))
                thumb
            }
            .frame(width: Self.thumbSize, height: Self.trackHeight)
            .contentShape(Rectangle())
            .gesture(drag)
            // ORDER MATTERS: promote to a single element, THEN name it. An identifier applied before the
            // promotion attaches to the children — it ended up on the thumb's glyph, whose auto-generated
            // label ("Breezy") is what a UI test then found under the slider's name.
            .accessibilityElement()
            .accessibilityIdentifier("wind-altitude-slider")
            .accessibilityLabel("Wind altitude")
            .accessibilityValue("\(level.shortLabel), \(level.pressureLabel)")
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? levelIndex + 1 : levelIndex - 1
                levelIndex = min(max(next, 0), levels.count - 1)
            }
            ticks
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(palette.overlay, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4)
            .stroke(palette.border, lineWidth: DS.Stroke.hairline))
    }

    private var thumb: some View {
        ZStack {
            Circle().fill(palette.surface)
            Circle().stroke(palette.accent, lineWidth: dragging ? 2.5 : 1.5)
            Image(systemName: "wind").font(.system(size: 10, weight: .bold)).foregroundStyle(palette.accent)
                .accessibilityHidden(true)                      // decoration; the slider carries the value
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
        .offset(y: offset(for: levelIndex) - Self.thumbSize / 2)
        .shadow(color: .black.opacity(0.35), radius: dragging ? 5 : 2)
    }

    /// Every level is labelled — ten rows is few enough that hiding any of them would just make the pilot
    /// hunt. The selected one is emphasised rather than enlarged, so the row spacing never shifts.
    private var ticks: some View {
        VStack(spacing: 0) {
            ForEach(levels.reversed(), id: \.rawValue) { lvl in     // top = highest
                Text(lvl.shortLabel)
                    .font(.dsLabelS.weight(lvl == level ? .bold : .regular))
                    .foregroundStyle(lvl == level ? palette.accent : palette.textDim)
                    .frame(height: Self.trackHeight / CGFloat(max(levels.count - 1, 1)),
                           alignment: .center)
                    .onTapGesture {
                        guard lvl != level else { return }
                        Haptics.impact(.light)
                        levelIndex = lvl.rawValue
                    }
            }
        }
        .frame(height: Self.trackHeight + Self.trackHeight / CGFloat(max(levels.count - 1, 1)))
    }

    /// Points from the top of the track to a detent.
    private func offset(for index: Int) -> CGFloat {
        let span = max(levels.count - 1, 1)
        let clamped = min(max(index, 0), span)
        return Self.trackHeight * CGFloat(span - clamped) / CGFloat(span)
    }

    /// Snap to the nearest detent, with a haptic on each crossing — the tick is what makes ten discrete
    /// levels feel like a control rather than a continuous slider that happens to quantise.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragging = true
                let span = max(levels.count - 1, 1)
                let fraction = 1 - min(max(value.location.y / Self.trackHeight, 0), 1)
                let snapped = Int((fraction * CGFloat(span)).rounded())
                guard snapped != levelIndex else { return }
                Haptics.impact(.light)
                levelIndex = min(max(snapped, 0), span)
            }
            .onEnded { _ in dragging = false }
    }

    // MARK: status chip

    /// Provenance, age and the colour key. Staleness is SHOWN, not hidden: model data with an honest age
    /// beats a confident-looking overlay whose run the pilot cannot see.
    private var statusChip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(level.shortLabel + " · " + level.pressureLabel)
                .font(.dsLabelSBold).foregroundStyle(palette.text)
            HStack(spacing: 5) {
                if windAloft.fetching { ProgressView().controlSize(.mini) }
                Text(statusText).font(.dsLabelS).foregroundStyle(palette.textDim)
            }
            if windAloft.fieldSet != nil, !thermalWarm { legend }   // no key for a layer that is not drawing
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: 168, alignment: .leading)
        .background(palette.overlay, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4)
            .stroke(palette.border, lineWidth: DS.Stroke.hairline))
        // ONE element with an explicit label, so VoiceOver reads "FL180, 500 hPa. GFS 12z +3h · 8 min ago"
        // as a single fact rather than four unrelated fragments. Written out rather than using
        // `children: .combine`, which merges the children's own identifiers and drops this one — leaving the
        // chip unreachable by name from a UI test.
        .accessibilityElement()
        .accessibilityIdentifier("wind-status-chip")
        .accessibilityLabel("\(level.shortLabel), \(level.pressureLabel). \(statusText)")
    }

    private var statusText: String {
        // Ordered by what the pilot most needs to know. The pause outranks the data: a chip reading
        // "GFS 12z +3h · 4 min ago" over a chart with no streaks on it invites reading calm air where
        // there is simply no layer.
        if thermalWarm { return "Paused — device warm" }
        guard let set = windAloft.fieldSet else {
            if windAloft.failed { return "Winds unavailable — retrying" }
            return windAloft.fetching ? "Loading winds…" : "Winds off"
        }
        return "\(set.cycleLabel) · \(Self.age(of: set.fetchedAt))"
    }

    /// A just-completed fetch is "now", not "in 0 seconds" — `RelativeDateTimeFormatter` rounds a
    /// sub-second age into the FUTURE tense, which reads as though the data has not arrived yet.
    private static func age(of when: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(when)
        guard seconds >= 45 else { return "now" }
        return relative.localizedString(for: when, relativeTo: now)
    }

    /// The speed key. Labelled in knots because that is the unit in the clearance and on the strip.
    private var legend: some View {
        let ramp = WindRamp.forLayer(layer, theme: theme)
        return VStack(alignment: .leading, spacing: 2) {
            LinearGradient(colors: ramp.cgColors(steps: 9).map { Color(cgColor: $0) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 5)
                .clipShape(Capsule())
            HStack(spacing: 0) {
                Text("0").font(.system(size: 8)).foregroundStyle(palette.textDim)
                Spacer()
                Text("75").font(.system(size: 8)).foregroundStyle(palette.textDim)
                Spacer()
                Text("150 kt").font(.system(size: 8)).foregroundStyle(palette.textDim)
            }
        }
    }

    private var leftPaneInset: CGFloat {
        guard widgets.leftPane != nil else { return 0 }
        return widgets.leftPaneWidth > 0 ? widgets.leftPaneWidth : 320
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
