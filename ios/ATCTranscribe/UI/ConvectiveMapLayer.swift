import MapKit

/// The storm-cell map layer: the engine-independent geometry, then the classic engine's reconcile.
///
/// # Why this exists
///
/// `ConvectiveAlert` has been able to say *you will be inside Convective SIGMET 7C in six minutes* for
/// several versions, and the map drew nothing. That was tolerable only while every cell came from a
/// bulletin with a series number a pilot could look up or hear a controller say. It stopped being
/// tolerable when `MRMSEchoTopService` started finding cells **nobody has reported**: a radar-derived
/// cell has no name, no bulletin and no entry on any briefing, so an outline on the map is the only way
/// to see what the banner is talking about.
///
/// # What is drawn, and at which instant
///
/// ⚠️ THE RING IS ADVANCED TO THE INSTANT THE ALERT LAST REASONED, NOT TO THE BULLETIN'S OBSERVATION.
/// A Convective SIGMET is read when it is read: twenty minutes old at 45 kt is fifteen miles of storm
/// travel, so drawing the polygon exactly as issued would put the outline visibly *behind* a banner
/// warning about a penetration ahead — the map and the banner contradicting each other at the one
/// moment the pilot is deciding whether to turn. So the ring is translated by the cell's own age with
/// `ConvectiveAlert.advance`, the same function and the same vector the alert projects with.
///
/// ⚠️ AND IT IS ADVANCED TO A *FIXED* INSTANT — `AppModel.convectiveDrawAt`, the time of the last
/// recompute — never to `Date()`. Advancing to the present would make every ring a function of the
/// clock: the diff signature below would change on every pass, `updateUIView` runs on any published
/// change (traffic moves every second), and the whole layer would be torn down and rebuilt
/// continuously — a blinking storm, and sixty polygon rebuilds a second to produce it. Pinning the
/// instant also buys the property that matters more: the outline moves exactly when the alert's own
/// reasoning moves, so the two cannot drift apart.
///
/// # Colour
///
/// `MapTheme.convective`, which is teal by day and a warm salmon at night. The first version of this
/// layer reused the EONET storm violet instead, on the reasoning that this app had already decided
/// violet means storm; put on a sectional, a 50 NM cell read as a MOA. The hue had to leave the
/// airspace palette altogether rather than sit next to it, and the whole argument — including what the
/// precipitation mosaic underneath rules out — is recorded on that theme field.
enum ConvectiveCellDraw {

    // MARK: Tunables (named, so no loop below carries a magic bound — rule 2)

    /// Drawn-cell cap. Deliberately `ConvectiveAlert.maxCells` and not a number of its own: the map must
    /// not be able to show a cell the alert ignored, nor stay silent about one it warned on.
    static let maxDrawn = ConvectiveAlert.maxCells
    /// How far ahead the motion arrow reaches. The alert's own look-ahead, so the arrowhead lands where
    /// the alert stopped caring — the pilot is looking at the window the warning was computed over.
    static let arrowMinutes = ConvectiveAlert.lookAheadMin
    /// Arrowhead barb half-angle, degrees off the shaft.
    static let barbDeg = 28.0
    /// Barb length as a fraction of the shaft …
    static let barbFraction = 0.28
    /// … clamped, so a 120 kt line's arrowhead does not become a second polygon.
    static let maxBarbNm = 6.0
    /// Below this a cell is drawn with no arrow at all. A 3 kt vector over twenty minutes is one mile of
    /// shaft — an arrow too short to show a direction, which is worse than no arrow, because a stub
    /// pointing nowhere still reads as information.
    static let minArrowKt = 5.0

    // MARK: Geometry

