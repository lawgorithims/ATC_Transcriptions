import Foundation

// MARK: - Great-circle helpers the glide sweep needs (extending the shared house geodesy)

extension Geo {
    /// Destination point from `c` along `bearingDeg` (TRUE) for `distanceNm` — standard great-circle
    /// forward solution on the same R = 3440.065 NM sphere as `nmBetween`.
    static func destination(from c: Coord, bearingDeg: Double, distanceNm: Double) -> Coord {
        let R = 3440.065
        let d = distanceNm / R
        let brg = bearingDeg * .pi / 180
        let la1 = c.lat * .pi / 180, lo1 = c.lon * .pi / 180
        let la2 = asin(sin(la1) * cos(d) + cos(la1) * sin(d) * cos(brg))
        let lo2 = lo1 + atan2(sin(brg) * sin(d) * cos(la1), cos(d) - sin(la1) * sin(la2))
        var lonDeg = lo2 * 180 / .pi
        if lonDeg > 180 { lonDeg -= 360 }; if lonDeg < -180 { lonDeg += 360 }
        return Coord(lat: la2 * 180 / .pi, lon: lonDeg)
    }

    /// Point `fraction` (0…1) of the way along the great circle a→b (spherical interpolation, so a
    /// long path sags correctly instead of cutting the chord through lat/lon space).
    static func interpolate(_ a: Coord, _ b: Coord, fraction f: Double) -> Coord {
        let delta = nmBetween(a, b) / 3440.065
        guard delta > 1e-9 else { return a }
        let A = sin((1 - f) * delta) / sin(delta), B = sin(f * delta) / sin(delta)
        let la1 = a.lat * .pi / 180, lo1 = a.lon * .pi / 180
        let la2 = b.lat * .pi / 180, lo2 = b.lon * .pi / 180
        let x = A * cos(la1) * cos(lo1) + B * cos(la2) * cos(lo2)
        let y = A * cos(la1) * sin(lo1) + B * cos(la2) * sin(lo2)
        let z = A * sin(la1) + B * sin(la2)
        return Coord(lat: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, lon: atan2(y, x) * 180 / .pi)
    }
}

// MARK: - Terrain seam

/// The one terrain question the glide sweep asks, as a protocol so tests inject synthetic grids and
/// the engine can be handed a background-queue `TerrainElevation` instance (the shared one is
/// main-actor-only by convention — see its type comment).
protocol TerrainSampling {
    var isReady: Bool { get }
    func sampleElevationFt(at coord: Coord) -> Double?
}

extension TerrainElevation: TerrainSampling {
    var isReady: Bool { isAvailable }
    func sampleElevationFt(at coord: Coord) -> Double? { elevationFt(at: coord) }
}

// MARK: - Inputs

/// The ownship snapshot a NRST assessment is computed from. A pure value so the engine never reads
/// live state mid-computation — the caller freezes the fix once, on the main actor, and hands it over.
struct GlideSituation: Equatable, Sendable {
    let coord: Coord
    let altitudeFtMSL: Double        // orthometric MSL feet (same datum as the terrain grid)
    let glideRatio: Double           // best-glide L/D actually used (profile's, or the default)
    let isDefaultGlideRatio: Bool    // true when no profile number existed — the UI must say so
    let verticalAccuracyM: Double?   // GPS vertical 1-sigma; nil = unknown (assume coarse)
    /// Age of the altitude this situation was built from. 0 = a live GPS altitude. Non-zero means the
    /// receiver stopped reporting altitude and the last known one was CARRIED FORWARD — see
    /// `NearestAirports.carriedAltitudeFt`. The UI must say so: every range on the list is then an
    /// estimate about a number nobody is currently measuring.
    var altitudeAgeS: Double = 0
    var isAltitudeCarried: Bool { altitudeAgeS > 0 }
}

/// Per-station weather the ranker consumes, pre-resolved by the caller (the engine stays sync + pure;
/// fetching is the store's job). Keyed by `NearestAirports.wxIdent(for:)` of the candidate.
struct NRSTWeather: Equatable, Sendable {
    let category: Metar.Category
    let ageMinutes: Int?             // nil = age unknown (still ranked, shown unaged)
}

// MARK: - Output

/// Why a reachable-by-the-numbers field is filed under CAUTION instead of CLEAR.
enum NRSTCaution: String, Equatable, Sendable {
    case terrainUnknown   // the sweep crossed a no-data cell / left grid coverage — clearance unverified
    case thinMargin       // clears terrain, but arrives with less than `thinArrivalMarginFt` to spare
}

