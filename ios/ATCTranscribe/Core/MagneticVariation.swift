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
/// Source: `navaid_meta.json` (6,018 navaids with a published signed variation, east positive / west
/// negative — BOS −15.2, SFO +14.4, DEN +9.3). The nearest station's value stands in for the point of
/// interest; stations are dense enough over the procedure-bearing US that the nearest one is normally
/// within a few tens of NM, where variation differs by well under the ±5° slack the AIM itself allows
/// at entry-sector boundaries. No station within `maxDistanceNm` → nil, and callers must treat nil as
/// "unknown", not zero.
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

    private static func lookup(_ coord: Coord) -> Double? {
        // ±2.5° of latitude ≈ 150 NM; widen the longitude window by cos(lat) so the box stays ~square.
        let dLat = maxDistanceNm / 60.0
        let dLon = dLat / max(cos(coord.lat * .pi / 180), 0.2)
        let box = BBox(minLat: coord.lat - dLat, minLon: coord.lon - dLon,
                       maxLat: coord.lat + dLat, maxLon: coord.lon + dLon)
        var best: (nm: Double, mv: Double)?
        var scanned = 0
        for np in NavDatabase.nearby(box, types: [1], limit: 200) {            // kind 1 = navaid
            scanned += 1
            assert(scanned <= 200, "variation scan bound")
            guard let mv = NavMeta.navaid(np.ident)?.magVar else { continue }
            // A mis-keyed record with an absurd value must not steer entry selection: real published
            // variation over the US (including Alaska) stays well inside ±40°.
            guard abs(mv) <= 40 else { continue }
            let d = HoldingPattern.distanceNm(coord, np.coord)
            guard d <= maxDistanceNm else { continue }
            if best == nil || d < best!.nm { best = (d, mv) }
        }
        return best?.mv
    }

    private static func cacheKey(_ c: Coord) -> Int64 {
        let latQ = Int64((c.lat * 10).rounded())          // 0.1° ≈ 6 NM
        let lonQ = Int64((c.lon * 10).rounded())
        return latQ &* 4_000 &+ lonQ                      // |lonQ| < 1800 < 4000 → collision-free
    }
}