    /// The ring to draw for `cell`, translated from where the product observed it to where it stands at
    /// `at`. Empty when there is nothing drawable.
    ///
    /// Two or more vertices come back, not three: a "LINE TS" Convective SIGMET **is** a two-point line
    /// with no area, and it describes a squall line — the single most dangerous shape in the whole feed.
    /// Dropping it for want of an interior would silently draw nothing for the cell most worth drawing,
    /// so the caller is left to render a 2-point ring as a line. See `ConvectiveCell.centroid`, which
    /// documents the same case for the same reason.
    static func ring(_ cell: ConvectiveCell, at: Date) -> [Coord] {
        assert(ConvectiveAlert.maxVertices > 0, "vertex cap must be positive")
        assert(maxDrawn > 0, "cell cap must be positive")
        let observed = Array(cell.polygon.prefix(ConvectiveAlert.maxVertices))   // bounded (rule 2)
        guard observed.count >= 2 else { return [] }
        return ConvectiveAlert.advance(observed, of: cell, byMinutes: ageMinutes(cell, at: at))
    }

    /// How far the ring is translated, in minutes — never negative.
    ///
    /// A negative age is not a hypothetical. `observedAt` is a *stated* bulletin time, the device clock
    /// can be wrong, and a GFS-style "issued at" can legitimately sit slightly ahead of now; feeding any
    /// of those to `advance` unchecked would run the storm **backwards** down its own motion vector,
    /// which is the one direction guaranteed to be wrong. Clamping at zero degrades to drawing the cell
    /// where the product put it.
    static func ageMinutes(_ cell: ConvectiveCell, at: Date) -> Double {
        let min = at.timeIntervalSince(cell.observedAt) / 60
        assert(min.isFinite || min.isNaN, "a time interval is a real number")
        guard min.isFinite, min > 0 else { return 0 }
        return min
    }

    /// The motion arrow for `cell` as one polyline — shaft, then a barb either side of the tip — or
    /// empty when the cell states no usable motion.
    ///
    /// The retraced tip (`[tail, tip, left, tip, right]`) is deliberate: it draws a shaft and a V in a
    /// single overlay, which keeps a cell to one arrow instead of three line objects and one renderer
    /// callback instead of three.
    ///
    /// ⚠️ IT POINTS ALONG `movingTowardDeg`, WHICH IS NOT `movingFromDeg`. The read warning on that
    /// field is about the alert; it applies at least as much here, because an arrow is a *claim about
    /// the future* that a pilot will fly on. Drawn from the wrong end, every storm on the map would
    /// appear to be leaving.
    static func motionArrow(_ cell: ConvectiveCell, at: Date) -> [Coord] {
        assert(barbDeg > 0 && barbDeg < 90, "a barb folds back from the tip")
        assert(barbFraction > 0, "a barb has length")
        guard let toward = cell.movingTowardDeg, let kt = cell.motionKt,
              kt >= minArrowKt, kt.isFinite else { return [] }
        let r = ring(cell, at: at)
        guard !r.isEmpty else { return [] }
        let tail = drawnCentroid(cell, at: at)
        let shaftNm = kt * (arrowMinutes / 60)
        guard shaftNm > 0 else { return [] }
        let tip = Geo.point(from: tail, bearingDeg: toward, distanceNm: shaftNm)
        let barbNm = Swift.min(shaftNm * barbFraction, maxBarbNm)
        let back = toward + 180
        let left = Geo.point(from: tip, bearingDeg: back + barbDeg, distanceNm: barbNm)
        let right = Geo.point(from: tip, bearingDeg: back - barbDeg, distanceNm: barbNm)
        return [tail, tip, left, tip, right]
    }

    /// The cell's centroid AS DRAWN: the observed centroid walked along the motion vector by the
    /// cell's own age, so it sits in the middle of the ring the pilot is looking at.
    ///
    /// Reached by advancing the OBSERVED centroid along the vector rather than by re-averaging the
    /// moved ring. Not quite the same point: `advance` walks each vertex along its own great circle,
    /// so the moved ring's vertex-mean and the moved centroid part company by about 25 ft over a 15 NM
    /// step — three orders of magnitude inside the cell either one anchors, and measured in the tests
    /// rather than assumed.
    ///
    /// Two callers, which is why it is a function: the motion arrow is rooted here, and a tapped cell
    /// reports its bearing and distance from this point. A card and an arrow that disagreed about
    /// where the middle of the storm is would be a strange thing to ship.
    static func drawnCentroid(_ cell: ConvectiveCell, at: Date) -> Coord {
        guard let toward = cell.movingTowardDeg, let kt = cell.motionKt, kt.isFinite, kt > 0 else {
            return cell.centroid                       // nothing stated → where the product put it
        }
        assert(toward.isFinite, "a reversed bearing is still a bearing")
        return Geo.point(from: cell.centroid, bearingDeg: toward,
                         distanceNm: kt * (ageMinutes(cell, at: at) / 60))
    }