/// Where a candidate stands against the glide. The order is the display order.
enum NRSTReachability: Equatable, Sendable {
    case clear                       // in glide, terrain-swept, arrives with margin
    case caution(NRSTCaution)        // in glide, but see the caution
    case blocked(atNm: Double)       // in glide by distance, terrain intersects the descent path
    case outOfGlide                  // beyond still-air range

    var isReachable: Bool { if case .clear = self { return true }; if case .caution = self { return true }; return false }
    /// Coarse sort group: clear < caution < blocked < outOfGlide.
    var group: Int {
        switch self { case .clear: return 0; case .caution: return 1; case .blocked: return 2; case .outOfGlide: return 3 }
    }
}

/// One ranked field. Everything the panel row shows is on here — the view must not re-derive.
struct NRSTCandidate: Identifiable, Equatable, Sendable {
    let airport: AirportData.Airport
    let distanceNm: Double
    let bearingTrueDeg: Double
    let reachability: NRSTReachability
    let arrivalMarginFt: Double?     // altitude to spare ABOVE the 1,000 ft arrival reserve (in-glide only)
    let category: Metar.Category     // .unknown when the field has no report
    let wxAgeMinutes: Int?
    let longestRunwayFt: Double?
    let longestRunwayPaved: Bool
    let longestRunwayLit: Bool
    let terrainRiseFt: Double?       // max terrain rise above field elev in the vicinity ring (nil = unknown)
    let score: Double                // composite rank inside its reachability group
    var id: String { airport.ident }
}

/// A full assessment — the list, plus the situation it was computed from so the UI can caption it
/// honestly ("from 6,500 ft · 9:1 · still air").
struct NRSTAssessment: Equatable, Sendable {
    let generatedAt: Date
    let situation: GlideSituation
    let stillAirRangeNm: Double      // best-case ground range to a sea-level field, for the caption
    let terrainAvailable: Bool
    /// Terrain elevation under the aircraft, from the same grid the glide paths are swept against.
    /// nil = outside coverage (the glide ranges still stand — they are height above each FIELD — but
    /// nothing here can be said about the ground below).
    let ownshipTerrainFt: Double?
    let candidates: [NRSTCandidate]  // display order: group, then score desc, then distance

    /// Height above the terrain model under the aircraft, feet.
    ///
    /// This is what a pilot means by "how high am I" and it is NOT what sets glide range — range is
    /// height above the destination FIELD's elevation, which is why each candidate carries its own
    /// margin. AGL is here because it is what tells the pilot how much time they have, and because a
    /// glide over a rising valley floor can be a long way from the ground while barely above the ridge
    /// ahead. Advisory, and the same surface model caveats as the AGL readout apply (canopy and
    /// buildings are IN it, so low readings over forest are normal).
    var ownshipAglFt: Double? { ownshipTerrainFt.map { situation.altitudeFtMSL - $0 } }
}

/// The live NRST engagement: which field the pilot committed to, and the EXACT pre-engage plan so
/// the banner's Restore is a true undo. The frequency line is resolved ONCE at engage (a SQLite
/// read has no business running per render inside a banner).
///
/// PERSISTED, because the undo is a guarantee-level control. Engaging immediately overwrites the
/// filed plan in `UserDefaults` (the `flightPlan` didSet saves), so an in-memory-only snapshot
/// evaporated the moment iOS jettisoned a backgrounded app — routine on a cockpit iPad — leaving the
/// pilot with a direct-to they may have tapped by accident and no way back to the plan they filed.
/// The no-confirm engage is justified by reversibility, so the reversibility has to survive a
/// process death too.
struct NRSTEngagement: Equatable, Codable {
    let ident: String                // FAA ident — stable key into the candidate list
    let displayIdent: String         // what the banner shows (ICAO when the field has one)
    let name: String
    let coord: Coord
    /// The route ident actually filed as the destination (ICAO, FAA ident, or a "lat,lon" user-point
    /// token). Kept so the engagement can be reconciled against the live plan: this is what the
    /// destination must still equal for the banner's claim to be true.
    let routeTarget: String
    let engagedAt: Date
    let priorPlan: FlightPlan?       // nil = there was no filed plan (Restore clears back to none)
    var frequencyLine: String?       // "CTAF 122.8" — what to call once established on the glide

    static let storageKey = "atc.nrstEngagement"

    /// Restore a persisted engagement (nil when none / undecodable). The banner it drives is only
    /// coherent if the live plan still flies to `routeTarget`; `AppModel` reconciles that on load.
    static func load() -> NRSTEngagement? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(NRSTEngagement.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }
}

// MARK: - Engine

