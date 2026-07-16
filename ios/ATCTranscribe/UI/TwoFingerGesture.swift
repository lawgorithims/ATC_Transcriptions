import SwiftUI

/// A two-finger downward-swipe detector layered over SwiftUI content. SwiftUI has no multi-finger
/// gesture, so this bridges a UIKit two-finger `UIPanGestureRecognizer`. The overlay is touch-transparent
/// to SINGLE-finger touches — `point(inside:)` returns true only while ≥2 fingers are down — so buttons
/// and sliders underneath keep working, and only a genuine two-finger drag is captured.
private struct TwoFingerSwipeDown: UIViewRepresentable {
    let onSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSwipeDown: onSwipeDown) }

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughUnlessTwoFinger()
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onSwipeDown = onSwipeDown }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipeDown: () -> Void
        private var fired = false
        init(onSwipeDown: @escaping () -> Void) { self.onSwipeDown = onSwipeDown }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began: fired = false
            case .changed:
                let t = g.translation(in: g.view)
                // A decisive downward drag (mostly vertical, past a threshold) fires once per gesture.
                if !fired, t.y > 60, t.y > abs(t.x) { fired = true; onSwipeDown() }
            default: break
            }
        }
        // Coexist with MapKit / SwiftUI recognizers rather than fighting them.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    /// Captures a touch only when two or more fingers are down — single-finger touches pass through to
    /// the SwiftUI controls below.
    private final class PassthroughUnlessTwoFinger: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            (event?.allTouches?.count ?? 0) >= 2
        }
    }
}

extension View {
    /// Fire `action` on a two-finger downward swipe over this view. Single-finger interaction underneath
    /// is unaffected.
    func twoFingerSwipeDown(_ action: @escaping () -> Void) -> some View {
        overlay(TwoFingerSwipeDown(onSwipeDown: action))
    }
}