    // MARK: Hit testing

    /// True when `here` falls inside the cell's outline **as drawn** at `at`.
    ///
    /// ⚠️ THE RING AS DRAWN, NOT AS ISSUED, and this is the whole reason the function exists rather
    /// than the callers reaching for `Geo.pointInRing(here, cell.polygon)`. A twenty-minute-old
    /// Convective SIGMET at 45 kt is drawn fifteen miles from where the bulletin put it; testing the
    /// issued polygon would open a card for a cell whose outline is fifteen miles away and refuse the
    /// one under the finger — a tap that misses what you touched and hits what is not there.
    ///
    /// A 2-point LINE TS returns false, and not as an oversight: a squall line has no interior to be
    /// inside of. It is reached by ON-SCREEN distance to the line instead, which is how the airway
    /// layer has always made a line feature tappable, and is the only way a finger-sized target works
    /// on a shape with no area. Each engine does that half in its own screen space.
    static func contains(_ cell: ConvectiveCell, at: Date, _ here: Coord) -> Bool {
        assert((-90...90).contains(here.lat), "a probe point on the earth")
        let r = ring(cell, at: at)
        guard r.count >= 3 else { return false }
        return Geo.pointInRing(here, r)
    }

    /// The drawn cells whose outline contains `here`, in the drawn order — `drawable` first, so a cell
    /// the map was never going to show cannot answer a tap on it.
    static func containing(_ cells: [ConvectiveCell], at: Date, _ here: Coord) -> [ConvectiveCell] {
        assert(cells.count <= 4_096, "absurd cell count — the services cap long before this")
        return drawable(cells).filter { contains($0, at: at, here) }
    }

    /// One tapped cell as a probe object, so neither engine can describe a storm differently from the
    /// other — the same reason both take their geometry from this type.
    ///
    /// `coord` is the drawn centroid, which makes the card's "from you" row a bearing and distance to
    /// the middle of the cell. Not to its nearest edge: the edge is what `ConvectiveThreat`
    /// .closestApproachNm measures over the whole look-ahead, and a second, differently-defined
    /// distance to the same storm on the same card would invite exactly the wrong comparison.
    static func object(_ cell: ConvectiveCell, at: Date) -> IdentifiedObject {
        assert(!cell.id.isEmpty, "a cell carries an identity")
        return IdentifiedObject(kind: .convective, ident: cell.id,
                                coord: drawnCentroid(cell, at: at), onRoute: false, cell: cell)
    }

    /// Where the altitude block goes: the ring's northernmost vertex, which is the convention
    /// `TFRArea.labelCoord` already set, so a cell's tops block and a TFR's limits block sit the same
    /// way round and a pilot reads one the way they read the other.
    static func labelCoord(_ ring: [Coord]) -> Coord? { ring.max(by: { $0.lat < $1.lat }) }

    /// The cell's tops in the compact chart form, for the altitude block's upper line.
    ///
    /// An unstated top reads "—", and that dash is doing real work: `VerticalRelation.topsUnknown` is a
    /// *threatening* case, because a product that did not measure a top is not evidence of a low one.
    /// Printing a confident number there, or hiding the cell for want of one, would both say the
    /// opposite of what the alert concluded.
    static func topsText(_ cell: ConvectiveCell) -> String {
        AirspaceLabelAnnotation.altText(cell.topsFtMSL.map { Int($0) })
    }