/// The engine-out NRST engine: which fields can this airplane GLIDE to, and in what order should a
/// pilot who just lost the engine consider them?
///
/// Pure math over injected data — no database handles, no stores, no clocks of its own — following
/// the `PlateSimilarity` convention so every branch is unit-testable. The caller (AppModel) gathers
/// candidates, runways, weather and a terrain sampler, freezes the ownship situation, and calls
/// `assess` off the main actor.
///
/// RANKING DOCTRINE (the pilot-specified hierarchy, in order):
///   1. In glide, terrain-checked — a three-track corridor sweep of the direct descent profile
///      against the bundled grid splits candidates into CLEAR / CAUTION / BLOCKED / OUT OF GLIDE.
///      Anything the sweep cannot verify (grid hole, off-coverage) is CAUTION, never CLEAR: unknown
///      terrain must not outrank verified terrain (fail-closed).
///   2. Weather — VFR > MVFR > unknown > IFR > LIFR, live METAR when the network has one.
///   3. Terrain around the field — max rise above field elevation in a surrounding ring.
///   4. Runways — longest usable (helipads/water/failed excluded), paved and lit as bonuses.
///   5. Facilities — Part-139/ARFF on the field first, else tower + fuel + public-use.
/// Tier 2 is LEXICOGRAPHIC above tiers 3–5: within a reachability group, a better flight category
/// always outranks any combination of runway/facility/terrain advantages — "two airports in glide,
/// one visual: the visual one", even against a Part-139 field with a 12,000 ft runway. Tiers 3–5
/// then combine as a weighted score whose weights descend in hierarchy order, with the still-air
/// arrival margin as a small tiebreak. The still-air assumption is deliberate: the app has no
/// offline wind source, and the conservative default ratio plus the arrival reserve absorb it.
enum NearestAirports {

    // Named constants (rule 2: every loop bound and physical assumption has a name).
    static let defaultGlideRatio = 7.0        // conservative GA single; C172 books ~9:1
    static let ftPerNm = 6076.115
    static let arrivalReserveFt = 1000.0      // arrive over the field no lower than pattern height
    static let enrouteBufferFt = 500.0        // discretionary clearance over swept terrain
    static let thinArrivalMarginFt = 500.0    // less to spare than this → CAUTION, not CLEAR
    /// How far from either endpoint the "the endpoint's own cell is not an obstacle" rule applies —
    /// one terrain cell (cells are ~1 NM across; see `TerrainElevation`). Inside it, terrain no
    /// HIGHER than that endpoint's own reading is not evidence of an obstruction. See `reachability`.
    static let endpointCellNm = 1.0
    static let sampleSpacingNm = 0.5          // ~half a terrain cell — bounds aliasing between cells
    static let corridorOffsetNm = 0.75        // lateral tracks either side of the direct course
    static let vicinityRingNm = [3.0, 5.0]    // terrain-hostility rings around the field
    static let vicinityBearings = 8           // samples per ring
    static let maxPathSamples = 256           // hard cap on stations per sweep (≥ 100 NM at 0.5 NM)
    static let maxSweptAirports = 256         // hard cap on fields swept per assessment (rule 2)
    static let maxCandidates = 40             // fields DISPLAYED, applied after ranking (never before)
    static let defaultVerticalAccuracyM = 25.0
    static let staleWxMinutes = 180           // a METAR older than this ranks as unknown weather
    static let minRunwayFt = 1800.0, fullRunwayFt = 5000.0   // runway-length score anchors
    static let terrainRiseEasyFt = 500.0, terrainRiseHostileFt = 5000.0
    // Tier 3–5 weights — descending per the hierarchy (weather is lexicographic ABOVE these, so it
    // has no weight: it cannot be traded away). Margin is a tiebreak, not a tier.
    static let wTerrain = 0.42, wRunway = 0.30, wFacility = 0.16, wMargin = 0.12

    /// Search radius for candidate gathering: comfortably past still-air range so "just out of glide"
    /// fields appear (greyed) instead of vanishing, bounded to keep the DB box sane.
    static func searchRadiusNm(for situation: GlideSituation) -> Double {
        let range = stillAirRangeNm(situation, fieldElevFt: 0)
        return min(100, max(15, range * 1.3))
    }

    // MARK: altitude — the one input the whole feature scales off

    /// Past this age a carried-forward altitude is refused outright. A minute of gliding is several
    /// hundred feet and a mile of range; beyond that the honest answer is "I don't know how high you
    /// are", not a ranked list built on a number from another part of the flight.
    static let maxAltitudeAgeS = 60.0
    /// Best-glide speed assumed when the aircraft profile has none — only used to size the descent
    /// allowance below, never the glide range itself.
    static let defaultBestGlideKts = 70.0

