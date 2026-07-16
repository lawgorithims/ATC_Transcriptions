import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A RELIABLE two-finger PAN over interactive SwiftUI content.
///
/// The obvious approach — an overlay `UIView` whose `point(inside:)` is true only when ≥2 fingers are down
/// — does NOT work: the first finger lands while the touch count is still 1, so it's hit-tested to the
/// content BELOW the overlay, and a two-touch recognizer on the overlay only ever receives the SECOND
/// finger and never reaches its minimum. Instead this attaches the recognizer to the enclosing WINDOW
/// (which receives every touch in the hierarchy) and only claims gestures whose centroid starts within
/// this view's own bounds. A marker view that is transparent to ALL touches (`point(inside:) == false`)
/// gives the position reference without blocking any button, slider, or scroll underneath.
struct TwoFingerPan: UIViewRepresentable {
    var onChanged: (CGSize) -> Void = { _ in }
    var onEnded: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged, onEnded: onEnded) }

    func makeUIView(context: Context) -> UIView {
        let v = Marker()
        v.onWindow = { window in context.coordinator.attach(to: window, marker: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void
        private weak var pan: UIPanGestureRecognizer?
        private weak var window: UIWindow?
        private weak var marker: UIView?
        private var active = false

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize) -> Void) {
            self.onChanged = onChanged; self.onEnded = onEnded
        }

        func attach(to window: UIWindow?, marker: UIView) {
            detach()
            guard let window else { return }                 // detached from the hierarchy — nothing to attach to
            let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            p.minimumNumberOfTouches = 2
            p.maximumNumberOfTouches = 2
            p.cancelsTouchesInView = false                   // never swallow a tap meant for a button below
            p.delegate = self
            window.addGestureRecognizer(p)
            self.pan = p; self.window = window; self.marker = marker
        }

        func detach() {
            if let p = pan, let w = window { w.removeGestureRecognizer(p) }
            pan = nil
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                active = markerContains(g.location(in: g.view))   // only our widget's region
            case .changed:
                guard active else { return }
                let t = g.translation(in: g.view)
                onChanged(CGSize(width: t.x, height: t.y))
            case .ended, .cancelled, .failed:
                guard active else { return }
                active = false
                let t = g.translation(in: g.view)
                onEnded(CGSize(width: t.x, height: t.y))
            default: break
            }
        }

        private func markerContains(_ pointInWindow: CGPoint) -> Bool {
            guard let marker, let window, marker.window === window else { return false }
            return marker.convert(marker.bounds, to: window).contains(pointInWindow)
        }

        // Coexist with the SwiftUI header drag / MapKit / a sibling widget's pan rather than fighting them.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    /// A position reference that never intercepts a touch (so it blocks nothing); it just tells the
    /// coordinator when it joins/leaves a window so the window-level recognizer can be (de)attached.
    private final class Marker: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindow?(window) }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
}
