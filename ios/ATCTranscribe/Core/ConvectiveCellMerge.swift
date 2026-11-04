import Foundation

/// Combines the four convective sources into one list, so a single thunderstorm described by three
/// products becomes one cell carrying the best of all three rather than three banners.
///
/// # The problem this solves
///
/// On an active afternoon the same storm can appear four times: inside a Convective SIGMET area, inside
/// a CWA, inside a Severe Thunderstorm Warning, and as an MRMS echo-top component. Published as-is the
/// pilot gets a banner reading "Entering Convective SIGMET 7C in 8 min (+3 more)" where all four are the
/// same weather — which is both noise and, worse, hides a genuinely separate second storm behind the
/// "+3 more".
///
/// And the four do not merely duplicate each other; each is missing something the others have:
///
/// | source  | polygon            | tops            | motion           | name a pilot can look up |
/// |---------|--------------------|-----------------|------------------|--------------------------|
/// | SIGMET  | area               | stated          | stated           | yes                      |
/// | CWA     | area, smaller      | stated in text  | stated in text   | yes                      |
/// | warning | **one storm**      | **none**        | stated, recent   | yes                      |
/// | radar   | one storm, measured| **measured**    | derived, biased  | no                       |
///
/// So the merge is not a deduplication that discards — it is a union that keeps the best field from
/// whichever source has it.
///
/// # The two rules
///
/// **Identity goes to the highest-ranked source** (`ConvectiveSource.rank`: SIGMET > CWA > warning >
/// radar). That is a judgement about what belongs on the banner, not about data quality: the name the
/// pilot can cross-check against an official product, and hear a controller offering a deviation around,
/// is worth more on one line of text than a slightly better-measured outline. A radar cell's own id is
/// position-derived and means nothing to anybody.
///
/// **Every number fails toward warning.** Tops take the HIGHER of the two, bases the LOWER, severity the
/// greater, validity the LATER, and the polygon the one with the LARGER area. The last of those is the
/// one worth being explicit about: keeping the bigger outline can only widen the alert, never narrow it,
/// so merging a 400 NM² radar cell into a 20,000 NM² SIGMET area cannot lose coverage the radar had.
///
/// ⚠️ `observedAt` IS NEVER MERGED. It is the winner's, always. Two things are built on it — the
/// dismiss key, and how far the motion vector is extrapolated — so moving it forward to the fresher
/// source's time would silently un-dismiss a bulletin the pilot had cleared, and would re-date a
/// 40-minute-old SIGMET motion vector as though it had just been measured.
///
/// Pure: no clock of its own beyond what it is handed, no network, no actor.
enum ConvectiveCellMerge {

    /// How near two cells' reference points must be before the overlap test is even worth running.
    /// A coarse pre-reject so the pairwise scan stays cheap; the real test is `describeSameStorm`.
    static let screenNm = 250.0

    /// Two cells closer than this are treated as the same storm even if their outlines do not overlap.
    /// A warning polygon and a radar component for one cell are drawn by different methods minutes
    /// apart, so they can miss each other by a few miles while plainly being one thunderstorm.
    static let sameStormNm = 12.0

    /// Fold the sources into one list, worst-topped first. Bounded by `ConvectiveAlert.maxCells`.
    static func merge(_ cells: [ConvectiveCell]) -> [ConvectiveCell] {
        assert(ConvectiveAlert.maxCells > 0, "ConvectiveCellMerge: cell cap must be positive")
        guard cells.count > 1 else { return cells }
        // Highest-ranked source first, and within a source the better-informed cell first, so the
        // identity a group keeps is deterministic rather than feed-order dependent.
        let ordered = cells.sorted { a, b in
            if a.source.rank != b.source.rank { return a.source.rank > b.source.rank }
            if informationScore(a) != informationScore(b) {
                return informationScore(a) > informationScore(b)
            }
            return a.id < b.id
        }
        var kept: [ConvectiveCell] = []
        kept.reserveCapacity(min(ordered.count, ConvectiveAlert.maxCells))
        for candidate in ordered.prefix(ConvectiveAlert.maxCells * 2) {  // bounded (rule 2)
            var absorbed = false
            for i in kept.indices {                                      // bounded by the cap (rule 2)
                guard describeSameStorm(kept[i], candidate) else { continue }
                kept[i] = enrich(kept[i], with: candidate)
                absorbed = true
                break
            }
            if !absorbed, kept.count < ConvectiveAlert.maxCells { kept.append(candidate) }
        }
        // Tallest first, unknown tops ahead of known ones: a cell whose top nobody measured is the one
        // the pilot can least afford to have pushed off the end of the banner.
        kept.sort { a, b in
            let ta = a.topsFtMSL, tb = b.topsFtMSL
            if (ta == nil) != (tb == nil) { return ta == nil }
            return (ta ?? 0) > (tb ?? 0)
        }
        return kept
    }

