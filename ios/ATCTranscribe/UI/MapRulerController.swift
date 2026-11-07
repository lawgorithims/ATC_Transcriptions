#if canImport(UIKit)
import UIKit

/// Drives the map rulers from one place, for whichever map engine happens to be live.
///
/// Both engines — `ChartMapView`'s `MKMapView` and `MapLibreChartView`'s `MLNMapView` — expose the
/// same two conversions (`convert(point, toCoordinateFrom:)` and `convert(coord, toPointTo:)`), so
/// all of the ruler's behaviour is written once here against a pair of closures and attached twice.
/// That matters beyond tidiness: the gesture arbitration below is the delicate part of this feature,
/// and having it exist in two places would mean a fix applied to one engine and not the other, on a
/// chart where the pilot cannot tell which engine they are looking at.
@MainActor
final class MapRulerController: NSObject, UIGestureRecognizerDelegate {

    /// Both fingers must be this close to the ruler's own line to drag the whole thing sideways.
    /// Narrow, and it takes BOTH fingers, so a pinch would have to begin with two fingers lying
    /// along an existing ruler to be mistaken for one.
    static let lineGrabBand: CGFloat = 30

    private let store: MapRulerStore
    private var toCoord: (CGPoint) -> Coord?
    private var toPoint: (Coord) -> CGPoint

    private weak var host: UIView?
    private var twoFinger: TwoFingerRulerRecognizer?
    private var clearAll: UITapGestureRecognizer?

    /// The map's own pinch and rotate, switched off while a ruler is under the fingers and switched
    /// straight back on when they lift. Disabling an in-flight recognizer is what cancels it, and by
    /// the time the second finger has landed the pinch has already started — so out-prioritising it
    /// is not enough, it has to be interrupted.
    private var suspended: [UIGestureRecognizer] = []
    /// Whether the map's own tap recognizers have been told to stand aside. Deferred rather than done
    /// at attach time because both engines build theirs lazily, so at `makeUIView` there is often
    /// nothing there yet to find.
    private var wiredTapDependencies = false

    /// What the two fingers have hold of: which ruler, and which end (if any) each finger drives.
    /// `nil` for a finger means it drives nothing, which is what makes a one-end grab predictable —
    /// the far end stays where the pilot left it instead of flying to their other thumb.
    private struct Hold {
        let id: UUID
        var endForTouch: [Bool?]
        /// Set when the pilot took hold of the LINE rather than an end: the whole ruler translates.
        var translateFrom: (a: Coord, b: Coord, origin: [CGPoint])?
    }
    private var hold: Hold?

    init(store: MapRulerStore = .shared,
         toCoord: @escaping (CGPoint) -> Coord?,
         toPoint: @escaping (Coord) -> CGPoint) {
        self.store = store
        self.toCoord = toCoord
        self.toPoint = toPoint
        super.init()
    }

    /// Re-point the conversions at a rebuilt map view without losing the rulers.
    func reconnect(toCoord: @escaping (CGPoint) -> Coord?, toPoint: @escaping (Coord) -> CGPoint) {
        self.toCoord = toCoord
        self.toPoint = toPoint
    }

