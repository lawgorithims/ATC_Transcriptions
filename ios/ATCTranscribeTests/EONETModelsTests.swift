import XCTest
@testable import ATCTranscribe

/// EONET event decode: tolerant parsing, [lon, lat] ordering, newest-geometry selection,
/// vertex/track/count caps, longitude wrapping, and the Codable round-trip the disk cache needs.
final class EONETModelsTests: XCTestCase {

    private let fixture = """
    { "title": "EONET Events", "events": [
      {"id":"EONET_FIRE","title":"Park Fire",
       "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Point","coordinates":[-120.5,40.1]},
                   {"date":"2026-06-02T00:00:00Z","type":"Point","coordinates":[-120.6,40.2]}]},
      {"id":"EONET_DUST","title":"Dust Plume",
       "geometry":[{"date":"2026-06-03T00:00:00Z","type":"Polygon",
                    "coordinates":[[[-106.0,32.0],[-105.0,32.0],[-105.0,33.0],[-106.0,33.0],[-106.0,32.0]]]}]},
      {"id":"","title":"No id",
       "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Point","coordinates":[-60.0,15.0]}]},
      {"id":"EONET_BADLAT","title":"Bad latitude",
       "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Point","coordinates":[-60.0,95.0]}]}
    ]}
    """.data(using: .utf8)!

    private let stormFixture = """
    { "events": [
      {"id":"EONET_STORM","title":"Hurricane Demo",
       "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Point","coordinates":[-60.0,15.0]},
                   {"date":"2026-06-02T00:00:00Z","type":"Point","coordinates":[-61.0,16.0]},
                   {"date":"2026-06-03T00:00:00Z","type":"Point","coordinates":[-62.0,17.0]}]}
    ]}
    """.data(using: .utf8)!

    func testDecodeFixtureTolerant() throws {
        let events = try XCTUnwrap(EONETEvent.decode(fixture, category: .wildfires))
        // The empty-id and the out-of-range-latitude events are dropped, never thrown.
        XCTAssertEqual(events.map(\.id), ["EONET_FIRE", "EONET_DUST"])

        let fire = events[0]
        XCTAssertEqual(fire.title, "Park Fire")
        XCTAssertEqual(fire.category, .wildfires)
        XCTAssertEqual(fire.point.lat, 40.2, accuracy: 1e-9)      // NEWEST geometry wins
        XCTAssertEqual(fire.point.lon, -120.6, accuracy: 1e-9)    // GeoJSON is [lon, lat]
        XCTAssertTrue(fire.polygon.isEmpty)
        XCTAssertTrue(fire.track.isEmpty)                          // fires never get a "track"
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: fire.updatedAt)
        XCTAssertEqual(comps.day, 2)                               // newest date, not the first

