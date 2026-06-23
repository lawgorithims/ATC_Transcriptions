import SwiftUI

/// The three appearance modes from the browser console: a dark teal **Cockpit**, a
/// light **Day**, and a red night-vision **Night**.
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
}

/// Resolved colors for a theme.
struct Palette {
    let bg, surface, surfaceAlt, text, textDim, accent, border, good, warn, bad: Color
}

extension AppTheme {
    var palette: Palette {
        switch self {
        case .cockpit:
            return Palette(bg: .hex(0x0B1117), surface: .hex(0x131E29), surfaceAlt: .hex(0x0F1A23),
                           text: .hex(0xE6F0F6), textDim: .hex(0x8AA0B0), accent: .hex(0x2EE6A6),
                           border: .hex(0x223342), good: .hex(0x2EE6A6), warn: .hex(0xF5C451), bad: .hex(0xFF6B6B))
        case .day:
            return Palette(bg: .hex(0xEEF2F6), surface: .hex(0xFFFFFF), surfaceAlt: .hex(0xF6F9FC),
                           text: .hex(0x17242E), textDim: .hex(0x5D6B78), accent: .hex(0x0A84FF),
                           border: .hex(0xD9E2EA), good: .hex(0x12A150), warn: .hex(0xB9820A), bad: .hex(0xD64545))
        case .night:
            return Palette(bg: .hex(0x140808), surface: .hex(0x200F0F), surfaceAlt: .hex(0x190A0A),
                           text: .hex(0xF2D2D2), textDim: .hex(0xC09090), accent: .hex(0xFF6B5A),
                           border: .hex(0x3A1F1F), good: .hex(0xFF9A6A), warn: .hex(0xFFB45A), bad: .hex(0xFF5A5A))
        }
    }
}

extension Color {
    static func hex(_ value: UInt) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255.0,
              green: Double((value >> 8) & 0xFF) / 255.0,
              blue: Double(value & 0xFF) / 255.0,
              opacity: 1.0)
    }
}
