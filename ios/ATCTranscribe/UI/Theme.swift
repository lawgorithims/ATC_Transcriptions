import SwiftUI

/// The three appearance modes: a near-black cinematic **Cockpit**, a white **Day**, and a
/// red night-vision **Night** (dark-adaptation safe — chrome emits essentially no blue/green).
enum AppTheme: String, CaseIterable, Identifiable {
    case cockpit, day, night
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {       // SF Symbol for the theme switcher
        switch self {
        case .cockpit: return "circle.lefthalf.filled"
        case .day: return "sun.max.fill"
        case .night: return "moon.fill"
        }
    }
    /// System appearance for sheets/menus/keyboards. Single source for the
    /// `.preferredColorScheme(...)` call sites — day is light, everything else dark.
    var colorScheme: ColorScheme { self == .day ? .light : .dark }
}

/// Resolved colors for a theme.
struct Palette: Equatable {
    let bg, surface, surfaceAlt, text, textDim, accent, border, good, warn, bad: Color
    /// One step above `bg` — sheets, popovers, menus.
    let bgElevated: Color
    /// 1px separators — dimmer than `border` (which outlines controls).
    let hairline: Color
    /// Selected-state fills and pressed buttons; quiet cousin of `accent`.
    let accentMuted: Color
    /// Translucent flat scrim for bars floating over the map (replaces blur materials).
    let overlay: Color
}

extension AppTheme {
    var palette: Palette {
        switch self {
        case .cockpit:
            // Pure black base, hairline structure, FAA sectional blue as the single accent.
            return Palette(bg: .hex(0x000000), surface: .hex(0x0B0F13), surfaceAlt: .hex(0x060A0D),
                           text: .hex(0xE9EFF3), textDim: .hex(0x7C8B96), accent: .hex(0x4B9FDD),
                           border: .hex(0x202B34), good: .hex(0x35C77F), warn: .hex(0xE3B341), bad: .hex(0xE5534B),
                           bgElevated: .hex(0x12181E), hairline: .hex(0x151D24),
                           accentMuted: .hex(0x16354D), overlay: .hex(0x000000, alpha: 0.82))
        case .day:
            // Flat white paper separated by 1px lines, not tonal shifts; accent darkened for AA.
            return Palette(bg: .hex(0xFFFFFF), surface: .hex(0xFFFFFF), surfaceAlt: .hex(0xF4F6F8),
                           text: .hex(0x0B1215), textDim: .hex(0x55636D), accent: .hex(0x205F94),
                           border: .hex(0xD3DAE0), good: .hex(0x0E7A44), warn: .hex(0x8A6400), bad: .hex(0xBD3A30),
                           bgElevated: .hex(0xFFFFFF), hairline: .hex(0xE7EBEE),
                           accentMuted: .hex(0xD9E8F4), overlay: .hex(0xFFFFFF, alpha: 0.86))
        case .night:
            // Red-only emission on true black. good/warn keep a little green channel so the
            // status ladder stays distinguishable — same trade as red cockpit lighting.
            return Palette(bg: .hex(0x000000), surface: .hex(0x0D0404), surfaceAlt: .hex(0x070202),
                           text: .hex(0xE8503F), textDim: .hex(0x8C2F26), accent: .hex(0xFF6A50),
                           border: .hex(0x2A0E0A), good: .hex(0xD98A4A), warn: .hex(0xF5B04E), bad: .hex(0xFF4E3E),
                           bgElevated: .hex(0x150707), hairline: .hex(0x1A0806),
                           accentMuted: .hex(0x3A120C), overlay: .hex(0x000000, alpha: 0.85))
        }
    }
}

extension Palette {
    /// Color for a transcription speed (× real-time, = 1/RTF): green when comfortably keeping up,
    /// amber when it's getting tight, red when it can't keep up with real time. Drives the
    /// RTF/speed readouts so a degrading device is obvious at a glance.
    func speedColor(realtime speed: Double) -> Color {
        if speed <= 0 { return textDim }
        if speed >= 1.2 { return good }   // comfortably faster than real time
        if speed >= 1.0 { return warn }   // keeping up, but tight
        return bad                        // falling behind real time
    }
}

extension Color {
    static func hex(_ value: UInt) -> Color {
        hex(value, alpha: 1.0)
    }
    static func hex(_ value: UInt, alpha: Double) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255.0,
              green: Double((value >> 8) & 0xFF) / 255.0,
              blue: Double(value & 0xFF) / 255.0,
              opacity: alpha)
    }
}
