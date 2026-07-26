import SwiftUI

// The app-wide design tokens for the cinematic-minimalism restyle: D-DIN typography,
// small flat radii, 1px strokes, and the shared surface/button recipes. Colors stay in
// Theme.swift (`Palette`); this file is everything that isn't a color. The palette is
// always passed in as a plain value — never read from the environment in subviews
// (ARCHITECTURE.md §6: AppModel publishes several times per second live).

enum DS {
    /// Corner radii — the whole app uses three: bars are square, chips barely soften,
    /// cards/surfaces get 4pt. (Replaces the pre-restyle spread of 1…16.)
    enum Radius {
        static let r0: CGFloat = 0
        static let r2: CGFloat = 2
        static let r4: CGFloat = 4
    }
    /// Stroke widths. `hairline` is one physical pixel on the 2x iPads the app targets;
    /// `control` outlines buttons and cards.
    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let control: CGFloat = 1.0
    }
}

/// One-time availability check for the bundled D-DIN faces (Resources/Fonts, SIL OFL).
/// Every token routes through these flags, so a missing/renamed font degrades to the
/// system face — cosmetic only, never a crash.
enum FontRegistry {
    static let dinName = "D-DIN"
    static let dinBoldName = "D-DIN-Bold"
    static let dinCondensedName = "D-DINCondensed"
    static let dinCondensedBoldName = "D-DINCondensed-Bold"

    static let dinAvailable: Bool = checkFace(dinName)
    static let dinBoldAvailable: Bool = checkFace(dinBoldName)
    static let dinCondensedAvailable: Bool = checkFace(dinCondensedName)
    static let dinCondensedBoldAvailable: Bool = checkFace(dinCondensedBoldName)

    private static func checkFace(_ name: String) -> Bool {
        assert(!name.isEmpty, "font face name must be non-empty")
        let ok = UIFont(name: name, size: 12) != nil
        assert(ok, "bundled font '\(name)' failed to register — check UIAppFonts/Resources/Fonts")
        return ok
    }
}

extension Font {
    // Raw faces. `relativeTo:` keeps Dynamic Type scaling; all fall back to system.
    static func din(_ size: CGFloat, relativeTo style: TextStyle) -> Font {
        FontRegistry.dinAvailable
            ? .custom(FontRegistry.dinName, size: size, relativeTo: style)
            : .system(style)
    }
    static func dinBold(_ size: CGFloat, relativeTo style: TextStyle) -> Font {
        FontRegistry.dinBoldAvailable
            ? .custom(FontRegistry.dinBoldName, size: size, relativeTo: style)
            : .system(style).weight(.bold)
    }
    static func dinCondensed(_ size: CGFloat, relativeTo style: TextStyle) -> Font {
        FontRegistry.dinCondensedAvailable
            ? .custom(FontRegistry.dinCondensedName, size: size, relativeTo: style)
            : .system(style)
    }
    static func dinCondensedBold(_ size: CGFloat, relativeTo style: TextStyle) -> Font {
        FontRegistry.dinCondensedBoldAvailable
            ? .custom(FontRegistry.dinCondensedBoldName, size: size, relativeTo: style)
            : .system(style).weight(.bold)
    }

    // Semantic tokens. Display/labels are D-DIN; prose stays the system face for long-form
    // legibility; data readouts stay monospaced so digits don't jitter.
    static var dsDisplayXL: Font { dinCondensedBold(34, relativeTo: .largeTitle) }
    static var dsDisplayL: Font { dinCondensedBold(24, relativeTo: .title2) }
    static var dsDisplayM: Font { dinCondensed(18, relativeTo: .title3) }
    static var dsHeadline: Font { dinBold(15, relativeTo: .headline) }
    static var dsBody: Font { .subheadline }
    static var dsLabel: Font { din(13, relativeTo: .footnote) }
    static var dsLabelBold: Font { dinBold(13, relativeTo: .footnote) }
    static var dsLabelS: Font { din(11, relativeTo: .caption2) }
    static var dsLabelSBold: Font { dinBold(11, relativeTo: .caption2) }
    static var dsDataMono: Font { .system(.caption, design: .monospaced).weight(.semibold) }
    static var dsDataMonoL: Font { .system(.body, design: .monospaced).weight(.semibold) }
}

extension View {
    /// ALL-CAPS tracked section header — the Card-title idiom, tokenized.
    func dsSectionHeader(_ p: Palette) -> some View {
        font(.dsLabelS).tracking(1.4).textCase(.uppercase).foregroundStyle(p.textDim)
    }
    /// ALL-CAPS condensed caption for tab bars and compact button labels.
    func dsCapsLabel() -> some View {
        font(.dinCondensedBold(12, relativeTo: .caption)).tracking(1.0).textCase(.uppercase)
    }
    /// The shared surface recipe: flat fill, small radius, 1px outline.
    func dsSurface(_ p: Palette, radius: CGFloat = DS.Radius.r4, fill: Color? = nil) -> some View {
        background(fill ?? p.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(p.border, lineWidth: DS.Stroke.control))
    }
}

/// Thin-outline button: transparent fill, 1px stroke, quiet press fill. `prominent`
/// promotes the stroke/label to the accent for the screen's primary action. Coexists
/// with `.plainHaptic` — a label that draws its own chrome keeps `.plainHaptic`, a bare
/// label that should read as a button adopts this. Never both.
struct OutlinedButtonStyle: ButtonStyle {
    let p: Palette
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsLabel)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(prominent ? p.accent : p.text)
            .background(configuration.isPressed ? p.accentMuted : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r2)
                .stroke(prominent ? p.accent : p.border, lineWidth: DS.Stroke.control))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in if pressed { Haptics.impact(.light) } }
    }
}
extension ButtonStyle where Self == OutlinedButtonStyle {
    static func outlined(_ p: Palette) -> OutlinedButtonStyle { .init(p: p) }
    static func outlinedProminent(_ p: Palette) -> OutlinedButtonStyle { .init(p: p, prominent: true) }
}
