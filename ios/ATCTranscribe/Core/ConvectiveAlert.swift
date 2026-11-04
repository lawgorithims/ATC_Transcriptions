import Foundation

/// Which product a cell came from. Four of them, because no single one answers the whole question.
///
/// The ordering of `rank` is the merge's tie-break and is a judgement about *identity*, not about data
/// quality: a cell the pilot can look up on an official bulletin and hear a controller refer to is the one
/// whose name should be on the banner, even when a radar grid measured its top more precisely. The merge
/// (`ConvectiveCellMerge`) keeps the highest-ranked cell's identity and takes the best available number
/// for every field from whichever source has it.
enum ConvectiveSource: String, Sendable, Equatable, Codable, CaseIterable {
    /// Convective SIGMET (AWC). Areas of thunderstorms, lines, or any single severe cell.
    case sigmet
    /// Center Weather Advisory (AWC). Issued by a CWSU for conditions BELOW SIGMET criteria.
    case cwa
    /// NWS Severe Thunderstorm Warning. Per-cell polygons, but no tops.
    case warning
    /// Derived here from MRMS echo tops. The only source that finds a cell nobody has reported.
    case radar

    var rank: Int {
        switch self {
        case .sigmet:  return 3
        case .cwa:     return 2
        case .warning: return 1
        case .radar:   return 0
        }
    }

    /// What the banner's source line says this is reading.
    var shortName: String {
        switch self {
        case .sigmet:  return "Convective SIGMET"
        case .cwa:     return "Center Weather Advisory"
        case .warning: return "NWS warning"
        case .radar:   return "radar echo tops"
        }
    }
}

/// A convective hazard area, normalised from whatever product supplied it, carrying the three things an
/// avoidance decision actually needs: where it is, **how high it goes**, and **where it is going**.
///
/// The precipitation radar the map draws (`RainViewerService`) can supply none of the last two. It is a
/// flat mosaic of surface reflectivity: no tops, no bases, no motion vector, and no way to derive a cell's
/// altitude from a PNG tile. So the alert is driven by products that state all three — the AWC bulletins
/// in `ConvectiveSigmetService`, and **measured** echo tops in `MRMSEchoTopService`, which closes the
/// gap the bulletins leave (an isolated non-severe cell carries no SIGMET). RainViewer remains what it is
/// good at: the picture.
struct ConvectiveCell: Identifiable, Equatable, Sendable {
    let id: String                  // stable across refreshes ("WST-1C") so an alert doesn't re-announce
    let label: String               // what the pilot reads ("Convective SIGMET 1C")
    var polygon: [Coord]            // the hazard boundary, in order; not required to be closed
    var topsFtMSL: Double?          // nil = the product did not state tops
    var baseFtMSL: Double?          // nil = surface
    let observedAt: Date            // when this was ISSUED — what data age is measured from
    var validUntil: Date
    var severity: Int?              // product-specific; higher is worse. Advisory only.

    /// ⚠️ THE DIRECTION THE CELL IS COMING **FROM**, DEGREES TRUE — NOT WHERE IT IS HEADED.
    ///
    /// This is the one field in the whole feature that can inverted-sign the alert into uselessness, so it
    /// is named for what it is rather than the tempting `motionDirDeg`. Aviation states storm motion the
    /// way it states wind: "MOV FROM 21045KT" means moving *from* 210° at 45 kt — travelling *toward* 030°.
    /// The AWC JSON copies that convention verbatim into `movementDir`, which was checked rather than
    /// assumed: across every active Convective SIGMET in the live feed, `movementDir` equalled the `MOV
    /// FROM ddd` in the bulletin's own text, 5 of 5.
    ///
    /// Use `movingTowardDeg` to advance a cell. Advancing along this field instead would march every storm
    /// backwards — a line approaching from the southwest would be modelled as receding to the southwest,
    /// so the alert would fire for the aircraft safely behind it and stay silent for the one flying in.
    var movingFromDeg: Double?
    var motionKt: Double?

    // ⚠️ Most fields above are `var` so that ONE caller can fill them: `ConvectiveCellMerge`, which
    // combines two descriptions of the same storm by taking the best available number for each field.
    // `id`, `label` and `observedAt` stay `let` — those three ARE the cell's identity, and `observedAt`
    // in particular is what `dismissKey` and the motion-vector ageing are built on, so a merge that
    // moved it would silently un-dismiss a bulletin and re-date its motion vector.

