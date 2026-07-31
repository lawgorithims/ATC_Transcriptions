import Foundation

/// Turns the published table into THE NUMBER — the one altitude and the one visibility that apply to this
/// aeroplane, on this approach, in these conditions, right now.
///
/// This is the arithmetic a pilot otherwise does in the cockpit from three places at once: the minima
/// table for the category and the line being flown, the plate's notes for the temperature and altimeter
/// penalties, and the front matter of the chart book for the inoperative-components table. Each step is
/// small; doing all of them correctly while flying an approach is not, and the failure is silent.
///
/// EVERY STEP IS SHOWN. The solver never returns a bare figure — it returns the base value it started
/// from and the ordered list of adjustments it applied, so the result can be checked against the plate in
/// a couple of seconds. A number a pilot cannot verify is a number they should not use.
///
/// WHAT IT REFUSES TO COMPUTE. Where a plate carries an adjustment in prose that this cannot reduce to
/// arithmetic, it is surfaced VERBATIM as an advisory and the figure is left alone. Showing the sentence
/// and letting the pilot apply it is safe; guessing what it meant is not.
enum MinimaSolver {

    // MARK: request

    /// Components whose failure raises the visibility required. Named as the chart names them.
    enum InopComponent: String, CaseIterable, Identifiable, Equatable {
        case approachLights = "Approach lighting (ALSF/MALSR/SSALR)"
        case shortApproachLights = "Short approach lighting (MALS/SSALS/ODALS)"
        case touchdownZoneAndCenterline = "TDZL / RCLS"
        case rvrReadout = "RVR readout"
        var id: String { rawValue }
    }

    struct Request: Equatable {
        var category: PlateMinima.Category = .a
        var kind: PlateMinima.Kind = .ils
        /// Which row of that kind, when a plate publishes more than one. Boston's RNAV 4L prints two
        /// `LNAV/VNAV DA` lines — an ordinary one and a starred one with minima nearly a hundred feet
        /// lower — and showing only the first would hide a published line from the pilot entirely.
        var lineIndex: Int = 0
        /// Conditional blocks the pilot has answered YES to, by heading.
        var conditionals: Set<String> = []
        var inoperative: Set<InopComponent> = []
        /// True when the altimeter setting is not the local one — the plate's remote-altimeter penalty.
        var remoteAltimeter = false
        /// Outside air temperature at the field, °C. Drives the Baro-VNAV limit; nil when unknown, and an
        /// unknown temperature is reported as unknown rather than assumed to be inside the window.
        var temperatureC: Double?
    }

    // MARK: result

    struct Step: Equatable, Identifiable {
        let text: String
        /// Where the rule came from — the pilot has to be able to go and check it.
        let source: String
        var id: String { text + source }
    }

    struct Solution: Equatable {
        let label: String
        let usesDecisionAltitude: Bool
        let altitudeFtMSL: Int?
        let visibility: PlateMinima.Visibility?
        let base: PlateMinima.Value
        let steps: [Step]
        /// Set when the line may not be flown at all in the stated conditions.
        let notAuthorised: String?
        /// Prose from the plate that changes the answer but was not reduced to arithmetic.
        let advisories: [String]

        var isUsable: Bool { notAuthorised == nil && altitudeFtMSL != nil }
        /// `DA` or `MDA` — not interchangeable, and the label is half the meaning of the number.
        var altitudeKind: String { usesDecisionAltitude ? "DA" : "MDA" }
    }

    // MARK: solve

    static func solve(_ minima: PlateMinima, request: Request) -> Solution? {
        guard let row = row(in: minima, kind: request.kind, lineIndex: request.lineIndex,
                            conditionals: request.conditionals),
              let base = row.values[request.category] else { return nil }
        assert(!row.label.isEmpty, "MinimaSolver: unlabelled row")

        var steps: [Step] = []
        var advisories: [String] = []
        var altitude = base.altitudeFtMSL
        var visibility = base.visibility
        var notAuthorised: String? = base.isNA ? "Published NA for Category \(request.category.rawValue)." : nil

        // Conditional blocks that were answered yes and DID supply a replacement row.
        for c in minima.conditionals.prefix(8) where request.conditionals.contains(c.heading) {
            if c.rows.contains(where: { $0.kind == request.kind }) {
                steps.append(Step(text: "Using the minima published for: \(c.question.dropLast())",
                                  source: "This plate"))
            }
        }

        // Temperature limit on Baro-VNAV. This one can forbid the line outright.
        if request.kind == .baroVNAV, let limit = temperatureLimit(minima) {
            switch temperatureVerdict(limit, temperatureC: request.temperatureC) {
            case .outside(let why): notAuthorised = notAuthorised ?? why
            case .unknown(let why): advisories.append(why)
            case .inside: break
            }
        }

        // Remote altimeter setting: a published increase in feet, applied to the altitude.
        if request.remoteAltimeter, let note = altimeterPenalty(minima), let add = note.addFt {
            if let a = altitude {
                altitude = a + add
                steps.append(Step(text: "Not using the local altimeter setting: +\(add) ft",
                                  source: note.source.isEmpty ? "This plate" : "\(note.source) altimeter setting"))
            }
        }

        // Inoperative components raise the visibility, never the altitude.
        if !request.inoperative.isEmpty {
            let outcome = InopTable.apply(inoperative: request.inoperative,
                                          kind: request.kind,
                                          category: request.category,
                                          visibility: visibility)
            if let v = outcome.visibility, v != visibility {
                steps.append(Step(text: "\(outcome.reason): visibility \(v.label)", source: InopTable.source))
                visibility = v
            } else if let r = outcome.uncomputed {
                advisories.append(r)
            }
        }

        // Night restrictions and anything else the plate flags for this line.
        for note in minima.notes.prefix(12) {                     // bounded (rule 2)
            if case .nightRestriction(let text) = note.effect, applies(text, to: request.kind) {
                advisories.append(text)
            }
        }

        return Solution(label: row.label,
                        usesDecisionAltitude: request.kind.usesDecisionAltitude,
                        altitudeFtMSL: notAuthorised == nil ? altitude : nil,
                        visibility: notAuthorised == nil ? visibility : nil,
                        base: base,
                        steps: steps,
                        notAuthorised: notAuthorised,
                        advisories: advisories)
    }

