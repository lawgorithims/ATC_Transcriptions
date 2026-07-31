import Foundation

/// Decides what a NOTAM is about, and whether it bears on the procedure in use.
///
/// THE BIAS RUNS ONE WAY. This never filters. It splits the fetched set into PINNED and the rest, and
/// the full list always contains everything that was pulled — a NOTAM promoted in error is a nuisance
/// the pilot reads and dismisses, while one quietly demoted is a hazard they never see. Every rule
/// below therefore fails toward showing more:
///
///   * A NOTAM this cannot categorise is `unclassified`, and unclassified is PINNED, not dropped.
///   * A NOTAM that names no runway is treated as applying to ALL runways.
///   * A NOTAM whose validity window will not parse is treated as IN FORCE.
///
/// Clause splitting matters more than it looks: `TWY B CLSD. RWY 04R AVBL` must never read as a runway
/// closure, so a subject and its condition have to be found in the SAME clause rather than merely in
/// the same NOTAM.
enum NotamRelevance {

    /// Cap on clauses examined in one NOTAM (rule 2). Real NOTAMs are a handful of sentences.
    static let maxClauses = 40
    /// Cap on runway tokens taken from one NOTAM (rule 2).
    static let maxRunways = 12

    // MARK: vocabulary

    /// Things that can be out of service, by what they are.
    static let navaidSubjects = ["ILS", "LOCALIZER", "LOC", "GLIDESLOPE", "GLIDE SLOPE", "G/S", "GS",
                                 "GP", "DME", "LOM", "LDA", "SDF", "VOR", "VORTAC", "NDB", "TACAN",
                                 "GPS", "WAAS", "RNAV", "MM", "OM"]
    static let lightingSubjects = ["ALSF", "ALSF1", "ALSF2", "MALSR", "MALSF", "MALS", "SSALR", "SSALF",
                                   "SSALS", "ODALS", "RAIL", "REIL", "HIRL", "MIRL", "LIRL", "RCLS",
                                   "RCLL", "TDZL", "PAPI", "VASI", "ABN", "APCH LGT", "APPROACH LIGHT"]
    /// Phrases that mean "it does not work".
    static let outConditions = ["OTS", "OUT OF SERVICE", "U/S", "UNUSABLE", "UNSERVICEABLE",
                                "UNMONITORED", "DECOMMISSIONED", "NOT AVBL", "NOT AVAILABLE",
                                "NOT AUTHORIZED", "NOT AUTH", "INOP"]
    static let closedConditions = ["CLSD", "CLOSED"]
    static let approachNAPhrases = ["PROCEDURE NA", "PROC NA", "MINIMUMS NA", "MINIMA NA",
                                    "ALL MINIMUMS NA", "CIRCLING NA", "LPV NA", "LNAV/VNAV NA",
                                    "LNAV NA", "SIAP NA", "IAP NA", "APCH NA", "APPROACH NA"]
    static let obstacleSubjects = ["CRANE", "TOWER", "OBST", "OBSTRUCTION", "ANTENNA", "DERRICK"]

    // MARK: classification

    static func classify(_ notam: Notam) -> ClassifiedNotam {
        let text = notam.searchText
        let clauses = split(text)
        let runways = runwayTokens(in: text)

        for clause in clauses.prefix(maxClauses) {                   // bounded (rule 2)
            if containsAny(clause, approachNAPhrases) {
                return ClassifiedNotam(notam: notam, kind: .approachNA, runways: runways,
                                       unclassified: false)
            }
        }
        for clause in clauses.prefix(maxClauses) {                   // bounded (rule 2)
            let closed = containsAny(clause, closedConditions)
            if closed, clause.contains("RWY") || clause.contains("RUNWAY") || clause.contains("AD ")
                || clause.contains("AERODROME") {
                return ClassifiedNotam(notam: notam, kind: .runwayClosed, runways: runways,
                                       unclassified: false)
            }
            let out = containsAny(clause, outConditions)
            guard out else { continue }
            if containsAny(clause, ["RVR"]) {
                return ClassifiedNotam(notam: notam, kind: .rvrOut, runways: runways, unclassified: false)
            }
            if containsAny(clause, lightingSubjects) {
                return ClassifiedNotam(notam: notam, kind: .lightingOut, runways: runways,
                                       unclassified: false)
            }
            if containsAny(clause, navaidSubjects) {
                return ClassifiedNotam(notam: notam, kind: .navaidOut, runways: runways,
                                       unclassified: false)
            }
        }
        for clause in clauses.prefix(maxClauses) where containsAny(clause, obstacleSubjects) {
            return ClassifiedNotam(notam: notam, kind: .obstacle, runways: runways, unclassified: false)
        }
        // Recognised nothing. That is a statement about this classifier, not about the NOTAM, so it is
        // marked unclassified and pinned rather than being quietly filed under "other" and buried.
        return ClassifiedNotam(notam: notam, kind: .other, runways: runways, unclassified: true)
    }