    /// The compass direction the cell is travelling toward, which is what advances its polygon.
    var movingTowardDeg: Double? {
        guard let from = movingFromDeg else { return nil }
        let toward = (from + 180).truncatingRemainder(dividingBy: 360)
        return toward < 0 ? toward + 360 : toward
    }

    /// True once the bulletin's validity has passed. The hazard does NOT expire with it — see
    /// `ConvectiveAlert.expiredGraceMinutes`.
    func isExpired(at now: Date) -> Bool { now > validUntil }

    /// Which product produced this cell. Defaulted so every existing construction site means what it
    /// said before the radar source existed.
    var source: ConvectiveSource = .sigmet

    /// Replaces the issue-time half of `dismissKey`, for a source whose cells have no issue time worth
    /// keying on. nil = key on the issue time, which is what every bulletin wants.
    ///
    /// ⚠️ THIS EXISTS BECAUSE A RADAR CELL IS RE-OBSERVED EVERY TWO MINUTES. `observedAt` is the frame
    /// time, so the default key changes on every refresh and a dismissal would survive about as long as
    /// it took the next frame to land — the X would look broken. Radar cells therefore key on their
    /// position-derived id alone, and a cell that drifts into the next id bucket announces itself again.
    /// That re-announcement is deliberate: it is still a thunderstorm, and it is still ahead.
    var dismissOverride: String? = nil

    /// The key a dismiss list must use.
    ///
    /// ⚠️ IT INCLUDES THE ISSUE TIME, AND THAT IS NOT BELT-AND-BRACES. Convective SIGMET series numbers
    /// recycle every hour: the one numbered 1C at noon is a different storm from the one numbered 1C at
    /// one o'clock. Keyed on `id` alone, a pilot tapping away today's 1C would silently mute every future
    /// 1C for the rest of the session — a safety alert switched off for the flight by one dismissal of
    /// something unrelated.
    var dismissKey: String { dismissOverride ?? "\(id)@\(Int(observedAt.timeIntervalSince1970))" }

    /// The mean of the polygon's vertices — the matching and dedupe anchor.
    ///
    /// Vertex mean rather than area centroid on purpose: it is defined for a 2-point line (which a
    /// "LINE TS" SIGMET actually is, and which has no area), it cannot be dragged off the shape by a
    /// degenerate ring, and both users of it only need a stable, cheap reference point.
    var centroid: Coord {
        assert(!polygon.isEmpty, "a cell always carries at least two vertices")
        guard !polygon.isEmpty else { return Coord(lat: 0, lon: 0) }
        var lat = 0.0, lon = 0.0
        let n = min(polygon.count, ConvectiveAlert.maxVertices)
        for i in 0..<n { lat += polygon[i].lat; lon += polygon[i].lon }
        return Coord(lat: lat / Double(n), lon: lon / Double(n))
    }
}

/// The ownship state the alert projects forward. Every field is optional because every one of them can be
/// absent in the cockpit, and the alert has to behave sensibly rather than crash or go quiet when it is.
struct ConvectiveOwnship: Equatable, Sendable {
    let position: Coord
    let altitudeFtMSL: Double?
    let trackDeg: Double?
    let groundSpeedKt: Double?
}

/// Where the aircraft sits relative to a cell's vertical extent.
///
/// Only one of these is safe, and it is deliberately the narrow case: everything else alerts. Convection
/// is hazardous below its base (microburst, hail falling out of the overhang) as well as inside it, so
/// "underneath" is not a let-off, and an unstated top is not evidence of a low one.
enum VerticalRelation: Equatable, Sendable {
    case inside(topsFtMSL: Double)          // between base and tops
    case nearTops(marginFt: Double)         // above the tops, but by less than the clearance rule wants
    case clearAbove(marginFt: Double)       // ≥ clearance above the tops — the ONLY non-threatening case
    case belowBase(marginFt: Double)        // under the cell
    case topsUnknown                        // product stated no tops → treated as relevant
    case altitudeUnknown                    // no GPS altitude → treated as relevant