    /// The cell's base, for the block's lower line. `nil` means the hazard reaches the ground — see
    /// `ConvectiveCell.baseFtMSL` — so it prints SFC, not a dash: that is a stated fact about the cell,
    /// not a gap in the product.
    static func baseText(_ cell: ConvectiveCell) -> String {
        AirspaceLabelAnnotation.altText(cell.baseFtMSL.map { Int($0) } ?? 0)
    }

    /// Two lines, tops over base — the chart's own altitude block.
    static func altBlock(_ cell: ConvectiveCell) -> String { "\(topsText(cell))\n\(baseText(cell))" }

    /// The drawn cells, de-duplicated by id and capped, in a stable order.
    ///
    /// Sorted so that a run of this function over an unchanged list produces an unchanged sequence: the
    /// merge's output order is not guaranteed, and an unstable order would make the cap itself flicker
    /// between which 64 cells it kept.
    static func drawable(_ cells: [ConvectiveCell]) -> [ConvectiveCell] {
        assert(cells.count <= 4_096, "absurd cell count — the services cap long before this")
        var seen = Set<String>()
        var out: [ConvectiveCell] = []
        for c in cells.prefix(4_096) where c.polygon.count >= 2 {    // bounded (rule 2)
            guard !seen.contains(c.id) else { continue }
            seen.insert(c.id)
            out.append(c)
        }
        out.sort { $0.id < $1.id }
        assert(out.count <= 4_096, "drawable: dedupe cannot grow the list")
        return Array(out.prefix(maxDrawn))
    }

    /// The per-cell change digest. A cell whose digest is unchanged is left alone, so an unchanged
    /// storm does not blink on a two-minute radar frame or a five-minute bulletin poll.
    ///
    /// Every field that changes the drawing is in here, and the first vertex is in it for the reason
    /// `updateTFRs` records: a re-issued product keeps its id and its vertex count while the boundary
    /// moves, and a count-only digest leaves the old shape drawn in the old place.
    static func digest(_ cell: ConvectiveCell, at: Date, isThreat: Bool) -> String {
        let p0 = cell.polygon.first ?? Coord(lat: 0, lon: 0)
        return String(format: "%@|%d|%.4f|%.4f|%@|%@|%.0f|%.0f|%d|%.0f",
                      cell.id, cell.polygon.count, p0.lat, p0.lon,
                      topsText(cell), baseText(cell),
                      cell.movingTowardDeg ?? -1, cell.motionKt ?? -1,
                      isThreat ? 1 : 0, at.timeIntervalSince1970)
    }
}

/// What `rendererFor` needs to know about a storm overlay it is handed back. Kept in an
/// identity-keyed side map, exactly as the hazard and TFR layers do it, so a storm polygon can never
/// be mistaken for airspace and vice versa.
struct ConvectiveOverlayStyle {
    /// This cell is one the alert is currently warning about, as opposed to one merely known to be
    /// there. The distinction is carried by WEIGHT, not by hue: same violet, a bolder outline and a
    /// fill you can see. One layer, one colour, two voices.
    let isThreat: Bool
    /// The cell's motion was DERIVED from radar rather than stated by a forecaster, so its arrow is
    /// dashed. `RadarCellFinder.fieldMotion` recovers direction to about 13° but reads speed 20–25%
    /// LOW, every time, for a structural reason recorded where it is measured — a dashed shaft is the
    /// cheapest honest way to say "this vector was computed here, and it is a floor on the speed".
    let isDerivedMotion: Bool
}

extension ChartMapView.Coordinator {

