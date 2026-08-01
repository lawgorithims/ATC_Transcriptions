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
    /// The VISUAL glideslope angle, degrees — from NASR, not from the plate. See the note on
    /// `vgsiDisagreement` for why this matters and why the plate-text parser was withdrawn.
    let vgsiAngleDeg: Double?

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
        // ⚠️ MATCH THE SYSTEM PREFIX, NOT THE FIRST LETTER. Taking `c.first` made every P-coded value a
        // "PAPI" — but PSIL/PSIR (69 rows) are the PVASI, a pulsating/steady SINGLE unit, and PNIL/PNIR
        // (13) are the panel system. Neither is a PAPI, and telling a pilot to expect a four-box PAPI
        // where there is one pulsating light is a description of something they will not see. Enumerated
        // against every distinct value in the table, so an unlisted code returns nil and shows raw.
        let system: String
        switch true {
        case c.hasPrefix("PSI"): system = "PVASI (pulsating)"
        case c.hasPrefix("PNI"): system = "Panel system"
        case c.hasPrefix("TRI"): system = "Tri-colour VASI"
        case c.hasPrefix("VAS"): return "VASI"                    // unspecified configuration
        case c.hasPrefix("P"):   system = "PAPI"
        case c.hasPrefix("V"):   system = "VASI"
        case c.hasPrefix("S"):   system = "SAVASI"
        default: return nil                                       // incl. PVT — unspecified
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

extension ApproachBrief {

    /// ITEM 30 — the VISUAL glideslope angle.
    ///
    /// ⚠️ FROM NASR, NOT FROM THE PLATE. This was first built as a regex over the plate's text, on the
    /// belief that the angle was not in the bundle's source. It IS: `VISUAL_GLIDE_PATH_ANGLE` in
    /// APT_RWY_END.csv, which the builder was reading 15 of 80 columns from. The regex reached 28% of
    /// plates and an audit measured it catching the wrong number — a TCH, a course, a distance — because
    /// "any d.dd within 60 characters of PAPI" is not a specification. It has been withdrawn rather than
    /// kept as a fallback: a wrong angle here is worse than no angle, since the entire point is a
    /// cross-check the pilot would otherwise have to do by eye.

    /// Does the published VISUAL glideslope disagree with the coded descent angle by enough to matter?
    ///
    /// Half a degree is the threshold: at 1 NM that is roughly 50 ft of path difference, which is the
    /// point at which flying one while looking at the other becomes visible on the runway. Returns nil
    /// when either angle is unknown — silence, not a reassurance that they agree.
    static func vgsiDisagreement(codedAngleDeg: Double?, vgsiAngleDeg: Double?) -> Double? {
        guard let coded = codedAngleDeg, let vgsi = vgsiAngleDeg else { return nil }
        assert(coded > 0 && coded < 12, "vgsiDisagreement: implausible coded angle")
        let delta = abs(coded - vgsi)
        return delta >= 0.5 ? delta : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
