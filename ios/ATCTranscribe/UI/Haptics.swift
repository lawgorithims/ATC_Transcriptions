import SwiftUI
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Subtle tactile confirmation for tappable controls — a small premium touch for the in-cockpit feel
/// (a bumpy flight deck benefits from feeling a tap land). Each call is a no-op where UIKit/Taptic
/// isn't available (e.g. a macOS build) and is silent in the Simulator. This is UI-only; nothing here
/// touches the transcription pipeline.
///
/// HARDWARE NOTE: no iPad (including iPad Pro) has a Taptic Engine, so `UIImpactFeedbackGenerator` is a
/// SILENT no-op on iPad regardless of this code — button haptics are only felt on iPhone. The generators
/// below are persistent + kept warm because a freshly-created generator often misses the FIRST tap
/// (prepare() warms the engine asynchronously); reusing a pre-prepared one fires reliably on iPhone.
@MainActor
enum Haptics {
    /// How firm the tap feels. `.light` for the toggle/menu icons and every button, `.medium` for the
    /// Start/Stop power tap, `.rigid` for the distinct standby long-press.
    enum Style { case light, medium, rigid }

    private static var lastLight: CFTimeInterval = 0

    #if canImport(UIKit)
    // Long-lived generators (one per firmness) so the Taptic engine stays warm between taps.
    private static let lightGen  = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGen  = UIImpactFeedbackGenerator(style: .rigid)
    #endif

    /// Warm the engine ahead of the first tap (call at launch / on foreground). Cheap; no-op on iPad.
    static func prepare() {
        #if canImport(UIKit)
        lightGen.prepare(); mediumGen.prepare(); rigidGen.prepare()
        #endif
    }

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
        let generator: UIImpactFeedbackGenerator
        switch style {
        case .light:  generator = lightGen
        case .medium: generator = mediumGen
        case .rigid:  generator = rigidGen
        }
        generator.impactOccurred()
        generator.prepare()          // re-arm so the NEXT tap is instant and doesn't miss
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