    /// Reconcile the storm-cell layer against `cells` in place — the hazard/TFR diff pattern: an
    /// unchanged cell is left untouched, a departed one is removed, an arrival is added, and a cell
    /// whose shape, tops, motion or threat status changed is torn down and re-added.
    ///
    /// `threatIDs` is the set of cell ids the banner is currently warning about, which is why they are
    /// passed in rather than recomputed here: both come out of the same pass in
    /// `AppModel.applyConvectiveThreats`, so the emphasis on the map and the text on the banner cannot
    /// disagree about which storm is the problem.
    ///
    /// Toggle-off (and the thermal/background pause) passes `[]`, which clears everything.
    func syncConvectiveCells(_ mv: MKMapView, cells: [ConvectiveCell],
                             threatIDs: Set<String>, at: Date) {
        assert(Thread.isMainThread, "overlay mutation must run on the main thread")
        assert(threatIDs.count <= ConvectiveAlert.maxCells, "threat set is capped by the alert")
        let wanted = ConvectiveCellDraw.drawable(cells)
        // The tap table, replaced wholesale rather than diffed: it has to hold every cell currently
        // drawn, including the survivors the loop below skips, and a departed cell has to leave it in
        // the same pass that removes its overlay. Taking it from `wanted` and the same `at` the rings
        // are built from is what guarantees a tap can only ever identify a cell that is on the screen,
        // with the ring it was actually drawn with.
        stormCellByID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        stormDrawAt = at
        var wantedDigest: [String: String] = [:]
        for c in wanted {
            wantedDigest[c.id] = ConvectiveCellDraw.digest(c, at: at, isThreat: threatIDs.contains(c.id))
        }
        for (id, prev) in stormDigestByKey where wantedDigest[id] != prev {
            removeStormCell(id, from: mv)                            // departed, or changed → re-added below
        }
        var addedLabels: [AirspaceLabelAnnotation] = []
        for c in wanted {
            stormDigestByKey[c.id] = wantedDigest[c.id]
            guard stormShapeByKey[c.id] == nil else { continue }      // survivor — untouched
            let ring = ConvectiveCellDraw.ring(c, at: at)
            guard ring.count >= 2 else { continue }
            let isThreat = threatIDs.contains(c.id)
            let style = ConvectiveOverlayStyle(isThreat: isThreat, isDerivedMotion: c.source == .radar)
            let coords = ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            // A 2-point LINE TS has no interior to fill, so it is drawn as the line it is. Anything
            // else is a polygon. See `ConvectiveCellDraw.ring`.
            let shape: MKOverlay = coords.count == 2
                ? MKPolyline(coordinates: coords, count: coords.count)
                : MKPolygon(coordinates: coords, count: coords.count)
            stormOverlayStyle[ObjectIdentifier(shape)] = style
            stormShapeByKey[c.id] = shape
            mv.addOverlay(shape, level: .aboveLabels)

            let arrow = ConvectiveCellDraw.motionArrow(c, at: at)
            if arrow.count >= 2 {
                let ac = arrow.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let line = StormMotionPolyline(coordinates: ac, count: ac.count)
                stormOverlayStyle[ObjectIdentifier(line)] = style
                stormArrowByKey[c.id] = line
                mv.addOverlay(line, level: .aboveLabels)
            }
            if let top = ConvectiveCellDraw.labelCoord(ring) {
                let label = AirspaceLabelAnnotation(
                    coord: CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon),
                    ceiling: ConvectiveCellDraw.topsText(c),
                    floor: ConvectiveCellDraw.baseText(c),
                    color: mapTheme.convective)
                stormLabelByKey[c.id] = label
                addedLabels.append(label)
            }
        }
        if !addedLabels.isEmpty { mv.addAnnotations(addedLabels) }
        assert(stormShapeByKey.count <= ConvectiveCellDraw.maxDrawn, "storm overlay count bounded")
    }

    private func removeStormCell(_ id: String, from mv: MKMapView) {
        if let shape = stormShapeByKey.removeValue(forKey: id) {
            mv.removeOverlay(shape); stormOverlayStyle[ObjectIdentifier(shape)] = nil
        }
        if let arrow = stormArrowByKey.removeValue(forKey: id) {
            mv.removeOverlay(arrow); stormOverlayStyle[ObjectIdentifier(arrow)] = nil
        }
        if let label = stormLabelByKey.removeValue(forKey: id) { mv.removeAnnotation(label) }
        stormDigestByKey[id] = nil
    }

    /// The storm cells under the finger, as probe candidates for `MapProbe.merge`.
    ///
    /// Two hit tests, because the layer draws two kinds of shape:
    ///
    /// * a ring is tested **geometrically**, against the outline as drawn, so a tap inside a cell
    ///   identifies it at any zoom — the same choice `rankProbe` makes for TFRs and for the same
    ///   reason (a rendered-feature query is limited by what the renderer tessellated);
    /// * a 2-point LINE TS has no interior, so it is tested by **on-screen distance** to the segment,
    ///   within the tap radius, exactly as `airwayCandidates` makes an airway tappable along its
    ///   length. Without this half the squall line — the shape in this feed most worth asking about —
    ///   would be the one cell on the map that could not be tapped at all.
    ///
    /// Reads `stormCellByID` and `stormDrawAt`, both written by `syncConvectiveCells` from the same
    /// list and the same instant it drew, so there is no second copy of the geometry to drift.
    func stormCandidates(at pt: CGPoint, here: Coord, radius: Double, in mv: MKMapView) -> [IdentifiedObject] {
        assert(radius >= 0, "stormCandidates: negative radius")
        assert(stormCellByID.count <= ConvectiveCellDraw.maxDrawn, "storm tap table bounded")
        var out: [IdentifiedObject] = []
        var hit = Set<String>()
        let drawn = ConvectiveCellDraw.drawable(Array(stormCellByID.values))
        for c in drawn where ConvectiveCellDraw.contains(c, at: stormDrawAt, here) {
            guard hit.insert(c.id).inserted else { continue }
            out.append(ConvectiveCellDraw.object(c, at: stormDrawAt))
        }
        for c in drawn where !hit.contains(c.id) {                                  // bounded (rule 2)
            let r = ConvectiveCellDraw.ring(c, at: stormDrawAt)
            guard r.count == 2 else { continue }
            let a = mv.convert(CLLocationCoordinate2D(latitude: r[0].lat, longitude: r[0].lon), toPointTo: mv)
            let b = mv.convert(CLLocationCoordinate2D(latitude: r[1].lat, longitude: r[1].lon), toPointTo: mv)
            guard Self.segmentDist(pt, a, b) <= radius else { continue }
            hit.insert(c.id)
            out.append(ConvectiveCellDraw.object(c, at: stormDrawAt))
        }
        // Stable, so two taps on the same overlapping pair put the same cell at the top of the
        // chooser. Nothing better to sort by: both are under the finger and neither is "nearer".
        out.sort { $0.ident < $1.ident }
        assert(out.count <= ConvectiveCellDraw.maxDrawn, "storm candidates bounded")
        return out
    }

    /// The renderer for a storm overlay, or nil when the overlay is not one of ours.
    ///
    /// Split out of `rendererFor` so the weights live beside the geometry that justifies them rather
    /// than halfway down a 100-line switch.
    func stormRenderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let style = stormOverlayStyle[ObjectIdentifier(overlay)] else { return nil }
        let color = mapTheme.convective
        if let poly = overlay as? MKPolygon {
            let r = MKPolygonRenderer(polygon: poly)
            r.strokeColor = color
            r.lineWidth = style.isThreat ? 3.0 : 1.6
            // The fill a pilot can see belongs to the cell being warned about. A known cell that the
            // track misses gets a wash faint enough to read the chart through — it is context, and
            // over a precipitation mosaic it is context on top of context.
            r.fillColor = color.withAlphaComponent(style.isThreat ? 0.22 : 0.07)
            return r
        }
        if let line = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = color
            let isArrow = line is StormMotionPolyline
            r.lineWidth = isArrow ? (style.isThreat ? 2.6 : 1.6) : (style.isThreat ? 3.0 : 1.6)
            if isArrow && style.isDerivedMotion { r.lineDashPattern = [5, 4] }
            r.lineJoin = .round
            return r
        }
        return nil
    }
}

/// A storm's motion arrow. A subclass purely so the renderer can tell a cell's own 2-point LINE TS
/// outline from the arrow attached to it — both are polylines carrying the same style, and the arrow
/// is the one that may be dashed.
final class StormMotionPolyline: MKPolyline {}
