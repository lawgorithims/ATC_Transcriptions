import Foundation

/// The ten pressure/height levels the winds-aloft overlay carries — one detent each on the map's altitude
/// slider. GFS is a pressure-coordinate model, so every level above the surface is an isobaric surface and
/// the flight level shown to the pilot is the STANDARD-ATMOSPHERE altitude of that surface, not a measured
/// height (925 hPa is "about 2,500 ft"; on any given day it is a few hundred feet either side). That is the
/// same convention the FAA winds-aloft product uses, and it is why the labels are round numbers.
///
/// The raw ordering matters twice over: it is the slider's detent index (0 = ground, 9 = the jet stream)
/// AND the persisted value behind `atc.map.windLevel`, so cases may be appended but never reordered.
enum WindLevel: Int, CaseIterable, Codable, Sendable {
    case surface = 0        // 10 m above ground
    case mb925 = 1
    case mb850 = 2
    case mb700 = 3
    case mb600 = 4
    case mb500 = 5
    case mb400 = 6
    case mb300 = 7
    case mb250 = 8
    case mb200 = 9

    /// The NOMADS GRIB-filter query flag that selects this level (`&lev_850_mb=on`).
    var gribLevParam: String {
        switch self {
        case .surface: return "lev_10_m_above_ground"
        case .mb925:   return "lev_925_mb"
        case .mb850:   return "lev_850_mb"
        case .mb700:   return "lev_700_mb"
        case .mb600:   return "lev_600_mb"
        case .mb500:   return "lev_500_mb"
        case .mb400:   return "lev_400_mb"
        case .mb300:   return "lev_300_mb"
        case .mb250:   return "lev_250_mb"
        case .mb200:   return "lev_200_mb"
        }
    }

    /// GRIB2 product-template 4.0 level identity: type 103 = "specified height above ground" (metres),
    /// type 100 = "isobaric surface" (pascals). Used to match a decoded message back to its level.
    var levelTypeAndValue: (type: Int, value: Int) {
        switch self {
        case .surface: return (103, 10)          // 10 m AGL
        case .mb925:   return (100, 92_500)      // hPa → Pa
        case .mb850:   return (100, 85_000)
        case .mb700:   return (100, 70_000)
        case .mb600:   return (100, 60_000)
        case .mb500:   return (100, 50_000)
        case .mb400:   return (100, 40_000)
        case .mb300:   return (100, 30_000)
        case .mb250:   return (100, 25_000)
        case .mb200:   return (100, 20_000)
        }
    }

    /// The slider's tick label — standard-atmosphere altitude, in the form a pilot reads it.
    var shortLabel: String {
        switch self {
        case .surface: return "SFC"
        case .mb925:   return "2.5k"
        case .mb850:   return "5k"
        case .mb700:   return "10k"
        case .mb600:   return "14k"
        case .mb500:   return "FL180"
        case .mb400:   return "FL240"
        case .mb300:   return "FL300"
        case .mb250:   return "FL340"
        case .mb200:   return "FL390"
        }
    }

    /// Spoken/accessible form, and the value bubble's subtitle: "850 hPa" / "10 m AGL".
    var pressureLabel: String {
        let (type, value) = levelTypeAndValue
        return type == 103 ? "\(value) m AGL" : "\(value / 100) hPa"
    }

    /// Clamp a persisted or slider-derived index onto a real case. Never traps: a defaults value written by
    /// a future build with more levels must degrade to the highest level this build knows, not crash.
    static func at(index: Int) -> WindLevel {
        assert(!allCases.isEmpty, "WindLevel: no cases")
        let capped = min(max(index, 0), allCases.count - 1)
        assert(allCases.indices.contains(capped), "WindLevel: clamp produced an invalid index")
        return allCases[capped]
    }

    /// Matches a decoded GRIB message's level identity to a case, or nil for a level we didn't ask for.
    static func from(levelType: Int, levelValue: Int) -> WindLevel? {
        assert(levelType >= 0, "WindLevel: negative level type")
        assert(levelValue >= 0, "WindLevel: negative level value")
        return allCases.first { $0.levelTypeAndValue == (levelType, levelValue) }
    }
}