    var isThreatening: Bool {
        if case .clearAbove = self { return false }
        return true
    }
}

/// One cell the aircraft is about to hit, or pass too near.
///
/// ⚠️ BOTH TIMES ARE KEPT, AND THAT IS THE POINT. The first version recorded whichever encounter came
/// first and stopped looking, which always meant the 20 NM crossing — it necessarily precedes entering the
/// cell — so a track aimed straight through a line of storms reported "within 20 NM in 5 min" and never
/// mentioned that it went inside at 8. The near-miss number buried the one that required a turn.
struct ConvectiveThreat: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case penetration        // the projected track enters the cell
        case proximity          // it stays out, but comes inside the avoidance radius
    }
    let cell: ConvectiveCell
    /// First moment the projected track is inside the avoidance radius. 0 = already is.
    let minutesToBreach: Double
    /// First moment the projected track is inside the cell itself; nil if it never gets there.
    let minutesToPenetration: Double?
    /// Closest the projected track comes to the cell boundary over the whole look-ahead, NM. 0 inside.
    let closestApproachNm: Double
    /// How old the bulletin is, minutes — the number that decides how much to trust all of the above.
    let dataAgeMin: Double
    /// How far the cell may have drifted from where this projection puts it, NM.
    let driftUncertaintyNm: Double
    let vertical: VerticalRelation
    /// The bulletin's validity has passed and this is being carried on the grace window.
    let isExpired: Bool

    /// Penetration whenever the track gets inside at any point in the window, however late — that is the
    /// fact that decides whether this needs a turn.
    var kind: Kind { minutesToPenetration == nil ? .proximity : .penetration }
    /// The number the headline leads with: when the reported kind of encounter begins.
    var minutesAway: Double { minutesToPenetration ?? minutesToBreach }

    var id: String { cell.id }
}

/// The storm-avoidance alert: pure geometry over a cell list and an ownship state, with no network, no
/// actor and no clock of its own, so every branch below is unit-testable at a chosen instant.
///
/// # What it answers
///
/// Two questions, in the pilot's terms: *am I going to fly into that*, and *am I going to pass closer to
/// it than I should*. Both are asked of the aircraft's **projected track**, not its present position, and
/// of the **cell's projected position**, not where the bulletin found it — a 45 kt line and a 250 kt
/// aeroplane close on each other at nearly 300 kt, so a check that holds either one still is not a check.
///
/// # Thresholds, and where they come from
///
/// The 20 NM comes from AIM 7-1-28, which is explicit: avoid by at least 20 miles any thunderstorm
/// identified as severe or giving an intense radar echo. It is not a round number someone liked.
///
/// The 5,000 ft overflight clearance is the FLOOR of the same guidance, not the whole of it — the full
/// rule is 1,000 ft of clearance for every 10 kt of wind speed at the cloud top, minimum 5,000 ft, which
/// at a realistic 50 kt over the top asks for 5,000 ft and at 90 kt asks for 9,000. This alert applies the
/// floor, because the wind AT THE TOP is not in the product it reads. `WindAloftService` already samples
/// winds aloft and could supply it; wiring that in is a real improvement and is deliberately not pretended
/// at here. A pilot skimming 5,000 ft over a tall cell in a strong flow is still being under-warned.
enum ConvectiveAlert {

    // MARK: Tunables (every one of them named, so no loop below has a magic bound — rule 2)