    /// Still-air sink at best glide, ft/min: a glide ratio is horizontal-over-vertical, so at `kts`
    /// the aircraft descends `kts / ratio` NM per hour. (9:1 at 65 kt ≈ 731 fpm — the C172 book figure.)
    static func glideSinkFpm(glideRatio: Double, bestGlideKts: Double? = nil) -> Double {
        assert(glideRatio > 0, "glide ratio must be positive")
        let kts = bestGlideKts ?? defaultBestGlideKts
        assert(kts > 0, "best-glide speed must be positive")
        return kts / glideRatio * ftPerNm / 60
    }

    /// The last known altitude carried forward to now, DESCENDING at `sinkFpm`.
    ///
    /// It only ever goes DOWN. The aircraft this feature exists for is losing height, so crediting a
    /// stale altitude would overstate every range on the list — the one direction that gets a pilot
    /// killed. Carrying it downward instead understates range, which shortens the list and is
    /// survivable. Floored at zero so a long gap can't produce a negative altitude.
    static func carriedAltitudeFt(lastFtMSL: Double, ageS: Double, sinkFpm: Double) -> Double {
        assert(ageS >= 0, "age is elapsed time")
        assert(sinkFpm >= 0, "sink is a descent rate, sign handled by the caller")
        return max(0, lastFtMSL - sinkFpm * (ageS / 60))
    }

    /// Ground distance the airplane can cover from the situation altitude down to `fieldElevFt` plus
    /// the arrival reserve, still air. Zero when already below the reserve.
    static func stillAirRangeNm(_ s: GlideSituation, fieldElevFt: Double) -> Double {
        assert(s.glideRatio > 0, "glide ratio must be positive")
        assert(ftPerNm > 6000 && ftPerNm < 6100, "feet-per-NM constant sane")
        let spendFt = s.altitudeFtMSL - fieldElevFt - arrivalReserveFt
        guard spendFt > 0 else { return 0 }
        return spendFt / ftPerNm * s.glideRatio
    }

    /// The ident to fetch/read weather under: the record's ICAO, or nil when it has none.
    ///
    /// There is deliberately NO "prepend K to a 3-letter FAA ident" fallback. Measured against the
    /// shipped NASR cycle, every CONUS 3-alpha field that reports already carries its ICAO in the
    /// `icao` column — so the fallback fired on exactly 54 rows, 53 of them ALASKA (PA-prefixed) plus
    /// Angaur in Palau, i.e. only where the K convention is wrong. Its entire effect was to request
    /// weather under a fabricated ident (KENA for PAEN), get nothing back, and rank a field as
    /// no-report that in fact reports.
    static func wxIdent(for airport: AirportData.Airport) -> String? {
        let icao = airport.icao.trimmingCharacters(in: .whitespaces).uppercased()
        return icao.count == 4 ? icao : nil
    }

    // MARK: engage support (pure; the caller injects the lookups)

    /// A resolved ident this far from the ranked field is a different place with the same name.
    static let targetToleranceNm = 3.0

    /// The route ident that is guaranteed to draw AT the ranked field.
    ///
    /// Validated by LOCATION, not by existence. `resolve` answers "where does the nav database put
    /// this ident", and idents are not unique across the FAA and ICAO sets — so merely checking that
    /// an ident resolves happily accepted one whose entry sits somewhere else entirely, and the
    /// ranked field and the magenta line would disagree. Anything that does not land within
    /// `targetToleranceNm` of the ranked coordinate falls back to the exact coordinate as a
    /// user-point token, which cannot be misplaced.
    static func routeTarget(for airport: AirportData.Airport, resolve: (String) -> Coord?) -> String {
        assert(airport.coord.lat.isFinite && airport.coord.lon.isFinite, "ranked field has a real coordinate")
        assert(targetToleranceNm > 0, "tolerance is a distance")
        for ident in [airport.icao, airport.ident] where !ident.isEmpty {
            if let c = resolve(ident), Geo.nmBetween(c, airport.coord) <= targetToleranceNm { return ident }
        }
        return UserPoint.token(airport.coord)
    }

