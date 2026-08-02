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

/// Aviation entity tints — the single source for the chip/legend/object-card colors that used to
/// be copy-pasted hex across five files. Cockpit and day keep the chart-convention hues; night maps
/// every entity onto an ordered warm ramp (dark adaptation) that stays distinguishable by luminance,
/// with TFR keeping pure alarm red.
enum EntityTint {
    static func color(_ kind: MapObjectKind, _ theme: AppTheme) -> Color {
        if theme == .night { return nightColor(kind) }
        switch kind {
        case .airport:   return .hex(0xE879F9)   // purple-pink — chart airport magenta family
        case .vor:       return .hex(0x34D399)   // green — navaid
        case .fix:       return .hex(0x60A5FA)   // blue — RNAV/GPS fix
        case .airspace:  return .hex(0x2F6FED)
        case .traffic:   return .orange
        case .userPoint: return .hex(0xFBBF24)
        case .hazard:    return .hex(0xF97316)
        case .tfr:       return .hex(0xF71433)
        case .airway:    return .hex(0x6B94DB)
        // Earth tone, deliberately outside the navigation-symbol families: this is ground
        // assessment, not a chart entity the pilot can navigate to.
        case .lzRisk:    return .hex(0x8D9B6A)
        }
    }
    private static func nightColor(_ kind: MapObjectKind) -> Color {
        switch kind {
        case .airport:   return .hex(0xFF5A3C)
        case .vor:       return .hex(0xC85A30)
        case .fix:       return .hex(0xD98A4A)
        case .airspace:  return .hex(0x8A4A26)
        case .traffic:   return .hex(0xE06018)
        case .userPoint: return .hex(0xF5B04E)
        case .hazard:    return .hex(0xE06018)
        case .tfr:       return .hex(0xFF3B30)
        case .airway:    return .hex(0xB0521E)
        case .lzRisk:    return .hex(0x8A6A34)
        }
    }
    /// Route-leg chip color (flight-plan strip / route editor).
    static func leg(_ kind: RouteKind, _ p: Palette, _ theme: AppTheme) -> Color {
        switch kind {
        case .airport:  return color(.airport, theme)
        case .vor:      return color(.vor, theme)
        case .waypoint: return color(.fix, theme)
        case .airway:   return theme == .night ? .hex(0xF5B04E) : .hex(0xF5C451)
        case .other:    return p.text            // DCT / procedure / unknown
        }
    }
    /// Distinct per-speaker diarization colors (cycles). Night is a warm luminance ramp — the old
    /// blue/green/violet set was a genuine night-vision violation.
    static func speaker(_ i: Int, _ theme: AppTheme) -> Color {
        let chart: [Color] = [.hex(0x3B9EFF), .hex(0x2EE6A6), .hex(0xF5C451),
                              .hex(0xC58CFF), .hex(0xFF8FB1), .hex(0x5AD1E6)]
        let night: [Color] = [.hex(0xFF6A50), .hex(0xD98A4A), .hex(0xF5B04E),
                              .hex(0xE8503F), .hex(0xB0521E), .hex(0x8C2F26)]
        let table = theme == .night ? night : chart
        assert(!table.isEmpty, "speaker palette must be non-empty")
        return table[((i % table.count) + table.count) % table.count]
    }
    /// Favorites star.
    static func favorite(_ theme: AppTheme) -> Color {
        theme == .night ? .hex(0xF5B04E) : .hex(0xF5C451)
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