    /// The row to read: a conditional block's version when its condition is engaged, otherwise the base.
    static func row(in minima: PlateMinima, kind: PlateMinima.Kind, lineIndex: Int = 0,
                    conditionals: Set<String>) -> PlateMinima.Row? {
        for c in minima.conditionals.prefix(8) where conditionals.contains(c.heading) {
            let matches = c.rows.filter { $0.kind == kind }
            if !matches.isEmpty { return matches[min(lineIndex, matches.count - 1)] }
        }
        let matches = minima.rows.filter { $0.kind == kind }
        guard !matches.isEmpty else { return nil }
        return matches[min(lineIndex, matches.count - 1)]
    }

    /// Every line the plate publishes, in printed order, as (kind, index-within-kind).
    static func availableLines(_ minima: PlateMinima) -> [(kind: PlateMinima.Kind, index: Int)] {
        var counts: [PlateMinima.Kind: Int] = [:]
        var out: [(PlateMinima.Kind, Int)] = []
        for r in minima.rows.prefix(32) {                         // bounded (rule 2)
            let i = counts[r.kind, default: 0]
            out.append((r.kind, i))
            counts[r.kind] = i + 1
        }
        return out
    }

    // MARK: notes

    struct AltimeterPenalty { let addFt: Int?; let source: String }

    static func altimeterPenalty(_ minima: PlateMinima) -> AltimeterPenalty? {
        for n in minima.notes.prefix(12) {                        // bounded (rule 2)
            if case .altimeterPenalty(let add, let source) = n.effect {
                return AltimeterPenalty(addFt: add, source: source)
            }
        }
        return nil
    }

    static func temperatureLimit(_ minima: PlateMinima) -> (minC: Int?, maxC: Int?)? {
        for n in minima.notes.prefix(12) {                        // bounded (rule 2)
            if case .baroVNAVTemperatureLimit(let lo, let hi) = n.effect { return (lo, hi) }
        }
        return nil
    }

    enum TemperatureVerdict: Equatable { case inside, outside(String), unknown(String) }

    /// Is the Baro-VNAV line authorised at this temperature?
    ///
    /// The limit is on the AIRCRAFT's uncompensated barometric vertical guidance, not on the procedure: in
    /// cold air the true height of a barometric path sits below the indicated one, and the error grows
    /// toward the ground. Outside the published window the line is not available, and an unknown
    /// temperature is reported as unknown — never quietly treated as inside.
    static func temperatureVerdict(_ limit: (minC: Int?, maxC: Int?), temperatureC: Double?) -> TemperatureVerdict {
        guard let t = temperatureC else {
            let lo = limit.minC.map { "\($0)°C" } ?? "the published limit"
            return .unknown("LNAV/VNAV is NA below \(lo) for uncompensated Baro-VNAV — field temperature unknown.")
        }
        if let lo = limit.minC, t < Double(lo) {
            return .outside("LNAV/VNAV NA: \(Int(t.rounded()))°C is below the published \(lo)°C limit for uncompensated Baro-VNAV.")
        }
        if let hi = limit.maxC, t > Double(hi) {
            return .outside("LNAV/VNAV NA: \(Int(t.rounded()))°C is above the published \(hi)°C limit for uncompensated Baro-VNAV.")
        }
        return .inside
    }

    /// Does a `… NA at night` restriction bear on the line being flown?
    static func applies(_ text: String, to kind: PlateMinima.Kind) -> Bool {
        let u = text.uppercased()
        if u.hasPrefix("PROCEDURE") { return true }
        if u.hasPrefix("CIRCLING") { return kind == .circling }
        if u.hasPrefix("STRAIGHT-IN") { return kind != .circling }
        return true
    }
}