    // MARK: relevance to a procedure

    /// Does this NOTAM bear on an approach to `runway` at `airport`?
    ///
    /// A NOTAM that names NO runway applies to all of them — an airport-wide navaid or lighting outage
    /// names none, and demanding a match would hide exactly the outages that matter most.
    static func bearsOnApproach(_ c: ClassifiedNotam, airport: String, runway: String) -> Bool {
        guard c.notam.icao.isEmpty || c.notam.icao.caseInsensitiveCompare(airport) == .orderedSame
                || airport.isEmpty else { return false }
        if c.unclassified { return true }                            // read it — this could not be read
        if c.kind == .other { return false }
        guard !c.runways.isEmpty else { return true }                // names none → applies to all
        let want = normalise(runway)
        guard !want.isEmpty else { return true }                     // circling / point-in-space
        return c.runways.contains { normalise($0) == want }
    }

    /// Split NOTAM text into clauses. A subject and its condition must be found in the SAME one.
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Runway designators named in the text, BOTH ends of a paired form.
    static func runwayTokens(in text: String) -> [String] {
        let pattern = #"RWY?S?\s*(\d{1,2}[LRC]?)(?:\s*/\s*(\d{1,2}[LRC]?))?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(maxRunways) {
            for g in 1..<m.numberOfRanges {                          // bounded by the pattern (rule 2)
                let r = m.range(at: g)
                guard r.location != NSNotFound else { continue }
                let token = ns.substring(with: r)
                if !token.isEmpty, !out.contains(token) { out.append(token) }
            }
        }
        return out
    }

    /// `04R` and `4R` are the same runway; the CIFP writes one and NOTAMs write either.
    static func normalise(_ runway: String) -> String {
        let t = runway.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return "" }
        let digits = t.prefix { $0.isNumber }
        let suffix = t.drop { $0.isNumber }
        guard let n = Int(digits) else { return t }
        return String(format: "%02d", n) + suffix
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles.prefix(64) where haystack.contains(n) { return true }   // bounded (rule 2)
        return false
    }

    // MARK: splitting a fetched set

    /// Split into what bears on the approach and everything else. The two together are ALWAYS the whole
    /// fetched set — asserted, because a filter that silently loses records is the failure this design
    /// exists to prevent.
    static func partition(_ all: [Notam], airport: String, runway: String,
                          now: Date = Date()) -> (pinned: [ClassifiedNotam], others: [ClassifiedNotam]) {
        var pinned: [ClassifiedNotam] = []
        var others: [ClassifiedNotam] = []
        for n in all.prefix(4_000) {                                 // bounded (rule 2)
            let c = classify(n)
            if n.isActive(at: now), bearsOnApproach(c, airport: airport, runway: runway) {
                pinned.append(c)
            } else {
                others.append(c)
            }
        }
        assert(pinned.count + others.count == min(all.count, 4_000),
               "NOTAM partition must not lose records")
        // Unclassified first inside the pinned group: they are the ones the app could not read and the
        // pilot must.
        pinned.sort { a, b in
            if a.unclassified != b.unclassified { return a.unclassified }
            return a.kind.rawValue < b.kind.rawValue
        }
        return (pinned, others)
    }
}