    /// AIM 7-1-28's avoidance distance.
    static let avoidNm = 20.0
    /// AIM 7-1-28's MINIMUM overflight clearance. See the type comment: the full rule needs wind at tops.
    static let overflightClearanceFt = 5_000.0
    /// How far ahead to project. Twenty minutes is about as far as a convective extrapolation means
    /// anything — cells grow, decay and split, and a 45 kt vector run out an hour is fiction.
    static let lookAheadMin = 20.0
    /// Projection granularity. 30 s at 250 kt is ~2 NM of travel, fine against a 20 NM radius.
    static let stepSeconds = 30.0
    /// Below this there is no meaningful track to project, so only the aircraft's present position is
    /// tested. Taxiing and holding both land here, and a parked aeroplane should not be told it is about
    /// to penetrate anything.
    static let minGroundSpeedKt = 30.0
    /// A cell's position is extrapolated from a vector measured some minutes ago, and the extrapolation is
    /// run some minutes forward; neither is exact, and cells deform as well as translate. The avoidance
    /// radius is widened by this fraction of the TOTAL drift (elapsed + projected) so a stale bulletin
    /// alerts earlier rather than later. A quarter of the drift is the judgement here: for a 45 kt cell on
    /// a 20-minute-old bulletin checked 10 minutes ahead it adds ~5.6 NM, which moves a 20 NM call out to
    /// about 26 NM. It is a buffer, not a forecast of error.
    static let driftErrorFraction = 0.25
    /// The same allowance for a cell whose motion was DERIVED rather than stated.
    ///
    /// ⚠️ IT IS LARGER BECAUSE THE DERIVATION HAS A MEASURED BIAS, NOT TO BE CAUTIOUS IN GENERAL.
    /// `RadarCellFinder.fieldMotion` recovers direction to about 13° but reads speed 20–25% LOW, every
    /// time, for a structural reason set out where it is measured. Low is the dangerous direction: it
    /// puts the projected cell short of where it will actually be. At 40 kt over a 20-minute look-ahead
    /// a 25% speed deficit is ~4 NM of position error, and 0.25 of the total drift only covers about
    /// 2.9 NM of it — so the fraction is raised until it does. This is the apology for a known bias,
    /// not a forecast of error, and it is deliberately NOT a 1.25× fudge applied to the speed itself:
    /// the published vector stays the one that was measured.
    static let radarDriftErrorFraction = 0.40
    /// What to add when the product states no motion at all. Such a cell cannot be advanced, so it is
    /// treated as stationary — which can be badly wrong — and this is the apology for that: roughly what
    /// an ordinary 25 kt cell covers in 25 minutes.
    static let unknownMotionUncertaintyNm = 10.0
    /// ⚠️ THE BULLETIN EXPIRES. THE THUNDERSTORM DOES NOT.
    ///
    /// Convective SIGMETs are valid two hours and reissued hourly, so there is a seam at every expiry
    /// where the new one has not arrived and the old one has lapsed. Dropping a cell the instant its
    /// validity passes puts a silent hole in the alert at exactly the moment the weather is unchanged, so
    /// an expired cell keeps alerting for this long, flagged, and the UI says it is expired.
    static let expiredGraceMinutes = 15.0

    // MARK: Static caps (rule 2 — every loop below is bounded by one of these)

    static let maxCells = 64
    static let maxVertices = 64
    /// 0…20 min inclusive at 30 s.
    static let maxProjectionSteps = 41
    /// Banner cap, worst first.
    static let maxThreats = 4

    // MARK: Vertical

    /// Where the aircraft sits relative to the cell's vertical extent.
    ///
    /// Fails toward alerting in every uncertain case: no altitude, no stated tops, or anywhere inside the
    /// column all alert. Only a clean `overflightClearanceFt` above a KNOWN top is let through.
    static func verticalRelation(cell: ConvectiveCell, altitudeFtMSL: Double?) -> VerticalRelation {
        assert(cell.topsFtMSL == nil || cell.topsFtMSL!.isFinite, "tops finite when present")
        assert(altitudeFtMSL == nil || altitudeFtMSL!.isFinite, "altitude finite when present")
        guard let alt = altitudeFtMSL else { return .altitudeUnknown }
        guard let tops = cell.topsFtMSL else { return .topsUnknown }
        if let base = cell.baseFtMSL, alt < base {
            return .belowBase(marginFt: base - alt)
        }
        let margin = alt - tops
        if margin <= 0 { return .inside(topsFtMSL: tops) }
        return margin >= overflightClearanceFt ? .clearAbove(marginFt: margin)
                                               : .nearTops(marginFt: margin)
    }

    // MARK: Geometry

