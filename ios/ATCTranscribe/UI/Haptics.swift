import SwiftUI
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Subtle tactile confirmation for tappable controls — a small premium touch for the in-cockpit feel
/// (a bumpy flight deck benefits from feeling a tap land). Each call is a no-op where UIKit/Taptic
/// isn't available (e.g. a macOS build) and is silent in the Simulator. This is UI-only; nothing here
/// touches the transcription pipeline.
@MainActor
enum Haptics {
    /// How firm the tap feels. `.light` for the toggle/menu icons and every button, `.medium` for the
    /// Start/Stop power tap, `.rigid` for the distinct standby long-press.
    enum Style { case light, medium, rigid }

    private static var lastLight: CFTimeInterval = 0

    static func impact(_ style: Style) {
        #if canImport(UIKit)
        // Coalesce `.light`: the button styles fire on press-DOWN and some actions ALSO call `.light` on
        // release, so a single tap can request two within ~100 ms — debounce to one crisp tap. Deliberate
        // repeat taps (>150 ms apart) still each fire. `.medium`/`.rigid` are never coalesced.
        if style == .light {
            let now = CACurrentMediaTime()
            if now - lastLight < 0.15 { return }
            lastLight = now
        }
        let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light:  uiStyle = .light
        case .medium: uiStyle = .medium
        case .rigid:  uiStyle = .rigid
        }
        let generator = UIImpactFeedbackGenerator(style: uiStyle)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}

/// A drop-in for `.plain` that adds the light tap-haptic on press-down while leaving the label exactly as
/// authored (so the 58 custom chips/rows/icon buttons all confirm a tap without any appearance change).
struct PlainHapticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)       // matches .plain's subtle press dim
            .onChange(of: configuration.isPressed) { _, pressed in if pressed { Haptics.impact(.light) } }
    }
}
extension ButtonStyle where Self == PlainHapticButtonStyle {
    static var plainHaptic: PlainHapticButtonStyle { .init() }
}