/// The FAA's INOPERATIVE COMPONENTS OR VISUAL AIDS TABLE, from the front matter of every Terminal
/// Procedures volume.
///
/// It raises the VISIBILITY required when a component of the approach lighting or the runway's touchdown
/// aids has failed; it never changes the altitude. The table is organised by the kind of approach, and
/// the rules differ in a way that matters: on an ILS whose published visibility is RVR 1800 or 2000 the
/// loss of the approach lights takes it to RVR 4000, while on a localizer or VOR the same failure adds
/// half a mile to whatever is published.
///
/// It does NOT apply to LPV, LNAV/VNAV or LP lines. Those carry their own inoperative notes on the plate
/// itself, so this returns an `uncomputed` prompt for them and leaves the number alone rather than
/// applying a rule that was written for a different kind of approach.
enum InopTable {

    static let source = "Inoperative Components or Visual Aids Table, TPP front matter"

    struct Outcome {
        var visibility: PlateMinima.Visibility?
        var reason: String = ""
        var uncomputed: String?
    }

    static func apply(inoperative: Set<MinimaSolver.InopComponent>,
                      kind: PlateMinima.Kind,
                      category: PlateMinima.Category,
                      visibility: PlateMinima.Visibility?) -> Outcome {
        guard let vis = visibility, !inoperative.isEmpty else { return Outcome(visibility: visibility) }

        switch kind {
        case .lpv, .baroVNAV, .lp, .rnpAR, .gls:
            return Outcome(visibility: vis,
                           uncomputed: "This line is not covered by the inoperative-components table — read the plate's own inoperative note.")
        case .circling:
            // Circling minima are not raised by the table; the visibility is the one published.
            return Outcome(visibility: vis)
        case .ils:
            return ilsOutcome(inoperative, vis)
        default:
            return groundBasedOutcome(inoperative, category, vis)
        }
    }

    /// ILS: the published visibility decides which rule applies.
    private static func ilsOutcome(_ inop: Set<MinimaSolver.InopComponent>,
                                   _ vis: PlateMinima.Visibility) -> Outcome {
        let lowRVR: Bool
        if case .rvrFt(let f) = vis { lowRVR = f <= 2_000 } else { lowRVR = false }
        var out = vis
        var reason = ""
        if inop.contains(.approachLights) {
            let target: PlateMinima.Visibility = lowRVR ? .rvrFt(4_000) : .rvrFt(2_400)
            if target > out { out = target; reason = "Approach lighting inoperative" }
        }
        if inop.contains(.touchdownZoneAndCenterline), lowRVR {
            let target = PlateMinima.Visibility.rvrFt(2_400)
            if target > out { out = target; reason = reason.isEmpty ? "TDZL/RCLS inoperative" : reason + " and TDZL/RCLS inoperative" }
        }
        if inop.contains(.rvrReadout) {
            // RVR unusable: the equivalent statute-mile figure is flown instead.
            out = statuteEquivalent(out)
            reason = reason.isEmpty ? "RVR inoperative" : reason + ", RVR inoperative"
        }
        return Outcome(visibility: out, reason: reason.isEmpty ? "Inoperative components" : reason)
    }

    /// LOC, LDA, SDF, VOR, NDB, GPS overlay: a flat increase in statute miles.
    private static func groundBasedOutcome(_ inop: Set<MinimaSolver.InopComponent>,
                                           _ category: PlateMinima.Category,
                                           _ vis: PlateMinima.Visibility) -> Outcome {
        var addSixteenths = 0
        var reason = ""
        if inop.contains(.approachLights) {
            addSixteenths = max(addSixteenths, 8)                 // ½ mile
            reason = "Approach lighting inoperative"
        } else if inop.contains(.shortApproachLights) {
            addSixteenths = max(addSixteenths, 4)                 // ¼ mile
            reason = "Short approach lighting inoperative"
        }
        guard addSixteenths > 0 else { return Outcome(visibility: vis) }
        let current = sixteenths(of: vis)
        return Outcome(visibility: .statuteSixteenths(current + addSixteenths), reason: reason, uncomputed: nil)
    }

    /// The RVR/visibility comparable-values table, used only where RVR is unusable.
    static func statuteEquivalent(_ v: PlateMinima.Visibility) -> PlateMinima.Visibility {
        guard case .rvrFt(let f) = v else { return v }
        switch f {
        case ...1_600: return .statuteSixteenths(4)               // ¼
        case ...2_400: return .statuteSixteenths(8)               // ½
        case ...3_200: return .statuteSixteenths(10)              // ⅝
        case ...4_000: return .statuteSixteenths(12)              // ¾
        case ...4_500: return .statuteSixteenths(14)              // ⅞
        case ...5_000: return .statuteSixteenths(16)              // 1
        default:       return .statuteSixteenths(20)              // 1¼
        }
    }

    static func sixteenths(of v: PlateMinima.Visibility) -> Int {
        switch v {
        case .statuteSixteenths(let s): return s
        case .rvrFt:
            guard case .statuteSixteenths(let s) = statuteEquivalent(v) else { return 8 }
            return s
        }
    }
}
