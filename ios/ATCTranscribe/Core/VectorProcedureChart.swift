import Foundation

/// A published procedure as DRAWABLE GEOMETRY rather than a picture of one — the vector chart
/// (items 1–7 and 9).
///
/// The app already draws procedures as an overlay on the moving map. This is the other thing a pilot
/// needs: the procedure ALONE, framed to itself, at a scale it states, so it can be read the way the
/// plate's plan view is read. Every primitive carries what it needs to be drawn at any zoom, which is
/// what makes it scalable (item 5) rather than a fixed rendering.
///
/// ⚠️ WHAT THIS DELIBERATELY DOES NOT DRAW, because the data is not there:
///   * MSA RINGS. Minimum sector altitudes are not in the bundle — no table in cifp.sqlite carries
///     them (verified column by column). Drawing a ring at a guessed radius or a guessed altitude would
///     be inventing a terrain-clearance guarantee, which is the worst class of error this app can make.
///   * CIRCLING PROTECTED AREAS, for the reason recorded in the audit: the expanded-radius marker is
///     printed on 2 of 7,476 plates, so the app cannot tell which TERPS standard applies, and the two
///     differ by miles.
/// The plate remains the authority for both, and the chart says so rather than leaving a gap that looks
/// like an answer.
struct VectorProcedureChart: Equatable {

    let airport: String
    let procedureName: String
    let kind: String                       // "IAP" / "SID" / "STAR"
    let primitives: [Primitive]
    /// Every coordinate the chart draws, for fitting the view to it.
    let extent: [Coord]

    /// One drawable thing. Deliberately geometry + meaning, never pixels: the view decides how a
    /// `.fix` with role `.finalApproachFix` looks, so the same model serves the day, night and
    /// decluttered palettes without re-deriving anything.
    enum Primitive: Equatable {
        /// The flown track. Already includes interpolated arc interiors, so a DME arc is a curve here.
        case track([Coord])
        /// A named fix, with everything published about it.
        case fix(Fix)
        /// The landing runway, drawn to scale from its own thresholds.
        case runway(from: Coord, to: Coord, designator: String)
        /// A leg the source describes but cannot place — "climb heading 040 to 2000". Drawn as a
        /// labelled ray from the last known point, NEVER as a line to a fabricated endpoint.
        case unplacedLeg(from: Coord, courseMag: Double?, text: String)
    }

    struct Fix: Equatable {
        let ident: String
        let coord: Coord
        let role: LegRole
        let constraint: LegConstraint?
        /// The detail tier at which this fix's ident becomes worth drawing. The fixes that define the
        /// SHAPE of the procedure — the final approach fix, the missed approach point, the initial fix —
        /// are named even in the overview, because without them the outline is anonymous.
        var identTier: ChartDetail {
            switch role {
            case .finalApproachFix, .missedApproachPoint, .initialApproachFix: return .overview
            default: return .idents
            }
        }
    }

    /// Build from an approach's coded legs (the same legs the map draws, so the two cannot disagree).
    ///
    /// `arcInterior` is injected rather than recomputed so this stays pure and the map and the chart
    /// share one arc implementation — a second one would drift.
    static func build(legs: [CIFPLeg], airport: String, procedureName: String, kind: String,
                      runwayThresholds: (from: Coord, to: Coord, designator: String)? = nil,
                      arcInterior: (Coord, Coord, Coord) -> [Coord] = ProcedureRoute.arcPoints)
        -> VectorProcedureChart {
        var primitives: [Primitive] = []
        var track: [Coord] = []
        var extent: [Coord] = []
        var fixes: [Fix] = []

        for leg in legs.prefix(512) {                                     // bounded (rule 2)
            guard let c = leg.coord else {
                // An altitude- or heading-terminated leg has no endpoint. Say what it is and where it
                // starts; do not draw a line to a point the source never published.
                if let from = track.last {
                    primitives.append(.unplacedLeg(from: from, courseMag: leg.course,
                                                   text: Self.unplacedText(leg)))
                }
                continue
            }
            // Curves: the arc interior goes in BEFORE the endpoint, exactly as on the map.
            if leg.legType == "AF" || leg.legType == "RF", let from = track.last {
                let centre = leg.legType == "RF" ? leg.arcCentre
                                                 : NavDatabase.resolve(leg.recommendedNavaid, near: c)
                if let centre { track += arcInterior(from, c, centre) }
            }
            track.append(c)
            extent.append(c)
            guard !leg.fix.isEmpty, !CIFP.isRunwayPseudoFix(leg.fix) else { continue }
            fixes.append(Fix(ident: leg.fix, coord: c, role: leg.role, constraint: leg.constraint))
        }
        if track.count >= 2 { primitives.append(.track(track)) }
        primitives += fixes.map { .fix($0) }
        if let r = runwayThresholds {
            primitives.append(.runway(from: r.from, to: r.to, designator: r.designator))
            extent.append(r.from); extent.append(r.to)
        }
        assert(primitives.count <= 1024, "VectorProcedureChart: primitive cap")
        return VectorProcedureChart(airport: airport, procedureName: procedureName, kind: kind,
                                    primitives: primitives, extent: extent)
    }

    /// What an unplaceable leg says. The ARINC path terminator IS the instruction, so it is stated
    /// rather than hidden — "climb on heading 040 to 2000 ft" is the procedure, and a chart that
    /// silently omitted it would show a gap the pilot has to fill from the plate.
    static func unplacedText(_ leg: CIFPLeg) -> String {
        let alt = SmartRouteLabel.altText(leg.constraint).map { " to \($0)" } ?? ""
        let crs = leg.course.map { String(format: "%03.0f°", $0) }
        switch leg.legType {
        case "CA", "VA": return "climb on \(crs ?? "course")\(alt)"
        case "FA":       return "from the fix on \(crs ?? "course")\(alt)"
        case "CI", "VI": return "\(crs ?? "course") to intercept"
        case "CD", "VD": return "\(crs ?? "course") to a DME distance"
        case "CR", "VR": return "\(crs ?? "course") to a radial"
        case "VM", "FM": return "\(crs ?? "course") for vectors"
        case "PI":       return "procedure turn"
        default:         return leg.legType.isEmpty ? "unpublished leg" : leg.legType
        }
    }

    /// The primitives that should be drawn at `detail`. Progressive disclosure (item 6) is applied HERE
    /// rather than in the view, so what is visible at a given scale is a testable property of the model.
    func visible(at detail: ChartDetail) -> [Primitive] {
        primitives.filter { p in
            switch p {
            case .track, .runway: return true                  // the shape is always drawn
            case .fix:            return true                  // the MARK is always drawn; its LABEL is tiered
            case .unplacedLeg:    return detail >= .idents      // an instruction is text, and text needs room
            }
        }
    }

    /// Should this fix's ident be drawn at `detail`?
    func showsIdent(_ fix: Fix, at detail: ChartDetail) -> Bool { detail >= fix.identTier }
    /// Should this fix's crossing restriction be drawn at `detail`?
    func showsRestriction(_ fix: Fix, at detail: ChartDetail) -> Bool {
        detail >= .restrictions && fix.constraint.flatMap(SmartRouteLabel.altText) != nil
    }
}
