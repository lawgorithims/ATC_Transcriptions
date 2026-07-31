import Foundation

/// One NOTAM, as the app needs it.
///
/// Awareness context, never a briefing — the same standing caveat as TFRs, and stated on screen rather
/// than buried here. What matters structurally is that a NOTAM is a piece of TEXT with a validity
/// window: the classification below exists to PROMOTE what bears on the procedure in use, never to
/// remove anything from the pilot's view.
struct Notam: Identifiable, Sendable, Equatable, Codable {
    let id: String                 // NOTAM number, e.g. "04/123"
    let icao: String               // the aerodrome it was issued for
    let text: String               // the raw NOTAM body
    /// The FAA's own plain-language rendering when it supplied one — preferred for display, but the raw
    /// text is what gets classified, because either can carry the operative phrase.
    let plainText: String?
    let classification: String?    // INTL | MIL | DOM | LMIL | FDC
    let effectiveStart: Date?
    let effectiveEnd: Date?        // nil = open-ended / permanent
    let issued: Date?
    /// Coordinates when the record carried them — item 39 draws these on the airport diagram.
    let lat: Double?
    let lon: Double?
    let radiusNm: Double?

    var coord: Coord? {
        guard let lat, let lon else { return nil }
        return Coord(lat: lat, lon: lon)
    }

    /// Is this NOTAM in force at `now`?
    ///
    /// A MISSING bound is open-ended on that side — the same rule `TFR.window(at:)` uses. An
    /// unparseable end date is never treated as expired, because the failure that matters is hiding a
    /// NOTAM that is still in force.
    func isActive(at now: Date = Date()) -> Bool {
        if let s = effectiveStart, now < s { return false }
        if let e = effectiveEnd, now > e { return false }
        return true
    }

    /// The text the classifier reads: the raw body UNIONED with the plain-language rendering, because
    /// the operative phrase can appear in either.
    var searchText: String {
        ([text, plainText].compactMap { $0 }).joined(separator: " ").uppercased()
    }
}

/// What a NOTAM bears on. Used to PIN the relevant ones to the top — never to filter.
enum NotamKind: String, Sendable, Equatable, Codable, CaseIterable {
    case runwayClosed, navaidOut, lightingOut, rvrOut, approachNA, obstacle, other

    var label: String {
        switch self {
        case .runwayClosed: return "Runway closed"
        case .navaidOut:    return "Navaid out of service"
        case .lightingOut:  return "Lighting out of service"
        case .rvrOut:       return "RVR out of service"
        case .approachNA:   return "Approach not authorised"
        case .obstacle:     return "Obstacle"
        case .other:        return "Other"
        }
    }
    var icon: String {
        switch self {
        case .runwayClosed: return "xmark.square.fill"
        case .navaidOut:    return "antenna.radiowaves.left.and.right.slash"
        case .lightingOut:  return "lightbulb.slash.fill"
        case .rvrOut:       return "eye.slash.fill"
        case .approachNA:   return "exclamationmark.octagon.fill"
        case .obstacle:     return "cone.fill"
        case .other:        return "doc.text"
        }
    }
}

/// A NOTAM with what the classifier made of it.
struct ClassifiedNotam: Identifiable, Sendable, Equatable {
    let notam: Notam
    let kind: NotamKind
    /// Runways named in the text. EMPTY means "no runway named", which is read as applying to ALL of
    /// them — see `NotamRelevance`.
    let runways: [String]
    /// True when the classifier recognised nothing in it. These are PINNED, not dropped: the
    /// classifier's job is to promote what it understands, never to demote what it does not.
    let unclassified: Bool
    var id: String { notam.id }
}

/// Why the NOTAM list is empty, which is never allowed to be ambiguous.
///
/// "No NOTAMs" and "no API key" and "the fetch failed" look identical as an empty list, and only one of
/// them means the pilot has nothing to read. Only `.ok` may ever render as "none".
enum NotamFeedState: Sendable, Equatable {
    case noCredential
    case loading
    case ok(fetchedAt: Date)
    case failed(String)

    /// May a zero count be displayed as "no NOTAMs"? Only from a successful fetch.
    var mayReportEmpty: Bool { if case .ok = self { return true }; return false }
}