    /// The one frequency worth putting on the engagement banner: CTAF first (that is who a glider-in
    /// announces to at the strips this feature mostly points at), else tower, else unicom.
    ///
    /// The tower tier matches NASR's `LCL/P`/`LCL/S` (local control) — NOT the string "TWR", which
    /// does not occur as a FREQ_USE value at all. Matching "TWR" made the tower branch dead code, so
    /// 247 operational towered fields (DEN, LAX, SFO, DFW…) that publish no separate CTAF row fell
    /// through to UNICOM 122.95 — an aircraft-to-aircraft frequency nobody in the tower cab is
    /// listening to, printed on the one line the banner offers as "who to call", at exactly the
    /// Part-139 fields the ranker deliberately promotes.
    static func frequencyLine(from frequencies: [AirportData.Frequency]) -> String? {
        let tiers: [(match: String, label: String)] = [("CTAF", "CTAF"), ("LCL", "TWR"), ("UNIC", "UNICOM")]
        assert(tiers.count == 3, "CTAF then tower then unicom")
        for tier in tiers {                                  // bounded: three tiers
            if let f = frequencies.first(where: { $0.use.uppercased().hasPrefix(tier.match) }) {
                // NAME THE QUALIFIER WHEN THERE IS ONE. 10,562 frequency rows carry a sectorization
                // string, and on 10,104 of them at 2,910 airports another frequency at the same field
                // shares the same use tag — so the qualifier is the ONLY thing distinguishing them. 594
                // airports publish more than one tower frequency. Offering one of several with no
                // indication that it serves a single side or runway of the field is a silent choice
                // made on the pilot's behalf, and this line is what the engine-out banner reads.
                let q = f.sectorization.trimmingCharacters(in: .whitespaces)
                return q.isEmpty ? "\(tier.label) \(f.value)"
                                 : "\(tier.label) \(f.value) (\(q.prefix(24)))"
            }
        }
        return nil
    }

    // MARK: assessment

    /// Rank `airports` for an engine-out glide from `situation`. Pure; safe off-main when `terrain`
    /// is an instance owned by the calling queue.
    static func assess(situation: GlideSituation,
                       airports: [AirportData.Airport],
                       runwaysFor: (String) -> [AirportData.Runway],
                       weather: [String: NRSTWeather],
                       terrain: TerrainSampling,
                       now: Date) -> NRSTAssessment {
        assert(situation.glideRatio > 0, "caller resolves the ratio before calling")
        assert(airports.count <= 4096, "candidate list is a bounded DB read")
        var out: [NRSTCandidate] = []
        // EVERY supplied field is swept; the display cap is applied AFTER ranking. Capping the input
        // instead (nearest-first from the DB) could drop the best field in glide: in dense airspace
        // the nearest 40 records are mostly private strips and helipads, so a good public field 12 NM
        // out could fall outside the window and never be ranked at all — a silent truncation the
        // pilot would read as "that airport is not reachable".
        for airport in airports.prefix(maxSweptAirports) {   // bounded (rule 2)
            guard let built = candidate(for: airport, situation: situation,
                                        runwaysFor: runwaysFor, weather: weather,
                                        terrain: terrain, now: now) else { continue }
            out.append(built)
        }
        assert(out.count <= maxSweptAirports, "swept set bounded")
        out.sort {
            if $0.reachability.group != $1.reachability.group { return $0.reachability.group < $1.reachability.group }
            if $0.reachability.isReachable {
                // Tier 2 is lexicographic: a better flight category cannot be outbid by runways or
                // facilities — the pilot's rule is "both in glide, one visual → the visual one".
                let (a, b) = (wxRank($0.category), wxRank($1.category))
                if a != b { return a < b }
                if $0.score != $1.score { return $0.score > $1.score }
            }
            return $0.distanceNm < $1.distanceNm
        }
        return NRSTAssessment(generatedAt: now, situation: situation,
                              stillAirRangeNm: stillAirRangeNm(situation, fieldElevFt: 0),
                              terrainAvailable: terrain.isReady,
                              ownshipTerrainFt: terrain.isReady
                                  ? terrain.sampleElevationFt(at: situation.coord) : nil,
                              candidates: Array(out.prefix(maxCandidates)))
    }

