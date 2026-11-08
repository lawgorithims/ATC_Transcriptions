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
///   * If instead both fingers REST for `pressDuration` without travelling, it was a simultaneous
///     two-finger long press: the recognizer recognises and a ruler is laid between them. The
///     fingers may then be adjusted before lifting, and lifting commits.
///
/// ⚠️ IT USED TO BE A TWO-FINGER TAP AND THE PILOT ASKED FOR A PRESS. A tap is the harder
/// gesture to make deliberately in turbulence — two fingers have to arrive AND leave together
/// inside a window — and it collided with the map's own two-finger tap-to-zoom-out, which had to be
/// made to wait on this recognizer failing. A press collides with nothing: a tap now fails here
/// immediately on lift, so zoom-out fires as it always did, and the ruler is armed by holding still,
/// which is the one thing a hand braced against vibration can actually do.
///
/// So a pilot now loses NOTHING. Pinch, rotate, one-finger pan, the double-tap zoom and the
/// two-finger tap-to-zoom-out all behave exactly as they did before this file existed.
@MainActor
final class TwoFingerRulerRecognizer: UIGestureRecognizer {

    /// What this pair of fingers turned out to mean.
    enum Intent { case undecided, adjust, created }

    /// How far a finger may travel and still count as a tap rather than a pinch. Generous, because
    /// this is read in flight with gloves on and against vibration.
    static let moveSlop: CGFloat = 16
    /// How long two fingers must rest, together and still, before they mean a ruler. Short enough
    /// not to feel like a wait, long enough that it cannot be produced by a pinch that happens to
    /// start slowly — which is the only other thing two still fingers could be.
    static let pressDuration: TimeInterval = 0.5
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
    private var ended = 0
    private var began: TimeInterval = 0
    /// Fires `pressDuration` after an undecided pair lands. Cancelled by travel, by a lift, and by
    /// `reset()` — a timer that outlives its gesture would arm a ruler under whatever the pilot is
    /// doing a moment later.
    private var pressTimer: DispatchWorkItem?

    override func reset() {
        super.reset()
        cancelPressTimer()
        intent = .undecided
        touchPair = []
        ended = 0
        current = []
        origins = []
        began = 0
    }

    private func cancelPressTimer() {
        pressTimer?.cancel()
        pressTimer = nil
    }

    /// Arm the press. Re-checks everything when it fires, because the world moved on in the half
    /// second it was waiting: fingers may have lifted, a third may have landed, or the recognizer
    /// may already have failed into a pinch.
    private func startPressTimer() {
        cancelPressTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.state == .possible, self.intent == .undecided,
                  self.touchPair.count == 2, self.ended == 0,
                  self.travelled() <= Self.moveSlop else { return }
            self.intent = .created
            self.state = .began                       // the ruler exists from here; lifting commits
        }
        pressTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressDuration, execute: work)
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
        } else {
            // Stay `.possible` and start counting: see the note above about not blocking a pinch.
            startPressTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard touchPair.count == 2 else { return }
        current = locations()
        switch intent {
        case .adjust:
            state = .changed
        case .undecided:
            if travelled() > Self.moveSlop {
                cancelPressTimer()
                state = .failed                                  // it is a pinch; stand down
            }
        case .created:
            // Armed, and the pilot is still holding. Let them slide the span to where they want it
            // before lifting — the ruler is laid where the fingers END, not where they landed.
            state = .changed
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
            // A finger lifting before the press matured means this was never a ruler. Failing at
            // once (rather than waiting for the second finger) is what lets the map's two-finger
            // tap-to-zoom-out fire without a perceptible delay, since it waits on this failure.
            cancelPressTimer()
            state = .failed
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
