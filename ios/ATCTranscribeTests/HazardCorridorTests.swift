import XCTest
@testable import ATCTranscribe

/// Corridor / vicinity math: point-to-segment projection (perpendicular, clamped, zero-length),
/// the 25 NM corridor boundary, polygon containment, storm tracks, the 50 NM ownship vicinity,
/// route-vs-vicinity dedup, and the hit cap.
final class HazardCorridorTests: XCTestCase {

    /// An E–W route along 40°N: (40, −80) → (40, −76).
    private let route = [Coord(lat: 40, lon: -80), Coord(lat: 40, lon: -76)]

    private func event(_ id: String, at point: Coord, category: EONETCategory = .wildfires,
                       polygon: [Coord] = [], track: [Coord] = []) -> EONETEvent {
        EONETEvent(id: id, title: id, category: category, updatedAt: Date(),
                   point: point, polygon: polygon, track: track)
    }

    // MARK: point-to-segment

    func testPerpendicularMidSegment() {
        // 0.5° of latitude off an E–W segment = 30 NM, exactly, under the flat projection.
        let d = HazardCorridor.distanceNm(from: Coord(lat: 40.5, lon: -78),
                                          toSegment: route[0], route[1])
        XCTAssertEqual(d, 30, accuracy: 0.05)
    }

    func testClampsBeyondEndpoints() {
        // A point past the east end measures to the endpoint, not the infinite line.
        let p = Coord(lat: 40, lon: -75)
        let d = HazardCorridor.distanceNm(from: p, toSegment: route[0], route[1])
        XCTAssertEqual(d, Geo.nmBetween(p, route[1]), accuracy: 0.5)
    }

    func testZeroLengthSegmentDegradesToPointDistance() {
        let a = Coord(lat: 40, lon: -80)
        let d = HazardCorridor.distanceNm(from: Coord(lat: 41, lon: -80), toSegment: a, a)
        XCTAssertEqual(d, 60, accuracy: 0.1)
    }

    func testAntimeridianSegment() {
        // A short segment straddling ±180: a point 30 NM north must not measure ~21,000 NM.
        let a = Coord(lat: 0, lon: 179.8), b = Coord(lat: 0, lon: -179.8)
        let d = HazardCorridor.distanceNm(from: Coord(lat: 0.5, lon: 180.0), toSegment: a, b)
        XCTAssertEqual(d, 30, accuracy: 0.5)
    }

    // MARK: corridor boundary (25 NM)

    func testCorridorBoundary24In26Out() {
        let inEvent = event("IN", at: Coord(lat: 40.4, lon: -78))        // 24 NM
        let outEvent = event("OUT", at: Coord(lat: 40.4334, lon: -78))   // ~26 NM
        let alert = HazardCorridor.alert(events: [inEvent, outEvent], route: route, ownship: nil)
        XCTAssertEqual(alert.routeHits.map(\.eventID), ["IN"])
        XCTAssertEqual(alert.routeHits[0].distanceNm, 24, accuracy: 0.2)
        XCTAssertTrue(alert.vicinityHits.isEmpty)                        // no ownship given
    }

    func testPolygonContainingRouteVertexIsDistanceZero() {
        let ring = [Coord(lat: 39.5, lon: -80.5), Coord(lat: 40.5, lon: -80.5),
                    Coord(lat: 40.5, lon: -79.5), Coord(lat: 39.5, lon: -79.5)]
        // Marker centroid is inside the ring but the ring CONTAINS the route's west endpoint.
        let dust = event("DUST", at: Coord(lat: 40, lon: -80), category: .dustHaze, polygon: ring)
        let alert = HazardCorridor.alert(events: [dust], route: route, ownship: nil)
        XCTAssertEqual(alert.routeHits.first?.distanceNm, 0)
    }

    func testStormTrackPointInsideCorridorHits() {
        // The storm's newest fix is far south, but one track point passes 12 NM off the route.
        let storm = event("STORM", at: Coord(lat: 35, lon: -78), category: .severeStorms,
                          track: [Coord(lat: 34, lon: -78), Coord(lat: 40.2, lon: -78),
                                  Coord(lat: 35, lon: -78)])
        let alert = HazardCorridor.alert(events: [storm], route: route, ownship: nil)
        XCTAssertEqual(alert.routeHits.map(\.eventID), ["STORM"])
        XCTAssertEqual(alert.routeHits[0].distanceNm, 12, accuracy: 0.2)
    }

    // MARK: vicinity (50 NM of ownship)

    func testVicinityBoundary49In51Out() {
        let own = Coord(lat: 30, lon: -100)
        let near = event("NEAR", at: Coord(lat: 30 + 49.0 / 60.0, lon: -100))
        let far = event("FAR", at: Coord(lat: 30 + 51.0 / 60.0, lon: -100))
        let alert = HazardCorridor.alert(events: [near, far], route: [], ownship: own)
        XCTAssertEqual(alert.vicinityHits.map(\.eventID), ["NEAR"])
        XCTAssertTrue(alert.routeHits.isEmpty)                           // no route given
    }

    func testRouteHitNeverRepeatsAsVicinityHit() {
        // Ownship sits on the route; the event is 24 NM from both → route hit only.
        let ev = event("BOTH", at: Coord(lat: 40.4, lon: -78))
        let alert = HazardCorridor.alert(events: [ev], route: route,
                                         ownship: Coord(lat: 40, lon: -78))
        XCTAssertEqual(alert.routeHits.map(\.eventID), ["BOTH"])
        XCTAssertTrue(alert.vicinityHits.isEmpty)
    }

    func testOwnshipInsidePolygonIsDistanceZero() {
        let ring = [Coord(lat: 29, lon: -101), Coord(lat: 31, lon: -101),
                    Coord(lat: 31, lon: -99), Coord(lat: 29, lon: -99)]
        let dust = event("DUST", at: Coord(lat: 30, lon: -100), category: .dustHaze, polygon: ring)
        let alert = HazardCorridor.alert(events: [dust], route: [], ownship: Coord(lat: 30, lon: -100))
        XCTAssertEqual(alert.vicinityHits.first?.distanceNm, 0)
    }

    // MARK: shape of the result

    func testHitsSortedNearestFirstAndCapped() {
        var events: [EONETEvent] = []
        for i in 0..<12 {                                    // 12 events, 1…12 NM off the route
            let d = Double(i + 1) / 60.0
            events.append(event("E\(i)", at: Coord(lat: 40 + d, lon: -78)))
        }
        events.shuffle()
        let alert = HazardCorridor.alert(events: events, route: route, ownship: nil)
        XCTAssertEqual(alert.routeHits.count, HazardCorridor.maxHits)
        XCTAssertEqual(alert.routeHits.first?.eventID, "E0")             // nearest first
        let dists = alert.routeHits.map(\.distanceNm)
        XCTAssertEqual(dists, dists.sorted())
    }

    func testEmptyInputs() {
        XCTAssertTrue(HazardCorridor.alert(events: [], route: route, ownship: nil).isEmpty)
        XCTAssertTrue(HazardCorridor.alert(events: [event("X", at: Coord(lat: 0, lon: 0))],
                                           route: [], ownship: nil).isEmpty)
    }
}