    /// How much an alert can learn from this cell. Only used to order cells WITHIN one source.
    static func informationScore(_ c: ConvectiveCell) -> Int {
        var score = 0
        if c.topsFtMSL != nil { score += 2 }
        if c.motionKt != nil && c.movingFromDeg != nil { score += 1 }
        if c.severity != nil { score += 1 }
        return score
    }

    /// Are these two descriptions of one storm?
    ///
    /// Either outline contains the other's reference point, or the outlines come within
    /// `sameStormNm` of each other. Asymmetric containment is checked both ways on purpose: a small
    /// radar cell inside a big SIGMET area satisfies one direction and not the other.
    static func describeSameStorm(_ a: ConvectiveCell, _ b: ConvectiveCell) -> Bool {
        assert(!a.polygon.isEmpty && !b.polygon.isEmpty, "ConvectiveCellMerge: a cell with no outline")
        let ca = a.centroid, cb = b.centroid
        // Cheap pre-reject so the segment math is not run across the continent.
        guard Geo.nmBetween(ca, cb) <= screenNm else { return false }
        if ConvectiveAlert.distanceNm(from: cb, toPolygon: a.polygon) == 0 { return true }
        if ConvectiveAlert.distanceNm(from: ca, toPolygon: b.polygon) == 0 { return true }
        // Nearest approach between the outlines, measured from each one's vertices to the other.
        var best = Double.greatestFiniteMagnitude
        for v in a.polygon.prefix(ConvectiveAlert.maxVertices) {         // bounded (rule 2)
            best = min(best, ConvectiveAlert.distanceNm(from: v, toPolygon: b.polygon))
            if best <= sameStormNm { return true }
        }
        for v in b.polygon.prefix(ConvectiveAlert.maxVertices) {         // bounded (rule 2)
            best = min(best, ConvectiveAlert.distanceNm(from: v, toPolygon: a.polygon))
            if best <= sameStormNm { return true }
        }
        return false
    }

    /// Take the conservative value of every field from `other`, keeping `winner`'s identity.
    static func enrich(_ winner: ConvectiveCell, with other: ConvectiveCell) -> ConvectiveCell {
        assert(winner.source.rank >= other.source.rank, "ConvectiveCellMerge: identity must win on rank")
        assert(!winner.polygon.isEmpty, "ConvectiveCellMerge: a winner with no outline")
        var out = winner

        // Tops: the higher. A SIGMET stating FL380 for a whole area and a radar measuring 52,000 ft over
        // the strongest pixel of it do not contradict each other — the area statement is a
        // generalisation. Taking the max is both the more accurate number and the safe direction, and it
        // is the same rule the SIGMET parser already applies to `altitudeHi1`/`Hi2`.
        switch (out.topsFtMSL, other.topsFtMSL) {
        case (nil, let t?):             out.topsFtMSL = t
        case (let a?, let b?):          out.topsFtMSL = max(a, b)
        default:                        break
        }
        // Bases: the lower, so the hazardous column is taken at its largest. nil means surface, which is
        // already the lowest possible, so a nil on either side wins.
        if out.baseFtMSL != nil {
            out.baseFtMSL = other.baseFtMSL == nil ? nil : min(out.baseFtMSL!, other.baseFtMSL!)
        }
        // Motion: only fill a gap. The winner is the higher-ranked source, and a stated vector from a
        // forecaster watching the storm beats a derived one with a known speed bias — so this never
        // overwrites, it only supplies what was missing.
        if out.motionKt == nil || out.movingFromDeg == nil {
            if let kt = other.motionKt, let from = other.movingFromDeg {
                out.motionKt = kt
                out.movingFromDeg = from
            }
        }
        switch (out.severity, other.severity) {
        case (nil, let s?):             out.severity = s
        case (let a?, let b?):          out.severity = max(a, b)
        default:                        break
        }
        // Validity: the later, so a storm covered by a lapsing SIGMET and a fresh warning is carried by
        // the fresh one instead of falling into the expiry seam.
        out.validUntil = max(out.validUntil, other.validUntil)
        // Outline: the larger. A superset can only widen the alert.
        let mine = RadarCellFinder.areaNm2(out.polygon)
        let theirs = RadarCellFinder.areaNm2(other.polygon)
        if theirs > mine, other.polygon.count >= 3 {
            out.polygon = Array(other.polygon.prefix(ConvectiveAlert.maxVertices))
        }
        return out
    }
}