    func attach(to view: UIView) {
        detach()
        let two = TwoFingerRulerRecognizer(target: self, action: #selector(handleTwoFinger(_:)))
        two.delegate = self
        two.cancelsTouchesInView = false          // never swallow a touch meant for map chrome
        two.shouldAdjust = { [weak self] points in self?.takeHold(at: points) ?? false }
        view.addGestureRecognizer(two)

        let clear = UITapGestureRecognizer(target: self, action: #selector(handleClear(_:)))
        clear.numberOfTapsRequired = 2
        clear.numberOfTouchesRequired = 1
        clear.delegate = self
        clear.cancelsTouchesInView = false
        view.addGestureRecognizer(clear)

        host = view
        twoFinger = two
        clearAll = clear
        wiredTapDependencies = false
    }

    func detach() {
        if let host {
            if let twoFinger { host.removeGestureRecognizer(twoFinger) }
            if let clearAll { host.removeGestureRecognizer(clearAll) }
        }
        resumeMapGestures()
        twoFinger = nil
        clearAll = nil
        host = nil
    }

    // MARK: Projection

    /// Re-project every ruler onto the display. Called by the engine wherever it already streams the
    /// plate anchors and the search highlight — i.e. on every camera change — so a frozen ruler
    /// stays nailed to the ground it was measured over.
    func refreshSegments() {
        wireTapDependenciesIfNeeded()
        var next: [UUID: MapRulerStore.ScreenSegment] = [:]
        for ruler in store.rulers {
            next[ruler.id] = MapRulerStore.ScreenSegment(a: toPoint(ruler.a), b: toPoint(ruler.b))
        }
        store.setSegments(next)
    }

    // MARK: The two-finger gesture

    @objc private func handleTwoFinger(_ g: TwoFingerRulerRecognizer) {
        switch g.state {
        case .began:
            suspendMapGestures()
            // The press matured into a ruler. Say so in the hand, because the pilot is holding
            // still and watching the chart: without it the only confirmation is the ruler appearing
            // when they lift, by which point it is too late to adjust the span.
            if g.intent == .created { Haptics.impact(.rigid) }
        case .changed:
            // `.created` has no hold — its ruler is laid at the fingers' final positions on lift.
            if g.intent == .adjust { applyHold(g.current) }
        case .ended:
            if g.intent == .created {
                // `current`, not `origins`: the span may have been slid after the press armed it.
                createRuler(between: g.current)
            } else {
                applyHold(g.current)
            }
            store.freeze()                       // lifting the fingers IS the commit
            hold = nil
            resumeMapGestures()
        case .cancelled, .failed:
            store.freeze()
            hold = nil
            resumeMapGestures()
        default:
            break
        }
    }

    private func createRuler(between points: [CGPoint]) {
        guard points.count == 2, let a = toCoord(points[0]), let b = toCoord(points[1]) else { return }
        store.add(a: a, b: b, live: false)
        refreshSegments()
        Haptics.impact(.medium)
    }

    /// Decide what (if anything) a landing pair of fingers has hold of. Called from the recognizer
    /// the instant the second finger lands, and its answer is what claims the gesture.
    private func takeHold(at points: [CGPoint]) -> Bool {
        guard points.count == 2 else { return false }
        let g0 = store.grab(near: points[0])
        let g1 = store.grab(near: points[1])

        // Both fingers on the ends of the SAME ruler: drag both, which moves, turns and resizes it
        // in one motion. This is the gesture the feature is really for.
        if let g0, let g1, g0.id == g1.id, g0.isEndA != g1.isEndA {
            hold = Hold(id: g0.id, endForTouch: [g0.isEndA, g1.isEndA], translateFrom: nil)
            return true
        }
        // One finger on one end: drag that end alone and leave the other where it is.
        if let g0 {
            hold = Hold(id: g0.id, endForTouch: [g0.isEndA, nil], translateFrom: nil)
            return true
        }
        if let g1 {
            hold = Hold(id: g1.id, endForTouch: [nil, g1.isEndA], translateFrom: nil)
            return true
        }
        // Neither on an end, but both lying along a ruler: slide the whole thing.
        if let id = rulerUnderBothFingers(points), let ruler = store.ruler(id) {
            hold = Hold(id: id, endForTouch: [nil, nil],
                        translateFrom: (ruler.a, ruler.b, points))
            return true
        }
        return false
    }

    private func applyHold(_ points: [CGPoint]) {
        guard let hold, points.count == 2, var ruler = store.ruler(hold.id) else { return }

        if let from = hold.translateFrom {
            // Translate by how far the two fingers' midpoint has moved, converted through the map so
            // the shift is in GROUND terms and the ruler keeps its length under a rotated chart.
            let before = CGPoint(x: (from.origin[0].x + from.origin[1].x) / 2,
                                 y: (from.origin[0].y + from.origin[1].y) / 2)
            let after = CGPoint(x: (points[0].x + points[1].x) / 2,
                                y: (points[0].y + points[1].y) / 2)
            let shift = CGPoint(x: after.x - before.x, y: after.y - before.y)
            let pa = toPoint(from.a), pb = toPoint(from.b)
            guard let a = toCoord(CGPoint(x: pa.x + shift.x, y: pa.y + shift.y)),
                  let b = toCoord(CGPoint(x: pb.x + shift.x, y: pb.y + shift.y)) else { return }
            ruler.a = a
            ruler.b = b
        } else {
            for (i, end) in hold.endForTouch.enumerated() {
                guard let end, i < points.count, let c = toCoord(points[i]) else { continue }
                if end { ruler.a = c } else { ruler.b = c }
            }
        }
        store.move(hold.id, a: ruler.a, b: ruler.b)
        if store.liveID != hold.id { store.setLive(hold.id) }
        refreshSegments()
    }

    /// The topmost ruler with both fingers lying along its line (and neither past its ends).
    private func rulerUnderBothFingers(_ points: [CGPoint]) -> UUID? {
        for ruler in store.rulers.reversed() {
            guard let seg = store.segments[ruler.id] else { continue }
            if points.allSatisfy({ distance(from: $0, toSegment: seg) <= Self.lineGrabBand } ) {
                return ruler.id
            }
        }
        return nil
    }

    private func distance(from p: CGPoint, toSegment s: MapRulerStore.ScreenSegment) -> CGFloat {
        let vx = s.b.x - s.a.x, vy = s.b.y - s.a.y
        let len2 = vx * vx + vy * vy
        guard len2 > 0.0001 else { return hypot(p.x - s.a.x, p.y - s.a.y) }
        var t = ((p.x - s.a.x) * vx + (p.y - s.a.y) * vy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (s.a.x + t * vx), p.y - (s.a.y + t * vy))
    }

    // MARK: Clearing

    @objc private func handleClear(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, !store.isEmpty else { return }
        store.clear()
        Haptics.impact(.light)
    }

    // MARK: Living alongside the map's own gestures

    /// `false` for the clear gesture while there is nothing to clear, which is the whole reason the
    /// map's double-tap zoom still works: the ruler's clear only competes once a ruler exists, so
    /// until the pilot makes one the chart behaves exactly as it did before.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === clearAll { return !store.isEmpty }
        return true
    }

    /// The ruler gestures coexist with one-finger panning and with map chrome. They do NOT coexist
    /// with pinch and rotate — those are suspended outright while a ruler is held, because a gesture
    /// that both measures and zooms measures nothing.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g === twoFinger, other is UIPinchGestureRecognizer || other is UIRotationGestureRecognizer {
            return false
        }
        return true
    }

    /// Make the map's own tap gestures wait on ours and stand down if ours recognises. Run late and
    /// once: both engines create their recognizers lazily, so at attach time there is usually
    /// nothing there to find.
    ///
    /// Three dependencies, and the third one costs something:
    ///
    ///   * the map's TWO-FINGER tap (zoom out) waits on the ruler's two-finger gesture, so laying a
    ///     ruler down does not also zoom the chart out from under it;
    ///   * the map's DOUBLE tap (zoom in) waits on the clear gesture;
    ///   * the map's SINGLE tap — tap-to-identify — waits on the clear gesture too.
    ///
    /// ⚠️ THAT LAST ONE DELAYS TAP-TO-IDENTIFY, and it is a deliberate trade rather than an
    /// oversight. Without it a double-tap to clear also fires the single-tap recognizer twice, so
    /// the pilot clears their rulers AND gets the object-identify panel thrown over the chart — seen
    /// happening on an iPad. With it, a single tap has to wait out the double-tap window before it
    /// is allowed to be a single tap.
    ///
    /// What keeps the cost confined: `gestureRecognizerShouldBegin` refuses the clear gesture
    /// outright while no ruler exists, so the dependency resolves instantly and tap-to-identify is
    /// exactly as quick as it ever was. The delay exists only once the pilot has put a ruler on the
    /// chart — a state they created and can end with the very gesture they are waiting on.
    private func wireTapDependenciesIfNeeded() {
        guard !wiredTapDependencies, let host, let twoFinger, let clearAll else { return }
        var found = false
        for g in Self.recognizers(in: host) where g !== twoFinger && g !== clearAll {
            guard let tap = g as? UITapGestureRecognizer else { continue }
            if tap.numberOfTouchesRequired == 2, tap.numberOfTapsRequired == 1 {
                tap.require(toFail: twoFinger); found = true
            }
            if tap.numberOfTouchesRequired == 1, tap.numberOfTapsRequired >= 1 {
                tap.require(toFail: clearAll); found = true
            }
        }
        wiredTapDependencies = found
    }

    private func suspendMapGestures() {
        guard let host, suspended.isEmpty else { return }
        for g in Self.recognizers(in: host)
        where (g is UIPinchGestureRecognizer || g is UIRotationGestureRecognizer) && g.isEnabled {
            g.isEnabled = false                 // cancels it if it has already begun
            suspended.append(g)
        }
    }

    private func resumeMapGestures() {
        for g in suspended { g.isEnabled = true }
        suspended.removeAll()
    }

    /// The map's recognizers, which on both engines hang off nested subviews rather than the map
    /// itself. Depth-bounded (rule 2) — this walks a live view tree on a gesture path.
    private static func recognizers(in view: UIView, depth: Int = 0) -> [UIGestureRecognizer] {
        guard depth <= 3 else { return [] }
        var out = view.gestureRecognizers ?? []
        for sub in view.subviews { out += recognizers(in: sub, depth: depth + 1) }
        return out
    }
}
#endif
