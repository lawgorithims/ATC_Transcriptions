import Foundation

/// The approach BRIEF — the handful of facts a pilot reads out loud before flying an approach,
/// assembled once from data already on the device.
///
/// Deliberately a value type with no I/O: the reads happen in the caller, so this is unit-testable and
/// cannot become a database round trip inside a view body (the trap this file's neighbours document).
///
/// ⚠️ EVERY FIELD IS OPTIONAL AND ABSENCE IS RENDERED AS ABSENCE. Measured over the 5,983 runway ends
/// that have an instrument approach: touchdown-zone elevation and runway length are published on 100%,
/// edge lights on 99.1% and a visual glideslope on 87.8% — but APPROACH lights on only 20.3% (it rises
/// to 82.5% on ILS runways). A brief that printed a dash for the missing four-fifths would read as "no
/// approach lighting installed", which is a different and wrong statement. Absent rows are omitted.
struct ApproachBrief: Equatable {

    /// Final approach course, degrees magnetic. See `ApproachProfile` for why this can be absent.
    let inboundCourseMag: Double?
    /// The published minimum, when the plate has been parsed. nil is the common case — minima are
    /// chart-only data and `MinimaStore` never downloads — and nil must render as "read the plate",
    /// never as a figure.
    let minimum: Minimum?
    let runway: String
    let runwayLengthFt: Double?
    let touchdownZoneElevFt: Double?
    /// NASR approach-lighting system code ("MALSR", "ALSF2"…), "" when the source publishes none.
    /// ⚠️ EMPTY MEANS NOT PUBLISHED, NOT "none installed" — on an ILS runway a blank is almost certainly
    /// a NASR omission, since an ILS runway without an approach light system is rare.
    let approachLights: String
    /// NASR visual-glideslope code ("P4L" = PAPI 4-box left, "V2R" = VASI 2-box right…).
    let vgsi: String
    /// NASR runway edge-light intensity ("HIGH"/"MED"/"LOW"), "" when unlit or unpublished.
    let edgeLights: String

    struct Minimum: Equatable {
        /// ⚠️ ALWAYS NAMED IN THE UI. A published minimum is per approach CATEGORY, and this app does
        /// not know the pilot's — `PlateMinima.Category` lives only as transient view state. Quoting a
        /// bare figure would invite a Category C pilot to read a Category A number, so the category is
        /// carried with the value and must be displayed beside it.
        let category: PlateMinima.Category
        let altitudeFtMSL: Int
        /// True when the figure is a decision altitude flown through, false when it is a minimum
        /// descent altitude levelled at. The two are not interchangeable and the brief says which.
        let isDecisionAltitude: Bool
        /// The line it was read from — "LPV", "LNAV", "S-ILS"… so the pilot can check it on the chart.
        let lineLabel: String
    }

    /// Height of the published minimum above the touchdown zone, when both are known. This is the
    /// number a pilot actually cross-checks against the chart's own HAT.
    var heightAboveTouchdownFt: Int? {
        guard let minimum, let tdze = touchdownZoneElevFt else { return nil }
        let h = minimum.altitudeFtMSL - Int(tdze.rounded())
        // A negative or absurd height means the two numbers do not belong together — say nothing.
        guard h > 0, h < 3_000 else { return nil }
        return h
    }

    /// Is there anything worth showing? A brief with nothing but a runway number is not a brief.
    var hasContent: Bool {
        inboundCourseMag != nil || minimum != nil || runwayLengthFt != nil
            || touchdownZoneElevFt != nil || !approachLights.isEmpty || !vgsi.isEmpty
    }
}

extension ApproachBrief {

    /// Plain-English decode of a NASR visual-glideslope code, or nil when it is not one this app knows.
    ///
    /// The point of item 33's "graphic decoding the acronym" — a pilot should not have to remember that
    /// P4L is a four-box PAPI on the left. The letter is the SYSTEM, the digit the box count, the last
    /// letter the side. Unrecognised codes return nil rather than a partial guess: NSTD ("non-standard")
    /// in particular means the installation does not follow the usual pattern, and expanding it into a
    /// confident sentence would be exactly wrong.
    static func decodeVGSI(_ code: String) -> String? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard c.count >= 2, !c.hasPrefix("NSTD") else { return nil }
        let system: String
        switch c.first {
        case "P": system = "PAPI"
        case "V": system = "VASI"
        case "S": system = "SAVASI"
        case "T": system = "Tri-colour VASI"
        case "R": system = "Pulsating"
        default:  return nil
        }
        let digits = c.dropFirst().prefix { $0.isASCIIDigit }
        let side: String?
        switch c.last {
        case "L": side = "left"
        case "R": side = "right"
        default:  side = nil
        }
        var out = system
        if let n = Int(digits), n > 0, n <= 8 { out += ", \(n) box\(n == 1 ? "" : "es")" }
        if let side { out += " on the \(side)" }
        return out
    }

    /// Plain-English decode of a NASR approach-lighting code.
    ///
    /// Only the systems that actually appear are named — measured over the whole table, 14 distinct
    /// codes with MALSR (860) and ALSF-2 (184) dominant. An unknown code returns nil so the raw acronym
    /// is shown rather than a wrong expansion.
    static func decodeApproachLights(_ code: String) -> String? {
        switch code.trimmingCharacters(in: .whitespaces).uppercased() {
        case "ALSF1":  return "ALSF-1 — high intensity, sequenced flashers, red side rows"
        case "ALSF2":  return "ALSF-2 — high intensity, sequenced flashers, CAT II/III"
        case "SSALR":  return "SSALR — simplified short, sequenced flashers"
        case "SSALS":  return "SSALS — simplified short"
        case "SSALF":  return "SSALF — simplified short, sequenced flashers"
        case "MALSR":  return "MALSR — medium intensity with runway alignment lights"
        case "MALSF":  return "MALSF — medium intensity with sequenced flashers"
        case "MALS":   return "MALS — medium intensity"
        case "SALS":   return "SALS — short approach lighting"
        case "SALSF":  return "SALSF — short approach lighting with flashers"
        case "ALSAF":  return "ALSAF — high intensity with sequenced flashers"
        case "ODALS":  return "ODALS — omnidirectional flashers only"
        case "RLLS":   return "Runway lead-in lights"
        default:       return nil            // incl. NSTD — say the code, not a guess
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
