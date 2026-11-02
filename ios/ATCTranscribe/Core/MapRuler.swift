import Foundation
import CoreGraphics
import Combine

/// A measuring ruler the pilot laid on the map: two geographic ends, and nothing else.
///
/// ⚠️ GEOGRAPHIC, NOT SCREEN. A ruler that stored screen points would measure a different distance
/// after every pan and would be wrong the instant the map moved under it. The ends are PLACES; the
/// distance, bearing and time are derived from them on demand. Where those places currently fall on
/// the display is a separate, disposable thing (`MapRulerStore.segments`), recomputed by whichever
/// map engine is live, and it is never the source of truth for a number the pilot reads.
struct MapRuler: Identifiable, Equatable {
    let id: UUID
    var a: Coord
    var b: Coord

    init(id: UUID = UUID(), a: Coord, b: Coord) {
        self.id = id
        self.a = a
        self.b = b
    }
}

/// What one ruler reads out. A pure derivation from the two ends plus the speed the caller supplies,
/// so it can be tested exhaustively without a map, a GPS or a run loop.
struct MapRulerReadout: Equatable {

    /// Where the time figure came from.
    ///
    /// ⚠️ CARRIED INTO THE UI ON PURPOSE. "14 min" means something very different depending on
    /// whether it came from the ground speed the aircraft is making right now or from a cruise
    /// number typed into an aircraft profile months ago, and a pilot deciding whether to go around
    /// weather has to know which. The label says so rather than implying a precision it lacks.
    enum SpeedSource: Equatable { case groundSpeed, cruise, none }

    let distanceNm: Double
    let bearingTrue: Double
    /// nil where no bundled navaid within range publishes a variation — then the UI shows TRUE and
    /// says so, rather than passing a true bearing off as magnetic.
    let bearingMag: Double?
    /// nil when there is no usable speed at all; the UI then shows distance and bearing only.
    let minutes: Double?
    let speedKt: Double?
    let speedSource: SpeedSource
}

/// The ruler's arithmetic and its formatting, kept together and kept pure.
enum MapRulerMath {

    /// Below this a ground speed is an aircraft sitting still, and a time derived from it is
    /// meaningless (at 2 kt a 10 NM ruler reads five hours). Same threshold, for the same reason, as
    /// `RouteETAs.minGroundSpeedKt` — the two must not disagree about whether the aircraft is moving.
    static let minGroundSpeedKt = 10.0

    static func readout(_ ruler: MapRuler,
                        groundSpeedKt: Double?,
                        cruiseKt: Int?,
                        variation: (Coord) -> Double?) -> MapRulerReadout {
        let nm = Geo.nmBetween(ruler.a, ruler.b)
        let brgTrue = Geo.bearing(ruler.a, ruler.b)

        // Variation at the MIDPOINT, not at an end. A long ruler can span several degrees of it, and
        // the midpoint is the least wrong single answer for a line. Walked along the great circle
        // rather than averaged in lat/lon, which would be wrong across the antimeridian.
        let mid = nm > 0 ? Geo.point(from: ruler.a, bearingDeg: brgTrue, distanceNm: nm / 2) : ruler.a
        let brgMag = variation(mid).map { compassDegrees(brgTrue - $0) }

        // The pilot's own speed first; the profile's planning number only as a fallback.
        let resolved: (Double?, MapRulerReadout.SpeedSource)
        if let gs = groundSpeedKt, gs >= minGroundSpeedKt {
            resolved = (gs, .groundSpeed)
        } else if let cruise = cruiseKt, cruise > 0 {
            resolved = (Double(cruise), .cruise)
        } else {
            resolved = (nil, .none)
        }
        let minutes = resolved.0.map { nm / $0 * 60 }

        return MapRulerReadout(distanceNm: nm, bearingTrue: brgTrue, bearingMag: brgMag,
                               minutes: minutes, speedKt: resolved.0, speedSource: resolved.1)
    }

