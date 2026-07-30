import Foundation

/// Local magnetic variation (declination), looked up from the FAA-PUBLISHED station values bundled
/// with the app — never computed from a geomagnetic model we would have to transcribe by hand.
///
/// Why it exists: coded procedure courses (hold inbound legs, approach courses) are MAGNETIC, while
/// anything derived from coordinates — a great-circle arrival track, the map's true-north canvas — is
/// TRUE. Comparing the two without the local variation is wrong by the declination itself: up to
/// ~17° across CONUS and more in Alaska. For holding-entry selection that error can cross a sector
/// boundary and name the wrong entry, which is why `HoldingPattern.entry(arrivingFrom:)` refuses to
/// guess and this type supplies the number.
///
/// Source: `navaid_meta.json` (published signed variation, east positive / west negative — BOS −15.2,
/// SFO +14.4, DEN +9.3). ⚠️ That file and `nav_coords.json` MUST come from one OurAirports snapshot:
/// the uniqueness gate below asks whether an ident is unique in `nav_coords` and then reads the value
/// from `navaid_meta`, so a half-rebuild lets an apparently-unique ident carry a foreign twin's
/// number. Enforced at build time by `Tools/navdb.py check_nav_pairing` (both builders refuse to
/// write a mismatched pair), on the shipped tables by `NavDataPairingTests`, and structurally by
/// `build_nav_meta.py` withholding `mv` from any ident its snapshot saw more than once.
/// The MEDIAN of the nearest few stations stands in for
/// the point of interest (see `minStations`/`votingStations` for why a single station is never
/// trusted); stations are dense enough over the procedure-bearing US that the nearest handful sit
/// within a few tens of NM, where variation differs by well under the ±5° slack the AIM itself allows
/// at entry-sector boundaries. Too few stations in range → nil, and callers must treat nil as
/// "unknown", not zero.
///
/// Known limitation: these are STATION declinations, which the FAA calibrates on multi-year epochs —
/// in Alaska a station's value can lag the true present-day variation by several degrees. That skew is
/// inherent to the published data (VOR radials are referenced to the same epochs) and is far smaller
/// than the errors this type exists to prevent (a defaulted 0, or a foreign twin's value).
enum MagneticVariation {

    /// Beyond this, a station's variation no longer speaks for the point (and we are likely over
    /// ocean, where no US procedure holds anyway).
    static let maxDistanceNm: Double = 150

    /// Cache key: coordinate rounded to ~6 NM. Variation changes on the order of 1° per 40–60 NM, so
    /// one lookup serves its neighbourhood; bounded so a long flight cannot grow it without limit.
    private static var cache: [Int64: Double?] = [:]
    private static let cacheCap = 512
    private static let lock = NSLock()

    /// The published variation nearest `coord` (signed, east positive), or nil when no station within
    /// `maxDistanceNm` publishes one. Thread-safe; the underlying scan is bounded.
    static func at(_ coord: Coord) -> Double? {
        let key = cacheKey(coord)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let value = lookup(coord)

        lock.lock()
        if cache.count >= cacheCap { cache.removeAll(keepingCapacity: true) }   // simple bounded reset
        cache[key] = value
        lock.unlock()
        return value
    }

    /// Test seam: clear the cache so fixtures cannot leak between tests.
    static func resetForTests() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// Minimum agreeing stations for a result. The variation table is keyed by BARE IDENT over
    /// worldwide data (first candidate wins), while stations are resolved by COORDINATE — so a short
    /// ident that also exists abroad (~445 CONUS stations, mostly 2-letter compass locators) can carry
    /// a FOREIGN twin's variation, wrong by tens of degrees yet inside the ±40° clamp. No single
    /// station is trusted: the MEDIAN of the nearest agreeing stations is returned, which one poisoned
    /// ident cannot steer, and fewer than this many values is "unknown", not a guess.
    static let minStations = 3
    /// How many nearest stations vote. Odd, so the median is a real published value.
    static let votingStations = 5

    private static func lookup(_ coord: Coord) -> Double? {
        // ±2.5° of latitude ≈ 150 NM; widen the longitude window by cos(lat) so the box stays ~square.
        let dLat = maxDistanceNm / 60.0
        let dLon = dLat / max(cos(coord.lat * .pi / 180), 0.2)
        let box = BBox(minLat: coord.lat - dLat, minLon: coord.lon - dLon,
                       maxLat: coord.lat + dLat, maxLon: coord.lon + dLon)
        var candidates: [(nm: Double, mv: Double)] = []
        var scanned = 0
        for np in NavDatabase.nearby(box, types: [1], limit: 200) {            // kind 1 = navaid
            scanned += 1
            assert(scanned <= 200, "variation scan bound")
            // ⚠️ ONLY globally-unique idents may vote. The variation table is keyed by bare ident over
            // worldwide data (first candidate wins), so a duplicated ident's value may belong to a
            // foreign twin — near Boston, 8 of the 11 nearest stations were poisoned that way (LI, BO,
            // LQ… reading −2° where the true value is −15°), enough to steer even a median. A
            // single-candidate ident is unambiguous by construction.
            guard NavDatabase.candidates(np.ident).count == 1 else { continue }
            guard let mv = NavMeta.navaid(np.ident)?.magVar else { continue }
            // A mis-keyed record with an absurd value must not steer entry selection: real published
            // variation over the US (including Alaska) stays well inside ±40°.
            guard abs(mv) <= 40 else { continue }
            let d = HoldingPattern.distanceNm(coord, np.coord)
            guard d <= maxDistanceNm else { continue }
            candidates.append((d, mv))
        }
        return consensus(of: candidates)
    }

    /// The robust aggregate over (distance, value) candidates: the MEDIAN of the nearest
    /// `votingStations` values, or nil below `minStations`. Pure and internal so the poisoned-station
    /// case is unit-tested directly — the scenario that motivated it (a foreign twin's value on the
    /// single nearest station) is not reproducible through the bundled data from a test.
    static func consensus(of candidates: [(nm: Double, mv: Double)]) -> Double? {
        guard candidates.count >= minStations else { return nil }
        let voters = candidates.sorted { $0.nm < $1.nm }.prefix(votingStations).map(\.mv).sorted()
        return voters[voters.count / 2]                                        // median of the nearest
    }

    private static func cacheKey(_ c: Coord) -> Int64 {
        let latQ = Int64((c.lat * 10).rounded())          // 0.1° ≈ 6 NM
        let lonQ = Int64((c.lon * 10).rounded())
        return latQ &* 4_000 &+ lonQ                      // |lonQ| < 1800 < 4000 → collision-free
    }
}