    /// Distance from a point to a polygon in NM, 0 inside it. Reuses `HazardCorridor`'s segment math, so
    /// the projection and its <1% error characteristic are the ones already tested there.
    static func distanceNm(from p: Coord, toPolygon ring: [Coord]) -> Double {
        assert(ring.count <= maxVertices, "polygon clamped upstream")
        assert((-90...90).contains(p.lat), "latitude in range")
        guard ring.count >= 3 else {
            // A two-point "LINE TS" area has no interior to enter, so it is measured as a segment.
            // Falling back to the first vertex would under-report by up to the line's whole length —
            // an aircraft abeam the middle of a 200 NM squall line would be told it was 100 NM clear.
            if ring.count == 2 { return HazardCorridor.distanceNm(from: p, toSegment: ring[0], ring[1]) }
            return ring.first.map { Geo.nmBetween(p, $0) } ?? .greatestFiniteMagnitude
        }
        if Geo.pointInRing(p, ring) { return 0 }
        var best = Double.greatestFiniteMagnitude
        let n = min(ring.count, maxVertices)
        for i in 0..<n {
            best = min(best, HazardCorridor.distanceNm(from: p, toSegment: ring[i], ring[(i + 1) % n]))
        }
        return best
    }

    /// The cell's polygon as it will stand `minutes` from the bulletin's own observation, translated along
    /// `movingTowardDeg` — see the warning on `ConvectiveCell.movingFromDeg` for why that is not
    /// `movingFromDeg`. A cell with no motion vector is returned unmoved.
    static func advance(_ ring: [Coord], of cell: ConvectiveCell, byMinutes minutes: Double) -> [Coord] {
        assert(minutes >= 0, "time runs forward")
        assert(ring.count <= maxVertices, "polygon clamped upstream")
        guard let toward = cell.movingTowardDeg, let kt = cell.motionKt,
              kt > 0, minutes > 0, !ring.isEmpty else { return ring }
        let nm = kt * (minutes / 60)
        var out: [Coord] = []
        out.reserveCapacity(ring.count)
        for i in 0..<min(ring.count, maxVertices) {
            out.append(Geo.point(from: ring[i], bearingDeg: toward, distanceNm: nm))
        }
        return out
    }

    /// How far the cell may be from where this projection puts it, NM — the recency term.
    ///
    /// Both halves matter and they add: the bulletin was already `ageMinutes` old when read, and the check
    /// runs `projectedMinutes` further on. A perfectly fresh bulletin checked far ahead is as uncertain as
    /// a stale one checked now.
    static func driftUncertaintyNm(_ cell: ConvectiveCell,
                                   ageMinutes: Double,
                                   projectedMinutes: Double) -> Double {
        assert(ageMinutes >= 0, "age runs forward")
        assert(projectedMinutes >= 0, "projection runs forward")
        guard let kt = cell.motionKt, kt > 0 else { return unknownMotionUncertaintyNm }
        let driftNm = kt * ((ageMinutes + projectedMinutes) / 60)
        let fraction = cell.source == .radar ? radarDriftErrorFraction : driftErrorFraction
        return driftNm * fraction
    }

    // MARK: The alert

    /// Every cell the projected track penetrates or passes too near, worst first.
    ///
    /// Ordering is penetration before proximity, then soonest, then nearest — a cell the aircraft will
    /// enter in 12 minutes outranks one it will pass 19 NM from in 3, because the first one has to be
    /// turned away from and the second one may not.
    static func threats(cells: [ConvectiveCell],
                        ownship: ConvectiveOwnship,
                        now: Date) -> [ConvectiveThreat] {
        assert(cells.count <= maxCells, "cell snapshot bounded by the service")
        assert((-90...90).contains(ownship.position.lat), "ownship latitude in range")
        var out: [ConvectiveThreat] = []
        for cell in cells.prefix(maxCells) {
            if let t = threat(cell: cell, ownship: ownship, now: now) { out.append(t) }
        }
        out.sort { a, b in
            if (a.kind == .penetration) != (b.kind == .penetration) { return a.kind == .penetration }
            if a.minutesAway != b.minutesAway { return a.minutesAway < b.minutesAway }
            return a.closestApproachNm < b.closestApproachNm
        }
        return Array(out.prefix(maxThreats))
    }

    /// Whether anything in this snapshot warrants the banner at all.
    static func hasThreat(cells: [ConvectiveCell], ownship: ConvectiveOwnship, now: Date) -> Bool {
        assert(cells.count <= maxCells, "cell snapshot bounded by the service")
        assert(now.timeIntervalSince1970 > 0, "a real instant")
        return !threats(cells: cells, ownship: ownship, now: now).isEmpty
    }

