import SwiftUI

/// Two-finger vertical-swipe convenience built on `TwoFingerPan` (the reliable window-attached recognizer
/// — an overlay gated on touch count silently fails to collect the first finger). Fires `action` ONCE when
/// a two-finger drag crosses a decisive vertical threshold in the requested direction; single-finger
/// interaction underneath (buttons, sliders, scroll) is unaffected.
private struct TwoFingerSwipe: View {
    enum Direction { case up, down }
    let direction: Direction
    let action: () -> Void

    @State private var fired = false

    var body: some View {
        TwoFingerPan(
            onChanged: { t in
                let vertical = direction == .down ? t.height : -t.height
                if !fired, vertical > 60, abs(t.height) > abs(t.width) { fired = true; action() }
            },
            onEnded: { _ in fired = false }
        )
    }
}

extension View {
    /// Fire `action` on a two-finger downward swipe over this view. Single-finger interaction is unaffected.
    func twoFingerSwipeDown(_ action: @escaping () -> Void) -> some View {
        overlay(TwoFingerSwipe(direction: .down, action: action))
    }

    /// Fire `action` on a two-finger upward swipe over this view. Single-finger interaction is unaffected.
    func twoFingerSwipeUp(_ action: @escaping () -> Void) -> some View {
        overlay(TwoFingerSwipe(direction: .up, action: action))
    }
}
