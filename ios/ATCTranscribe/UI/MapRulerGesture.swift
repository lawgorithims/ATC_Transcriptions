#if canImport(UIKit)
import UIKit

/// The two-finger recognizer behind the ruler, and the one place that decides whether a given pair
/// of fingers belongs to a ruler or to the map.
///
/// WHY A CUSTOM RECOGNIZER. Two fingers on a map already mean something: pinch to zoom, and on both
/// engines a two-finger tap means zoom OUT. A ruler cannot simply take them. What it can do is
/// decide, from WHERE the fingers land and WHAT they then do, which of the two readings applies —
/// and that decision needs the individual touch positions at the moment they land, which neither
/// `UITapGestureRecognizer` (its touches are gone by the time it fires) nor `UIPanGestureRecognizer`
/// (it reports a centroid) will give.
///
/// The rule, and the reason for it:
///
///   * Two fingers that land holding an existing ruler claim the gesture IMMEDIATELY (`.adjust`).
///     The pilot is reaching for something that is already on the chart, under their finger, so
///     there is nothing ambiguous to wait for. The map's pinch and rotate are switched off for the
///     duration by the controller — not merely out-prioritised, because by the time the second
///     finger lands the pinch has already begun.
///   * Two fingers that land anywhere else stay `.possible` and WAIT. This is the important half: a
///     gesture that has not begun blocks nothing, so an ordinary pinch-zoom behaves exactly as it
///     did before this file existed. The moment either finger travels past `moveSlop` the
///     recognizer FAILS and the pinch is left entirely alone.
///   * If instead both fingers lift inside `tapWindow` without travelling, it was a two-finger tap:
///     the recognizer recognises, and a new ruler is laid between the two points. The map's own
///     two-finger tap is made to require this one to fail, so the chart does not also zoom out.
///
/// So the only thing a pilot loses is the two-finger tap-to-zoom-out, and only when the tap is a
/// deliberate one. Pinch, rotate, one-finger pan and the double-tap zoom (while no ruler exists)
/// are untouched.
@MainActor
final class TwoFingerRulerRecognizer: UIGestureRecognizer {

    /// What this pair of fingers turned out to mean.
    enum Intent { case undecided, adjust, created }

    /// How far a finger may travel and still count as a tap rather than a pinch. Generous, because
    /// this is read in flight with gloves on and against vibration.
    static let moveSlop: CGFloat = 16
    /// How long two fingers may rest before they stop being a tap. Past this the pilot is holding,
    /// not tapping, and the gesture is left to the map.
    static let tapWindow: TimeInterval = 0.45
    /// Two fingers closer together than this are one clumsy touch, not a span worth measuring.
    static let minSpan: CGFloat = 32

    private(set) var intent: Intent = .undecided
    /// Where the two fingers are now, and where they landed, in the host view's coordinates.
    private(set) var current: [CGPoint] = []
    private(set) var origins: [CGPoint] = []

    /// Asked once, when the second finger lands: does this pair take hold of something? Returning
    /// true claims the gesture immediately.
    var shouldAdjust: ([CGPoint]) -> Bool = { _ in false }

    private var touchPair: [UITouch] = []
    /// How many of the two fingers have come off. A tap is only a tap once BOTH have: resolving on
    /// the first lift would mean a pilot who lifts one finger and keeps dragging the other has
    /// already laid a ruler down behind their hand.
    private var ended = 0
    private var began: TimeInterval = 0

    override func reset() {
        super.reset()
        intent = .undecided
        touchPair = []
        ended = 0
        current = []
        origins = []
        began = 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for t in touches where touchPair.count < 3 { touchPair.append(t) }
        // A third finger is not a ruler gesture under any reading — hand it back to the map.
        if touchPair.count > 2 { state = .failed; return }
        guard touchPair.count == 2 else { return }
        origins = locations()
        current = origins
        began = event.timestamp
        guard span(origins) >= Self.minSpan else { state = .failed; return }
        if shouldAdjust(origins) {
            intent = .adjust
            state = .began
        }
        // Otherwise stay `.possible`: see the note above about not blocking a pinch.
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard touchPair.count == 2 else { return }
        current = locations()
        switch intent {
        case .adjust:
            state = .changed
        case .undecided:
            if travelled() > Self.moveSlop { state = .failed }   // it is a pinch; stand down
        case .created:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        ended += touches.count
        switch intent {
        case .adjust:
            // A finger coming off ends the adjustment. Lifting IS the commit, so there is nothing to
            // wait for — and continuing to track one finger after the other has gone would drag the
            // ruler somewhere the pilot did not put it.
            state = .ended
        case .undecided:
            guard ended >= 2 else { return }                     // one finger up is not a tap yet
            let quick = event.timestamp - began <= Self.tapWindow
            if quick, travelled() <= Self.moveSlop, touchPair.count == 2 {
                intent = .created
                state = .ended                                   // a two-finger tap: lay a ruler
            } else {
                state = .failed
            }
        case .created:
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }

    private func locations() -> [CGPoint] {
        touchPair.prefix(2).map { $0.location(in: view) }
    }

    private func travelled() -> CGFloat {
        guard current.count == 2, origins.count == 2 else { return 0 }
        return max(hypot(current[0].x - origins[0].x, current[0].y - origins[0].y),
                   hypot(current[1].x - origins[1].x, current[1].y - origins[1].y))
    }

    private func span(_ p: [CGPoint]) -> CGFloat {
        guard p.count == 2 else { return 0 }
        return hypot(p[0].x - p[1].x, p[0].y - p[1].y)
    }
}
#endif