    /// The single-cell test. nil when the cell is irrelevant: safely overflown, long expired, or simply
    /// never came within the avoidance radius over the look-ahead.
    static func threat(cell: ConvectiveCell,
                       ownship: ConvectiveOwnship,
                       now: Date) -> ConvectiveThreat? {
        assert(cell.polygon.count <= maxVertices, "polygon clamped upstream")
        assert(stepSeconds > 0, "a non-positive step would not terminate")

        // Expired past the grace window — the weather outlives the bulletin, but not indefinitely.
        let expiredByMin = now.timeIntervalSince(cell.validUntil) / 60
        guard expiredByMin <= expiredGraceMinutes else { return nil }

        let vertical = verticalRelation(cell: cell, altitudeFtMSL: ownship.altitudeFtMSL)
        guard vertical.isThreatening else { return nil }

        let ageMin = max(0, now.timeIntervalSince(cell.observedAt) / 60)
        let ring = Array(cell.polygon.prefix(maxVertices))

        // No usable track: test where the aircraft is, now, and nothing more. Still worth doing — a
        // parked aeroplane under a cell should say so, it just must not claim an encounter time.
        let gs = ownship.groundSpeedKt ?? 0
        guard let track = ownship.trackDeg, gs >= minGroundSpeedKt else {
            let advanced = advance(ring, of: cell, byMinutes: ageMin)
            let d = distanceNm(from: ownship.position, toPolygon: advanced)
            let slack = driftUncertaintyNm(cell, ageMinutes: ageMin, projectedMinutes: 0)
            guard d <= avoidNm + slack else { return nil }
            return ConvectiveThreat(cell: cell, minutesToBreach: 0,
                                    minutesToPenetration: d == 0 ? 0 : nil,
                                    closestApproachNm: d, dataAgeMin: ageMin,
                                    driftUncertaintyNm: slack, vertical: vertical,
                                    isExpired: expiredByMin > 0)
        }

        // Both move, so the whole window is walked: the breach and the penetration are recorded
        // separately and the loop does NOT stop at the first of them. Closing speed here is the sum of
        // two vectors — a 250 kt aeroplane and a 45 kt line can be closing at nearly 300 kt — which is
        // why neither one may be held still.
        var breachMin: Double?
        var penetrationMin: Double?
        var slackAtBreach = 0.0
        var closest = Double.greatestFiniteMagnitude
        let steps = min(Int((lookAheadMin * 60 / stepSeconds).rounded()) + 1, maxProjectionSteps)
        for step in 0..<steps {
            let minutes = Double(step) * stepSeconds / 60
            let own = minutes > 0
                ? Geo.point(from: ownship.position, bearingDeg: track, distanceNm: gs * (minutes / 60))
                : ownship.position
            // The cell is advanced from when it was OBSERVED, not from now, so the bulletin's age is
            // carried in the geometry instead of only in the caveat text.
            let advanced = advance(ring, of: cell, byMinutes: ageMin + minutes)
            let d = distanceNm(from: own, toPolygon: advanced)
            closest = min(closest, d)
            if d == 0, penetrationMin == nil { penetrationMin = minutes }
            if breachMin == nil {
                let slack = driftUncertaintyNm(cell, ageMinutes: ageMin, projectedMinutes: minutes)
                if d <= avoidNm + slack { breachMin = minutes; slackAtBreach = slack }
            }
        }
        // A penetration always breaches first, but clamp rather than assume: a polygon whose edge math
        // and containment test disagree at the boundary must not publish a nil breach time.
        guard let breach = breachMin ?? penetrationMin else { return nil }
        return ConvectiveThreat(cell: cell, minutesToBreach: breach,
                                minutesToPenetration: penetrationMin,
                                closestApproachNm: closest == .greatestFiniteMagnitude ? 0 : closest,
                                dataAgeMin: ageMin, driftUncertaintyNm: slackAtBreach,
                                vertical: vertical, isExpired: expiredByMin > 0)
    }
}

