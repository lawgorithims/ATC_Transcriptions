import XCTest
@testable import ATCTranscribe

/// Wind-field sampling: bilinear interpolation against an independent reference, the out-of-grid nil
/// contract the particle renderer depends on, and the U/V → knots/direction conversions a pilot reads.
final class WindFieldTests: XCTestCase {

    private struct Expected: Decodable {
        struct Bilinear: Decodable { let name: String; let lat, lon, u, v, kt, dirFrom: Double }
        let bilinear: [Bilinear]
    }

    /// A 3×2 grid with a known linear gradient, so interpolation is checkable by hand:
    /// u = column index, v = 10 × row index, over lon −100…−98 (step 1) and lat 30…31 (step 1).
    private func ramp() -> WindField {
        WindField(level: .mb850, minLat: 30, minLon: -100, dLat: 1, dLon: 1, ni: 3, nj: 2,
                  u: [0, 1, 2, 0, 1, 2], v: [0, 0, 0, 10, 10, 10])
    }

    func testBilinearInterpolationOnAKnownRamp() throws {
        let f = ramp()
        let corner = try XCTUnwrap(f.sample(lat: 30, lon: -100))
        XCTAssertEqual(corner.x, 0, accuracy: 1e-5)
        XCTAssertEqual(corner.y, 0, accuracy: 1e-5)
        let mid = try XCTUnwrap(f.sample(lat: 30.5, lon: -99.5))
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-5, "halfway along the u gradient")
        XCTAssertEqual(mid.y, 5.0, accuracy: 1e-5, "halfway along the v gradient")
        let far = try XCTUnwrap(f.sample(lat: 31, lon: -98))
        XCTAssertEqual(far.x, 2, accuracy: 1e-5)
        XCTAssertEqual(far.y, 10, accuracy: 1e-5)
    }

    /// Out-of-grid must be nil rather than a clamped edge value: the renderer respawns a particle on nil,
    /// and a clamped sample would instead park particles along the data boundary in a visible fence.
    func testOutsideTheGridIsNil() {
        let f = ramp()
        XCTAssertNil(f.sample(lat: 29.99, lon: -99))
        XCTAssertNil(f.sample(lat: 31.01, lon: -99))
        XCTAssertNil(f.sample(lat: 30.5, lon: -100.01))
        XCTAssertNil(f.sample(lat: 30.5, lon: -97.99))
        XCTAssertNil(f.speedKt(lat: 0, lon: 0))
        XCTAssertNil(f.directionFromDeg(lat: 0, lon: 0))
    }

    func testBboxDescribesTheGridExtent() {
        let b = ramp().bbox
        XCTAssertEqual(b.minLat, 30, accuracy: 1e-9)
        XCTAssertEqual(b.maxLat, 31, accuracy: 1e-9)
        XCTAssertEqual(b.minLon, -100, accuracy: 1e-9)
        XCTAssertEqual(b.maxLon, -98, accuracy: 1e-9)
    }

    /// Meteorological direction is the bearing the wind blows FROM — the only convention in a cockpit.
    /// A pure eastward component (u > 0, v = 0) is a WESTERLY: 270°.
    func testSpeedAndMeteorologicalDirection() throws {
        let f = WindField(level: .mb500, minLat: 0, minLon: 0, dLat: 1, dLon: 1, ni: 2, nj: 2,
                          u: [10, 10, 10, 10], v: [0, 0, 0, 0])
        XCTAssertEqual(try XCTUnwrap(f.speedKt(lat: 0.5, lon: 0.5)), 19.438, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(f.directionFromDeg(lat: 0.5, lon: 0.5)), 270, accuracy: 0.01)

        // Blowing southward = FROM the north. Reported in 0…<360, so due north is 0 (never a signed zero,
        // which would format as "-0" in a readout).
        let northerly = WindField(level: .mb500, minLat: 0, minLon: 0, dLat: 1, dLon: 1, ni: 2, nj: 2,
                                  u: [0, 0, 0, 0], v: [-5, -5, -5, -5])
        let dir = try XCTUnwrap(northerly.directionFromDeg(lat: 0.5, lon: 0.5))
        XCTAssertEqual(dir, 0, accuracy: 0.01)
        XCTAssertFalse(dir.sign == .minus, "a signed zero must not escape the sampler")

        let southerly = WindField(level: .mb500, minLat: 0, minLon: 0, dLat: 1, dLon: 1, ni: 2, nj: 2,
                                  u: [0, 0, 0, 0], v: [5, 5, 5, 5])       // blowing northward = FROM the south
        XCTAssertEqual(try XCTUnwrap(southerly.directionFromDeg(lat: 0.5, lon: 0.5)), 180, accuracy: 0.01)
    }

    /// The same bilinear sampler, run over the real 850 hPa fixture and checked against the reference
    /// decoder's interpolation at three airports.
    func testBilinearMatchesReferenceOnRealData() throws {
        let bundle = Bundle(for: Self.self)
        let gribURL = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"))
        let jsonURL = try XCTUnwrap(bundle.url(forResource: "wind_fixture_expected", withExtension: "json"))
        let expected = try JSONDecoder().decode(Expected.self, from: try Data(contentsOf: jsonURL))
        let messages = Grib2Decoder.messages(from: try Data(contentsOf: gribURL))
        let box = WindBBox(minLat: 20, minLon: -130, maxLat: 55, maxLon: -60)
        let set = try XCTUnwrap(WindFieldSet.build(from: messages, bbox: box, fetchedAt: Date()))
        let field = try XCTUnwrap(set.field(.mb850))
        XCTAssertEqual(set.fields.count, 1, "the fixture carries one level")
        XCTAssertEqual(set.forecastHours, 9)
        XCTAssertEqual(set.cycleLabel, "GFS 06z +9h")
        XCTAssertEqual(set.validTime.timeIntervalSince(set.cycle), 9 * 3600, accuracy: 1)

        for b in expected.bilinear {
            let w = try XCTUnwrap(field.sample(lat: b.lat, lon: b.lon), b.name)
            XCTAssertEqual(Double(w.x), b.u, accuracy: 2e-3, "\(b.name) u")
            XCTAssertEqual(Double(w.y), b.v, accuracy: 2e-3, "\(b.name) v")
            XCTAssertEqual(Double(try XCTUnwrap(field.speedKt(lat: b.lat, lon: b.lon))), b.kt,
                           accuracy: 5e-3, "\(b.name) kt")
            XCTAssertEqual(Double(try XCTUnwrap(field.directionFromDeg(lat: b.lat, lon: b.lon))), b.dirFrom,
                           accuracy: 0.05, "\(b.name) direction")

            // The same real bytes through the altitude sampler the clearance rule reads. This fixture
            // carries ONE level, so the column has nothing to interpolate between and every altitude
            // must come back as that level's own wind — which is the check that the two paths cannot
            // drift apart on units (m/s vs kt), on the surface-level exclusion, or on the vector mean.
            for altitude in [4_781.0, 20_000, 45_000] {
                let w = try XCTUnwrap(set.windAt(lat: b.lat, lon: b.lon, altitudeFtMSL: altitude),
                                      "\(b.name) at \(altitude) ft")
                XCTAssertEqual(w.kts, b.kt, accuracy: 5e-3, "\(b.name) kt at \(altitude) ft")
                XCTAssertEqual(w.fromDeg, b.dirFrom, accuracy: 0.05, "\(b.name) dir at \(altitude) ft")
            }
        }
    }

    /// An unpaired component must not produce a half-built field — one level with U but no V is dropped.
    func testUnpairedComponentIsDropped() throws {
        let bundle = Bundle(for: Self.self)
        let gribURL = try XCTUnwrap(bundle.url(forResource: "wind_fixture", withExtension: "grib2"))
        let messages = Grib2Decoder.messages(from: try Data(contentsOf: gribURL))
        let uOnly = messages.filter { $0.paramNumber == 2 }
        XCTAssertEqual(uOnly.count, 1)
        let box = WindBBox(minLat: 20, minLon: -130, maxLat: 55, maxLon: -60)
        XCTAssertNil(WindFieldSet.build(from: uOnly, bbox: box, fetchedAt: Date()),
                     "a U component with no V is not a wind field")
        XCTAssertNil(WindFieldSet.build(from: [], bbox: box, fetchedAt: Date()))
    }

    func testLevelIndexClampsInsteadOfTrapping() {
        XCTAssertEqual(WindLevel.at(index: -5), .surface)
        XCTAssertEqual(WindLevel.at(index: 0), .surface)
        XCTAssertEqual(WindLevel.at(index: 9), .mb200)
        XCTAssertEqual(WindLevel.at(index: 99), .mb200, "a future build's index must degrade, not crash")
        XCTAssertEqual(WindLevel.allCases.count, 10)
        XCTAssertEqual(WindLevel.mb850.shortLabel, "5k")
        XCTAssertEqual(WindLevel.surface.pressureLabel, "10 m AGL")
        XCTAssertEqual(WindLevel.mb200.pressureLabel, "200 hPa")
        XCTAssertNil(WindLevel.from(levelType: 100, levelValue: 12_345))
    }

    // MARK: The wind at one altitude — what the storm alert's overflight clearance rule reads

    /// A two-level column with a known gradient: 700 hPa (9,882 ft) at 20 kt and 500 hPa (18,289 ft) at
    /// 60 kt, both westerly, over one grid cell. Everything between those heights is checkable by hand.
    private func column(_ fields: [WindField]? = nil) -> WindFieldSet {
        let at = Date(timeIntervalSince1970: 1_793_721_600)
        return WindFieldSet(fields: fields ?? [level(.mb700, kt: 20), level(.mb500, kt: 60)],
                            bbox: WindBBox(minLat: 30, minLon: -100, maxLat: 31, maxLon: -99),
                            cycle: at.addingTimeInterval(-6 * 3600), forecastHours: 6,
                            validTime: at, fetchedAt: at)
    }

    /// One level, uniform over the cell, blowing eastward — so `u > 0` and the reported wind is a westerly.
    private func level(_ l: WindLevel, kt: Double) -> WindField {
        let mps = Float(kt) / WindField.mpsToKt
        return WindField(level: l, minLat: 30, minLon: -100, dLat: 1, dLon: 1, ni: 2, nj: 2,
                         u: [mps, mps, mps, mps], v: [0, 0, 0, 0])
    }

    func testTheWindAtAnAltitudeComesFromTheLevelsThatBracketIt() throws {
        let set = column()
        let low = try XCTUnwrap(set.windAt(lat: 30.5, lon: -99.5, altitudeFtMSL: 9_882))
        XCTAssertEqual(low.kts, 20, accuracy: 0.05, "on a level, that level's wind")
        XCTAssertEqual(low.fromDeg, 270, accuracy: 0.05, "eastward flow is a westerly")
        let mid = try XCTUnwrap(set.windAt(lat: 30.5, lon: -99.5, altitudeFtMSL: (9_882 + 18_289) / 2))
        XCTAssertEqual(mid.kts, 40, accuracy: 0.1, "halfway up the column, halfway along the gradient")
    }

    /// Outside the levels it clamps rather than extrapolating. A linear run-out from two levels would
    /// reach 150 kt somewhere over FL450 on this column, and the clearance rule would then ask for 15,000
    /// ft of air on the strength of arithmetic rather than data.
    func testAboveAndBelowTheColumnTheWindIsClampedNotExtrapolated() throws {
        let set = column()
        XCTAssertEqual(try XCTUnwrap(set.windAt(lat: 30.5, lon: -99.5, altitudeFtMSL: 45_000)).kts,
                       60, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(set.windAt(lat: 30.5, lon: -99.5, altitudeFtMSL: 3_000)).kts,
                       20, accuracy: 0.05)
    }

    /// ⚠️ OFF THE GRID IS nil, NEVER CALM. The clearance rule reads nil as "fall back to the 5,000 ft
    /// floor" and a zero as "the top is in still air" — which is the same number today and a dangerously
    /// different one the moment the floor is raised.
    func testOffTheGridThereIsNoWindAtAll() {
        XCTAssertNil(column().windAt(lat: 45, lon: -99.5, altitudeFtMSL: 20_000))
        XCTAssertNil(column().windAt(lat: 30.5, lon: -140, altitudeFtMSL: 20_000))
        XCTAssertNil(column().windAt(lat: 30.5, lon: -99.5, altitudeFtMSL: .nan))
    }

    /// The surface level is excluded from the column on purpose: it sits 10 m above a ground elevation
    /// this sampler has no business knowing, and no convective top is within reach of it. A set holding
    /// nothing else therefore has no answer, rather than answering with a 10 m wind.
    func testTheSurfaceLevelIsNotPartOfTheColumn() {
        XCTAssertNil(column([level(.surface, kt: 25)]).windAt(lat: 30.5, lon: -99.5,
                                                              altitudeFtMSL: 20_000))
        XCTAssertNil(column([]).windAt(lat: 30.5, lon: -99.5, altitudeFtMSL: 20_000))
    }

    func testBboxContainment() {
        let outer = WindBBox(minLat: 20, minLon: -130, maxLat: 55, maxLon: -60)
        let inner = WindBBox(minLat: 30, minLon: -100, maxLat: 40, maxLon: -90)
        XCTAssertTrue(outer.contains(inner))
        XCTAssertFalse(inner.contains(outer))
        XCTAssertTrue(outer.contains(lat: 35, lon: -95))
        XCTAssertFalse(outer.contains(lat: 5, lon: -95))
        XCTAssertEqual(outer.latSpan, 35, accuracy: 1e-9)
        XCTAssertEqual(outer.lonSpan, 70, accuracy: 1e-9)
    }
}