    /// Build one ranked candidate, or nil when the facility is not a place an airplane lands
    /// (closed, heliport/seaplane/balloon/ultralight, or nothing but helipads and water in NASR).
    private static func candidate(for airport: AirportData.Airport, situation: GlideSituation,
                                  runwaysFor: (String) -> [AirportData.Runway],
                                  weather: [String: NRSTWeather],
                                  terrain: TerrainSampling, now: Date) -> NRSTCandidate? {
        guard airport.isOperational, !airport.isNonAirplaneFacility else { return nil }
        let runways = runwaysFor(airport.ident)
        let usable = runways.filter { !$0.isHelipad && !$0.isFailed && $0.surface.uppercased() != "WATER" }
        // NASR has runway rows for ~every airplane field; a record with rows but none usable is a
        // heliport/seaplane in disguise (pre-site_type DB cycles). No rows at all = unknown, keep it.
        guard runways.isEmpty || !usable.isEmpty else { return nil }
        guard let fieldElevFt = airport.elevationFt ?? terrain.sampleElevationFt(at: airport.coord) else { return nil }

        let distanceNm = Geo.nmBetween(situation.coord, airport.coord)
        let bearing = Geo.bearing(situation.coord, airport.coord)
        let rangeNm = stillAirRangeNm(situation, fieldElevFt: fieldElevFt)
        let marginFt = (rangeNm - distanceNm) / situation.glideRatio * ftPerNm
        let reach = reachability(situation: situation, to: airport.coord, distanceNm: distanceNm,
                                 inGlide: distanceNm <= rangeNm, arrivalMarginFt: marginFt, terrain: terrain)

        let wx = weather[wxIdent(for: airport) ?? ""]
        let category = effectiveCategory(wx)
        let longest = usable.compactMap { r in r.lengthFt.map { (len: $0, r: r) } }.max { $0.len < $1.len }
        let rise = vicinityRiseFt(around: airport.coord, fieldElevFt: fieldElevFt, terrain: terrain)
        let score = composite(riseFt: rise, longest: longest?.len,
                              paved: longest?.r.isPaved ?? false, lit: !(longest?.r.lights.isEmpty ?? true),
                              airport: airport, marginFt: marginFt)
        return NRSTCandidate(airport: airport, distanceNm: distanceNm, bearingTrueDeg: bearing,
                             reachability: reach,
                             arrivalMarginFt: reach.isReachable ? max(0, marginFt) : nil,
                             category: category, wxAgeMinutes: wx?.ageMinutes,
                             longestRunwayFt: longest?.len,
                             longestRunwayPaved: longest?.r.isPaved ?? false,
                             longestRunwayLit: !(longest?.r.lights.isEmpty ?? true),
                             terrainRiseFt: rise, score: score)
    }

    // MARK: tier 1 — the terrain sweep

    /// Classify one field against the glide. The sweep walks the DIRECT descent profile — altitude
    /// bleeding off linearly with along-track distance at the glide ratio — and requires each swept
    /// terrain station to sit below it by `enrouteBufferFt` PLUS the grid's own optimism margin (GPS
    /// vertical sigma + measured peak under-read, exactly `AGLReading.marginFt`'s formula).
    ///
    /// THE MARGIN IS NEVER DISCOUNTED. It is not a comfort pad, it is compensation for two
    /// measurement errors that are one-sided in the OPTIMISTIC direction and do not shrink with
    /// distance: the grid under-reads summits (`peakUnderReadM`, sized to the shipped grid's measured
    /// residual) and the GPS altitude the whole profile hangs off has its own sigma. An earlier
    /// version ramped the entire buffer to zero near the ownship, which made the requirement SMALLER
    /// than the known error for the first ~0.8 NM — a 1-sigma-high fix over an under-read ridge could
    /// then be ranked CLEAR with the true glide path passing through rock.
    ///
    /// ENDPOINT CELLS ARE NOT OBSTACLES. Cells are ~1 NM across and hold the MAXIMUM elevation
    /// inside them, so the aircraft's own cell routinely reads ABOVE the aircraft (flying a valley
    /// beside a ridge, or over canopy — `AGLReading.isBelowSurfaceModel` documents this as normal).
    /// Comparing that reading against the profile blocked EVERY candidate at 0.0 NM whenever the
    /// pilot was low near terrain — the exact blanking this feature must not do. The rule instead:
    /// within `endpointCellNm` of either end, terrain no HIGHER than that endpoint's own reading is
    /// not evidence of an obstruction — the aircraft is demonstrably flying over its cell, and the
    /// field demonstrably sits in its own. Anything higher than the endpoint reading is still
    /// checked in full, so a genuine ridge 0.6 NM ahead is caught.
    static func reachability(situation: GlideSituation, to dest: Coord, distanceNm: Double,
                             inGlide: Bool, arrivalMarginFt: Double,
                             terrain: TerrainSampling) -> NRSTReachability {
        guard inGlide else { return .outOfGlide }
        guard terrain.isReady else { return .caution(.terrainUnknown) }
        assert(distanceNm >= 0, "distance is a metric")
        assert(maxPathSamples >= 2, "a sweep has at least both ends")

        let stations = min(maxPathSamples, max(2, Int(distanceNm / sampleSpacingNm) + 1))
        let ftPerNmDown = ftPerNm / situation.glideRatio
        let buffer = enrouteBufferFt
                   + ((situation.verticalAccuracyM ?? defaultVerticalAccuracyM)
                      + TerrainElevation.peakUnderReadM) * GPSReadout.mToFt
        // The endpoints' own readings, taken through the same corridor so the comparison is like for
        // like. A nil here means the endpoint sits on a data hole — that is a hole, handled below.
        // ONE axis for every station on this sweep. See `corridorMaxFt` for why it is not recomputed
        // per station: at the far end the two points coincide and the recomputed bearing is noise.
        let axis = sweepAxisDeg(from: situation.coord, to: dest)
        let ownFloor = corridorMaxFt(center: situation.coord, axisDeg: axis, terrain: terrain)
        let fieldFloor = corridorMaxFt(center: dest, axisDeg: axis, terrain: terrain)
        var sawHole = (ownFloor == nil || fieldFloor == nil)
        for i in 0...stations {                              // bounded by maxPathSamples (rule 2)
            let f = Double(i) / Double(stations)
            let d = f * distanceNm
            let center = Geo.interpolate(situation.coord, dest, fraction: f)
            let profileFt = situation.altitudeFtMSL - d * ftPerNmDown
            guard let sample = corridorMaxFt(center: center, axisDeg: axis, terrain: terrain) else {
                sawHole = true
                continue                                      // unverifiable ≠ blocked; noted below
            }
            if sample.sawHole { sawHole = true }               // a lateral track left coverage
            // Endpoint-cell rule (see the doc comment): near an end, terrain no higher than that
            // end's own reading is the end's own terrain, not an obstruction between them.
            if d < endpointCellNm, let floor = ownFloor?.maxFt, sample.maxFt <= floor { continue }
            if distanceNm - d < endpointCellNm, let floor = fieldFloor?.maxFt, sample.maxFt <= floor { continue }
            if sample.maxFt > profileFt - buffer { return .blocked(atNm: d) }
        }
        if sawHole { return .caution(.terrainUnknown) }
        if arrivalMarginFt < thinArrivalMarginFt { return .caution(.thinMargin) }
        return .clear
    }

