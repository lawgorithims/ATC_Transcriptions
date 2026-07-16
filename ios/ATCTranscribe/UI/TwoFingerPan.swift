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
///
/// `priority` breaks ties when several regions overlap the same two-finger centroid (e.g. two stacked
/// widgets, or a widget docked over the top-bar swipe zone): only the highest-priority region claims the
/// gesture, so the front-most card moves and the ones behind it (and the top-bar swipe) stay put.
struct TwoFingerPan: UIViewRepresentable {
    var priority: Int = 0
    var onChanged: (CGSize) -> Void = { _ in }
    var onEnded: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(priority: priority, onChanged: onChanged, onEnded: onEnded) }

    func makeUIView(context: Context) -> UIView {
        let v = Marker()
        // [weak v] is REQUIRED: without it the Marker self-retains through its own stored closure, pinning
        // the Coordinator (and its captured store closures) forever — a per-instance leak on every widget /
        // top-bar / plate-menu region.
        v.onWindow = { [weak v] window in
            guard let v else { return }
            context.coordinator.attach(to: window, marker: v)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.priority = priority
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? Marker)?.onWindow = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var priority: Int
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void
        private weak var pan: UIPanGestureRecognizer?
        private weak var window: UIWindow?
        private weak var marker: UIView?
        private var active = false

        // All attached coordinators, weakly, so overlapping regions can arbitrate by priority at .began.
        private struct Weak { weak var c: Coordinator? }
        private static var live: [Weak] = []

        init(priority: Int, onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize) -> Void) {
            self.priority = priority; self.onChanged = onChanged; self.onEnded = onEnded
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
            Coordinator.live.removeAll { $0.c == nil }
            Coordinator.live.append(Weak(c: self))
        }

        func detach() {
            if let p = pan, let w = window { w.removeGestureRecognizer(p) }
            pan = nil
            Coordinator.live.removeAll { $0.c == nil || $0.c === self }
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                active = winsArbitration(at: g.location(in: g.view))   // only the front-most region claims it
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

        /// True iff this region contains the centroid AND no higher-priority live region IN THE SAME WINDOW
        /// also contains it (ties broken by registration order, so exactly one region ever claims a gesture).
        /// Same-window scoping matters on iPadOS: a second scene (Split View / Stage Manager) is a separate
        /// UIWindow whose coordinators share this static registry, and both windows' spaces start at (0,0),
        /// so an unscoped compare could let a card in window B win — and thus DENY — a gesture in window A.
        private func winsArbitration(at pointInWindow: CGPoint) -> Bool {
            guard markerContains(pointInWindow) else { return false }
            let contenders = Coordinator.live.compactMap { $0.c }
                .filter { $0.window === self.window && $0.markerContains(pointInWindow) }
            let top = contenders.map(\.priority).max()
            return contenders.first { $0.priority == top } === self
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