/// The pilot-facing sentences, pure and separate from the geometry so the wording can be tested without
/// constructing a flight.
///
/// The tone rule here is the same one the rest of the app follows: say the thing, say how much to trust
/// it, and never imply precision the data does not have. "In 12 min" from a 20-minute-old bulletin is a
/// statement about a projection, so the age travels with it rather than being buried in a settings screen.
enum ConvectiveAlertText {

    /// Altitudes the way a pilot says them: flight levels above 18,000 ft, feet below.
    static func altitudeText(_ ftMSL: Double) -> String {
        assert(ftMSL.isFinite, "altitude finite")
        assert(ftMSL > -2_000, "altitude above the Dead Sea")
        if ftMSL >= 18_000 { return String(format: "FL%03.0f", (ftMSL / 100).rounded()) }
        let thousands = (ftMSL / 100).rounded() * 100
        return "\(Int(thousands).formatted(.number.grouping(.automatic))) ft"
    }

    /// "now", "1 min", "12 min" — never "0 min", which reads as a rounding artefact rather than a warning.
    static func minutesText(_ minutes: Double) -> String {
        assert(minutes.isFinite, "minutes finite")
        assert(minutes >= 0, "minutes non-negative")
        if minutes < 0.5 { return "now" }
        return "\(Int(minutes.rounded())) min"
    }

    /// The one line that has to carry the whole warning if the pilot reads nothing else.
    static func headline(_ t: ConvectiveThreat) -> String {
        assert(!t.cell.label.isEmpty, "a cell the pilot can name")
        assert(t.minutesAway >= 0, "encounter in the future")
        let when = minutesText(t.minutesAway)
        switch t.kind {
        case .penetration:
            return when == "now"
                ? "In \(t.cell.label)"
                : "Entering \(t.cell.label) in \(when)"
        case .proximity:
            let nm = Int(t.closestApproachNm.rounded())
            return when == "now"
                ? "\(nm) NM from \(t.cell.label)"
                : "Within \(nm) NM of \(t.cell.label) in \(when)"
        }
    }

    /// Tops, motion and age — the three things that decide whether the headline deserves a turn.
    static func detail(_ t: ConvectiveThreat) -> String {
        assert(t.dataAgeMin >= 0, "age non-negative")
        assert(t.driftUncertaintyNm >= 0, "uncertainty non-negative")
        var parts: [String] = []

        switch t.vertical {
        case .inside(let tops):            parts.append("tops \(altitudeText(tops))")
        case .nearTops(let margin):        parts.append("only \(Int(margin.rounded())) ft above tops")
        case .belowBase(let margin):       parts.append("base \(Int(margin.rounded())) ft above you")
        case .topsUnknown:                 parts.append("tops not reported")
        case .altitudeUnknown:             parts.append("no GPS altitude")
        case .clearAbove:                  break   // filtered out before a threat is built
        }

        if let kt = t.cell.motionKt, let from = t.cell.movingFromDeg, kt > 0 {
            // Stated the way the bulletin states it, so it can be read against the printed text without
            // the pilot having to reverse a heading in their head.
            parts.append(String(format: "moving from %03.0f° at %.0f kt", from, kt))
        } else {
            // A bulletin that did not state a vector and a measurement that could not recover one are
            // different facts, and the pilot can act on the difference: the first may be in the
            // bulletin text, the second will not be anywhere.
            parts.append(t.cell.source == .radar ? "movement not measurable" : "motion not reported")
        }

        // For a penetration the headline gives the moment of entry; this is the moment the 20 NM is
        // broken, which is the one a turn has to beat. Omitted when they round to the same minute, and
        // when the avoidance radius is already broken (the headline covers that).
        if t.kind == .penetration, t.minutesToBreach >= 0.5,
           minutesText(t.minutesToBreach) != minutesText(t.minutesAway) {
            parts.append("inside \(Int(ConvectiveAlert.avoidNm)) NM in \(minutesText(t.minutesToBreach))")
        }

        parts.append(t.dataAgeMin < 1 ? "issued just now"
                                      : "issued \(Int(t.dataAgeMin.rounded())) min ago")
        if t.isExpired { parts.append("bulletin expired — carried forward") }
        if t.driftUncertaintyNm >= 1 {
            parts.append("±\(Int(t.driftUncertaintyNm.rounded())) NM drift")
        }
        return parts.joined(separator: " · ")
    }
}