    /// One station's corridor reading: the max across the direct course line and `corridorOffsetNm`
    /// either side of it (track error, wind drift, cell-edge effects), plus whether any of the three
    /// tracks left coverage.
    ///
    /// `sawHole` exists because silently dropping an off-grid LATERAL sample would let a candidate
    /// whose corridor runs off the edge of the grid — a coastal or border glide — rank CLEAR on the
    /// strength of the two tracks that happened to be inside coverage. Unverified is CAUTION.
    /// Nil (not merely `sawHole`) only when the CENTER sample itself is unavailable.
    /// The corridor's lateral axis for a whole sweep: the great-circle course from the ownship to the
    /// field, taken ONCE.
    ///
    /// It used to be recomputed per station as `Geo.bearing(center, dest)`, which is undefined at the far
    /// end: the last station is `interpolate(..., fraction: 1)`, i.e. `dest` up to floating-point noise,
    /// so `atan2` there resolves that noise into an arbitrary heading and the two lateral tracks landed on
    /// a RANDOM axis. That station is the one covering the field itself, and the endpoint-cell exemption
    /// compares it against `fieldFloor` — which is read on a well-defined axis — so a hill 0.75 NM off in
    /// whichever direction the noise chose could exceed the field's own reading, escape the exemption, and
    /// report a perfectly reachable airport as BLOCKED. Nondeterministically, run to run, in the list a
    /// pilot reads after the engine quits.
    ///
    /// A single axis is not an approximation worth worrying about: over the ≤100 NM this sweep spans the
    /// great-circle course turns by a couple of degrees at most, which moves a 0.75 NM perpendicular
    /// offset by ~0.03 NM — far inside one ~1 NM terrain cell. Coincident endpoints (the aircraft over the
    /// field) have no meaningful axis at all, and 0 is as good as any: the two tracks then straddle the
    /// field north/south, which is what a vicinity reading should do anyway.
    static func sweepAxisDeg(from: Coord, to: Coord) -> Double {
        assert(corridorOffsetNm > 0, "corridor has width")
        assert(coincidentNm > 0, "coincidence threshold is a distance")
        return Geo.nmBetween(from, to) > coincidentNm ? Geo.bearing(from, to) : 0
    }

    /// Below this the two coordinates are the same place and no bearing between them means anything
    /// (1e-4 NM ≈ 0.6 ft — orders of magnitude under any GPS fix, and above great-circle round-off).
    static let coincidentNm = 1e-4