        let dust = events[1]
        XCTAssertEqual(dust.polygon.count, 5)
        XCTAssertEqual(dust.point.lat, 32.4, accuracy: 1e-9)       // ring centroid
        XCTAssertEqual(dust.point.lon, -105.6, accuracy: 1e-9)
        comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: dust.updatedAt)
        XCTAssertEqual(comps.day, 3)
    }

    func testStormKeepsTrackOtherCategoriesDoNot() throws {
        let storms = try XCTUnwrap(EONETEvent.decode(stormFixture, category: .severeStorms))
        XCTAssertEqual(storms.count, 1)
        XCTAssertEqual(storms[0].track.count, 3)                   // oldest → newest
        XCTAssertEqual(storms[0].track.first?.lat, 15.0)
        XCTAssertEqual(storms[0].track.last?.lat, 17.0)
        XCTAssertEqual(storms[0].point.lat, 17.0)                  // marker at the newest fix
        XCTAssertEqual(storms[0].point.lon, -62.0)

        let asFire = try XCTUnwrap(EONETEvent.decode(stormFixture, category: .wildfires))
        XCTAssertTrue(asFire[0].track.isEmpty)                     // dated points ≠ track for fires
    }

    func testLongitudeWrapsIntoRange() throws {
        let data = """
        {"events":[{"id":"X","title":"Dateline",
         "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Point","coordinates":[190.0,10.0]}]}]}
        """.data(using: .utf8)!
        let events = try XCTUnwrap(EONETEvent.decode(data, category: .severeStorms))
        XCTAssertEqual(events.first?.point.lon ?? 0, -170.0, accuracy: 1e-9)
        XCTAssertEqual(events.first?.point.lat ?? 0, 10.0, accuracy: 1e-9)
    }

    /// A polygon-only event whose ring straddles ±180 must get its marker ON the ring (near ±180),
    /// not at lon 0 on the far side of the globe (the naive-longitude-average bug).
    func testAntimeridianPolygonCentroid() throws {
        let data = """
        {"events":[{"id":"ASH","title":"Aleutian Ash",
         "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Polygon",
                      "coordinates":[[[179.0,51.0],[-179.0,51.0],[-179.0,52.0],[179.0,52.0],[179.0,51.0]]]}]}]}
        """.data(using: .utf8)!
        let events = try XCTUnwrap(EONETEvent.decode(data, category: .volcanoes))
        XCTAssertEqual(events.count, 1)
        // Latitude is the plain mean of the 5 ring vertices (the closing vertex repeats the first,
        // so 51,51,52,52,51 → 51.4) — the point here is the LONGITUDE handling.
        XCTAssertEqual(events[0].point.lat, 51.4, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(events[0].point.lon), 179.0)      // near the dateline, NOT ~0
    }

    func testPolygonVertexCapSubsamples() throws {
        var verts: [String] = []
        for i in 0..<1000 { verts.append("[\(Double(i) / 100.0),\(Double(i) / 200.0)]") }
        let data = """
        {"events":[{"id":"BIG","title":"Big Ring",
         "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Polygon",
                      "coordinates":[[\(verts.joined(separator: ","))]]}]}]}
        """.data(using: .utf8)!
        let events = try XCTUnwrap(EONETEvent.decode(data, category: .dustHaze))
        XCTAssertEqual(events.count, 1)
        XCTAssertLessThanOrEqual(events[0].polygon.count, EONETEvent.maxPolygonVertices)
        XCTAssertGreaterThanOrEqual(events[0].polygon.count, 3)
    }

    func testPerCategoryCap() throws {
        var items: [String] = []
        for i in 0..<120 {
            items.append("""
            {"id":"E\(i)","title":"E\(i)",
             "geometry":[{"date":"2026-06-01T00:00:00Z","type":"Point","coordinates":[-100.0,35.0]}]}
            """)
        }
        let data = "{\"events\":[\(items.joined(separator: ","))]}".data(using: .utf8)!
        XCTAssertEqual(try XCTUnwrap(EONETEvent.decode(data, category: .wildfires)).count,
                       EONETEvent.maxEventsPerCategory)
    }

    /// A structurally-invalid body (not an events envelope) returns nil so the SERVICE treats a
    /// 200-with-garbage as a failed poll — never an empty success that would clobber the cache.
    func testInvalidEnvelopeReturnsNil() {
        XCTAssertNil(EONETEvent.decode(Data("not json".utf8), category: .wildfires))
        XCTAssertNil(EONETEvent.decode(Data("[1,2,3]".utf8), category: .wildfires))
        XCTAssertNil(EONETEvent.decode(Data("{\"events\":{}}".utf8), category: .wildfires))
        XCTAssertNil(EONETEvent.decode(Data("<html>maintenance</html>".utf8), category: .wildfires))
        XCTAssertNil(EONETEvent.decode(Data(), category: .wildfires))
    }

    /// A genuine empty events list is VALID and decodes to [] (distinct from a garbage body → nil).
    func testValidEmptyEnvelopeReturnsEmpty() {
        XCTAssertEqual(EONETEvent.decode(Data("{\"events\":[]}".utf8), category: .wildfires), [])
    }

    func testCodableRoundTrip() throws {
        let events = EONETEvent.demoEvents()
        let data = try JSONEncoder().encode(events)
        let back = try JSONDecoder().decode([EONETEvent].self, from: data)
        XCTAssertEqual(back, events)
    }

    func testDemoEventsAreSane() {
        let events = EONETEvent.demoEvents()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.id)).count, 3)             // unique ids (the diff key)
        XCTAssertTrue(events.contains { !$0.polygon.isEmpty })     // exercises the polygon renderer
        XCTAssertTrue(events.contains { $0.track.count >= 2 })     // exercises the track renderer
    }
}
