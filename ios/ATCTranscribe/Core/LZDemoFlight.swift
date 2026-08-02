import Foundation
import MapKit

/// Picks somewhere the landability layer can actually answer, so a demonstration is of the feature
/// rather than of an empty map.
///
/// =============================================================================================
/// WHY "SOMEWHERE WITH DATA" IS NOT THE SAME AS "SOMEWHERE IN A PACK"
/// =============================================================================================
/// A pack's bounding rectangle is a rectangle; the data inside it is not. Cells are cut to the
/// analysis grid and a 1-degree cell fills only ~82% of its own bounding box, so a point picked
/// uniformly from the rect lands outside the tiles often enough to matter. Worse, a point can be
/// inside the tiles and still score nothing — water, or a hole in coverage.
///
/// So this does not trust geometry. It picks a candidate, ASKS THE COMPOSITOR what it would paint
/// there, and keeps the point only if it gets a real answer. That is the same sampler the heatmap
/// and the tap card use, so "there is data here" means exactly what it means everywhere else.
///
/// The whole point of the exercise is showing the layer working. A demo that opens on blank ground
/// is indistinguishable from a demo of a broken layer — which is the failure this codebase has hit
/// more than any other.
enum LZDemoFlight {

    /// How many points to try before giving up on a pack. Bounded (rule 2).
    static let maxAttempts = 200
    /// Height above the ground to park at, in feet. Low enough to be a plausible light-aircraft
    /// cruise, high enough that the glide footprint has something to draw.
    static let minHeightAGL = 4_500.0
    static let maxHeightAGL = 11_000.0
    /// Keep the drop away from the very edge of a pack, or half the footprint falls off the data and
    /// the demonstration shows a semicircle.
    static let edgeInsetFraction = 0.18

    struct Drop: Equatable {
        let coord: Coord
        let altitudeFtMSL: Double
        let groundElevationFt: Double
        /// The pack it came from, for the caption — a demo should be able to say where it is.
        let packName: String
        var heightAGL: Double { altitudeFtMSL - groundElevationFt }
    }

    /// Choose a spot inside one of the mounted packs that the layer can genuinely score.
    ///
    /// `sample` is `LZRiskController.sampler` in production and a closure in tests. `elevation` is
    /// the terrain grid; a nil elevation is not fatal — it only means the height is measured from
    /// sea level, which is still a usable demonstration.
    ///
    /// Returns nil when no pack is mounted or nothing scored after `maxAttempts` — a real answer,
    /// and the caller must show it as one rather than dropping the aeroplane somewhere arbitrary.
    static func pick(mounted: [LZPackStore.Mounted],
                     sample: (Coord) -> LZSampleInfo?,
                     elevationFt: (Coord) -> Double?,
                     rng: inout RandomNumberGenerator) -> Drop? {
        guard !mounted.isEmpty else { return nil }
        for _ in 0..<maxAttempts {                                   // bounded (rule 2)
            guard let m = mounted.randomElement(using: &rng) else { return nil }
            guard let c = randomPoint(in: m.rect, using: &rng) else { continue }
            // THE CHECK THAT MATTERS: does the layer have an answer here?
            guard let info = sample(c), !info.vetoed || info.score > 0 else { continue }
            _ = info
            let groundFt = elevationFt(c) ?? 0
            let agl = Double.random(in: minHeightAGL...maxHeightAGL, using: &rng)
            return Drop(coord: c, altitudeFtMSL: (groundFt + agl).rounded(),
                        groundElevationFt: groundFt.rounded(),
                        packName: m.reader.packID)
        }
        return nil
    }

    /// A uniformly random point inside `rect`, inset from its edges, in lat/lon.
    static func randomPoint(in rect: MKMapRect, using rng: inout RandomNumberGenerator) -> Coord? {
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        let insetX = rect.size.width * edgeInsetFraction
        let insetY = rect.size.height * edgeInsetFraction
        let x = Double.random(in: (rect.minX + insetX)...(rect.maxX - insetX), using: &rng)
        let y = Double.random(in: (rect.minY + insetY)...(rect.maxY - insetY), using: &rng)
        let p = MKMapPoint(x: x, y: y).coordinate
        guard p.latitude.isFinite, p.longitude.isFinite,
              abs(p.latitude) <= 90, abs(p.longitude) <= 180 else { return nil }
        return Coord(lat: p.latitude, lon: p.longitude)
    }
}