    private static func corridorMaxFt(center: Coord, axisDeg: Double,
                                      terrain: TerrainSampling) -> (maxFt: Double, sawHole: Bool)? {
        guard let mid = terrain.sampleElevationFt(at: center) else { return nil }
        assert(axisDeg.isFinite, "corridor axis is a real bearing")
        var worst = mid
        var hole = false
        for side in [-1.0, 1.0] {                            // bounded: exactly two lateral tracks
            let p = Geo.destination(from: center, bearingDeg: axisDeg + side * 90, distanceNm: corridorOffsetNm)
            if let e = terrain.sampleElevationFt(at: p) { worst = max(worst, e) } else { hole = true }
        }
        assert(worst >= mid, "corridor max can only raise the center sample")
        assert(worst.isFinite, "a sampled elevation is a real number")
        return (worst, hole)
    }

    // MARK: tier 3 — terrain around the field

    /// Max terrain rise above field elevation on rings around the airport — the "is this strip at
    /// the bottom of a box canyon" number. Nil when every ring sample is off-grid.
    static func vicinityRiseFt(around coord: Coord, fieldElevFt: Double,
                               terrain: TerrainSampling) -> Double? {
        guard terrain.isReady else { return nil }
        assert(vicinityBearings > 0 && vicinityBearings <= 16, "ring sampling bounded")
        var maxElev: Double?
        for ringNm in vicinityRingNm {                        // bounded: 2 rings × 8 bearings
            for k in 0..<vicinityBearings {
                let brg = Double(k) * (360.0 / Double(vicinityBearings))
                let p = Geo.destination(from: coord, bearingDeg: brg, distanceNm: ringNm)
                if let e = terrain.sampleElevationFt(at: p) { maxElev = max(maxElev ?? e, e) }
            }
        }
        return maxElev.map { max(0, $0 - fieldElevFt) }
    }

    // MARK: tiers 2/4/5 — the weighted score

    /// A stale report is not current weather: past `staleWxMinutes` the category ranks as unknown
    /// (the row still shows the aged report so the pilot can judge for themselves).
    static func effectiveCategory(_ wx: NRSTWeather?) -> Metar.Category {
        guard let wx else { return .unknown }
        if let age = wx.ageMinutes, age > staleWxMinutes { return .unknown }
        return wx.category
    }

    /// Weather tier ordering (lower ranks first). Unknown deliberately sits BETWEEN MVFR and IFR:
    /// most engine-out-relevant fields never report, and ranking silence below a known-IFR station
    /// would bury every small VFR strip under any towered field in fog.
    static func wxRank(_ c: Metar.Category) -> Int {
        switch c {
        case .vfr: return 0
        case .mvfr: return 1
        case .unknown: return 2
        case .ifr: return 3
        case .lifr: return 4
        }
    }

    private static func composite(riseFt: Double?, longest: Double?,
                                  paved: Bool, lit: Bool, airport: AirportData.Airport,
                                  marginFt: Double) -> Double {
        assert(wTerrain > wRunway && wRunway > wFacility,
               "tier weights must descend with the hierarchy")
        assert(abs(wTerrain + wRunway + wFacility + wMargin - 1.0) < 1e-9, "weights sum to 1")
        let terrainScore = riseFt.map {
            1 - clamp01(($0 - terrainRiseEasyFt) / (terrainRiseHostileFt - terrainRiseEasyFt))
        } ?? 0.5                                              // unknown vicinity = neutral
        let lengthScore = clamp01(((longest ?? 0) - minRunwayFt) / (fullRunwayFt - minRunwayFt))
        let runwayScore = clamp01(0.8 * lengthScore + (paved ? 0.15 : 0) + (lit ? 0.05 : 0))
        let facilityScore = facilities(airport)
        let marginScore = clamp01(marginFt / 4000)
        return wTerrain * terrainScore + wRunway * runwayScore
             + wFacility * facilityScore + wMargin * marginScore
    }

    /// Facilities tier. A Part-139 certificate means fire/rescue equipment ON the field — that
    /// dominates, scaled by ARFF index (A smallest … E largest). Otherwise build up from tower,
    /// fuel (people + services), and public use.
    static func facilities(_ a: AirportData.Airport) -> Double {
        if a.isCertificated {
            let index = a.far139.uppercased().last.map { c -> Double in
                switch c { case "A": return 0; case "B": return 1; case "C": return 2
                case "D": return 3; case "E": return 4; default: return 0 }
            } ?? 0
            return 0.6 + 0.08 * index                        // 0.60 … 0.92
        }
        var s = 0.0
        if a.isTowered { s += 0.35 }
        if a.hasFuel { s += 0.20 }
        if a.isPublicUse { s += 0.15 }
        return s
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}
