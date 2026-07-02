#if canImport(UIKit)
import UIKit
#endif

/// Subtle tactile confirmation for the heading-bar controls — a small premium touch for the
/// in-cockpit feel (a bumpy flight deck benefits from feeling a tap land). Each call is a no-op
/// where UIKit/Taptic isn't available (e.g. a macOS build) and is silent in the Simulator. This is
/// UI-only; nothing here touches the transcription pipeline.
@MainActor
enum Haptics {
    /// How firm the tap feels. `.light` for the toggle/menu icons, `.medium` for the Start/Stop
    /// power tap, `.rigid` for the distinct standby long-press.
    enum Style { case light, medium, rigid }

    static func impact(_ style: Style) {
        #if canImport(UIKit)
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