    /// Degrees onto 0..<360, so a bearing never prints as -15 or 375.
    static func compassDegrees(_ deg: Double) -> Double {
        guard deg.isFinite else { return 0 }
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// "4.3 NM" close in, "127 NM" far out. The decimal is kept under 10 NM because that is the
    /// range at which a ruler is being used to clear terrain or a TFR edge, where a whole mile is
    /// not a fine enough answer.
    static func distanceText(_ nm: Double) -> String {
        guard nm.isFinite else { return "—" }
        if nm < 10 { return String(format: "%.1f NM", nm) }
        return "\(Int(nm.rounded())) NM"
    }

    /// Three digits always, because a two-digit bearing on a chart is a misread waiting to happen.
    static func bearingText(_ readout: MapRulerReadout) -> String {
        if let mag = readout.bearingMag {
            return String(format: "%03d°M", Int(mag.rounded()) % 360)
        }
        return String(format: "%03d°T", Int(readout.bearingTrue.rounded()) % 360)
    }

    /// "<1 min", "7 min", "1:23". Hours and minutes past an hour, because "83 min" is a number a
    /// pilot has to convert before it means anything.
    static func timeText(_ minutes: Double?) -> String? {
        guard let minutes, minutes.isFinite, minutes >= 0 else { return nil }
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let total = Int(minutes.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The whole one-line readout, in the order a pilot reads it: how far, how long, which way.
    static func summary(_ readout: MapRulerReadout) -> String {
        var parts = [distanceText(readout.distanceNm)]
        if let t = timeText(readout.minutes) { parts.append(t) }
        parts.append(bearingText(readout))
        return parts.joined(separator: "  ·  ")
    }

    /// What the time figure rests on, for the second line. nil when there is no time shown at all.
    static func speedNote(_ readout: MapRulerReadout) -> String? {
        guard let kt = readout.speedKt else { return nil }
        switch readout.speedSource {
        case .groundSpeed: return "at \(Int(kt.rounded())) kt GS"
        case .cruise:      return "at \(Int(kt.rounded())) kt planned cruise"
        case .none:        return nil
        }
    }
}

/// Every ruler on the map, and where their ends currently fall on screen.
///
/// A singleton for the same reason `ChartLibrary` is one: the two map engines, the layers menu and
/// the SwiftUI overlay all have to be looking at the same rulers, and a ruler must survive the map
/// being torn down and rebuilt (a layer switch, a render-failure fallback to the classic engine).
@MainActor
final class MapRulerStore: ObservableObject {
    static let shared = MapRulerStore()

    /// Where one ruler's ends fall on the display right now. Refreshed by the live engine on every
    /// camera change and thrown away freely — see the warning on `MapRuler`.
    struct ScreenSegment: Equatable {
        var a: CGPoint
        var b: CGPoint
    }

    /// Bounded, and the bound is a safety one rather than a memory one: a pilot tapping at a chart
    /// in turbulence must not end up with a display they cannot read through. The oldest goes first
    /// because it is the one they have stopped looking at.
    static let maxRulers = 8

    /// How near an end a finger has to land to take hold of it, in points. Sized for a thumb on a
    /// yoke mount rather than a mouse.
    static let grabRadius: CGFloat = 44

    @Published private(set) var rulers: [MapRuler] = []
    /// The ruler under the pilot's fingers, if any — drawn live, and frozen the moment they lift.
    @Published private(set) var liveID: UUID?
    @Published private(set) var segments: [UUID: ScreenSegment] = [:]

    var isEmpty: Bool { rulers.isEmpty }

    @discardableResult
    func add(a: Coord, b: Coord, live: Bool) -> UUID {
        let ruler = MapRuler(a: a, b: b)
        rulers.append(ruler)
        while rulers.count > Self.maxRulers {
            let dropped = rulers.removeFirst()
            segments.removeValue(forKey: dropped.id)
            if liveID == dropped.id { liveID = nil }
        }
        if live { liveID = ruler.id }
        return ruler.id
    }

    func move(_ id: UUID, a: Coord, b: Coord) {
        guard let i = rulers.firstIndex(where: { $0.id == id }) else { return }
        rulers[i].a = a
        rulers[i].b = b
    }

    /// Mark a ruler as the one under the pilot's fingers — it is drawn dashed and amber so there is
    /// never a doubt which one is still moving.
    func setLive(_ id: UUID) {
        guard rulers.contains(where: { $0.id == id }) else { return }
        if liveID != id { liveID = id }
    }

    /// Lifting the fingers freezes the ruler. There is deliberately no separate commit: what is on
    /// screen when the pilot lets go is what stays, which is the whole of the interaction.
    func freeze() { liveID = nil }

    func remove(_ id: UUID) {
        rulers.removeAll { $0.id == id }
        segments.removeValue(forKey: id)
        if liveID == id { liveID = nil }
    }

    func clear() {
        rulers.removeAll()
        segments.removeAll()
        liveID = nil
    }

    func ruler(_ id: UUID) -> MapRuler? { rulers.first { $0.id == id } }

    /// Replace the screen projection wholesale. Compared before assigning: this is called on every
    /// camera change, and an unconditional write would republish the store — and re-render the
    /// overlay — on every frame of a pan whether or not anything moved.
    func setSegments(_ next: [UUID: ScreenSegment]) {
        if next != segments { segments = next }
    }

    /// Which ruler end a finger has taken hold of, nearest first. Searched newest-first so the ruler
    /// the pilot just laid down wins when two overlap.
    func grab(near point: CGPoint, radius: CGFloat = MapRulerStore.grabRadius) -> (id: UUID, isEndA: Bool)? {
        var best: (id: UUID, isEndA: Bool, d: CGFloat)?
        for ruler in rulers.reversed() {
            guard let seg = segments[ruler.id] else { continue }
            let da = hypot(seg.a.x - point.x, seg.a.y - point.y)
            let db = hypot(seg.b.x - point.x, seg.b.y - point.y)
            let (d, isA) = da <= db ? (da, true) : (db, false)
            if d <= radius, best == nil || d < best!.d {
                best = (ruler.id, isA, d)
            }
        }
        guard let best else { return nil }
        return (best.id, best.isEndA)
    }
}
