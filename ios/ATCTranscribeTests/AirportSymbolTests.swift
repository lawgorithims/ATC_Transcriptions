import XCTest
@testable import ATCTranscribe

/// The FAA sectional airport-symbol rules (Aeronautical Chart Users' Guide, "Airports").
final class AirportSymbolTests: XCTestCase {

    private func rw(_ bearing: Double, _ len: Int) -> AirportSymbol.Runway {
        AirportSymbol.Runway(bearingDeg: bearing, lengthFt: len)
    }

    // MARK: tower colour — the single most-read attribute

    func testToweredDrivesTheBlueSymbolAndNonToweredMagenta() {
        let towered = AirportSymbol.spec(attributes: .init(hasTower: true, hardSurface: true),
                                         runways: [rw(35, 7864)], category: nil)
        let non = AirportSymbol.spec(attributes: .init(hasTower: false, hardSurface: true),
                                     runways: [rw(35, 5000)], category: nil)
        XCTAssertTrue(towered.towered, "a control tower is the blue symbol")
        XCTAssertFalse(non.towered, "no tower is the magenta symbol")
    }

    /// Unknown must not be rendered as a negative — but it also must not claim a tower.
    func testUnknownTowerIsNotDrawnAsTowered() {
        let s = AirportSymbol.spec(attributes: .init(hardSurface: true), runways: [rw(9, 4000)], category: nil)
        XCTAssertFalse(s.towered)
    }

    // MARK: shape — the runway length / surface rules

    func testHardRunwayBetween1500And8069IsAFilledCircleWithRunways() {
        let s = AirportSymbol.spec(attributes: .init(hasTower: false, hardSurface: true),
                                   runways: [rw(90, 5000)], category: nil)
        XCTAssertEqual(s.shape, .filledCircleWithRunways)
    }

    func testHardRunwayOver8069IsDrawnAsRunwaysWithoutACircle() {
        let s = AirportSymbol.spec(attributes: .init(hasTower: true, hardSurface: true),
                                   runways: [rw(35, 10_006)], category: nil)
        XCTAssertEqual(s.shape, .runwaysOnly, "a runway longer than 8,069 ft drops the circle")
    }

    func testSoftSurfacedFieldIsASimpleOpenCircle() {
        let s = AirportSymbol.spec(attributes: .init(hasTower: false, hardSurface: false),
                                   runways: [rw(18, 3000)], category: nil)
        XCTAssertEqual(s.shape, .openCircle)
    }

    func testShortHardRunwayUnder1500IsAlsoAnOpenCircle() {
        let s = AirportSymbol.spec(attributes: .init(hasTower: false, hardSurface: true),
                                   runways: [rw(18, 1200)], category: nil)
        XCTAssertEqual(s.shape, .openCircle)
    }

    func testMultipleRunwayConfigurationIsDepictedSeparately() {
        let s = AirportSymbol.spec(attributes: .init(hasTower: true, hardSurface: true),
                                   runways: [rw(35, 7000), rw(90, 6000), rw(140, 5000)], category: nil)
        XCTAssertEqual(s.shape, .runwaysOnly, "three or more runways get the separate depiction")
    }

    // MARK: runway axes — the "simplified runway layout" the symbol shows

    /// A runway and its reciprocal are ONE strip of pavement, so they must collapse to one line.
    func testReciprocalRunwaysCollapseToASingleAxis() {
        let axes = AirportSymbol.runwayAxes([rw(40, 7000), rw(220, 7000)])
        XCTAssertEqual(axes, [40], "04/22 is one runway, not two lines")
    }

    func testDistinctRunwaysProduceDistinctAxesSorted() {
        let axes = AirportSymbol.runwayAxes([rw(140, 5000), rw(35, 7864), rw(92, 7001)])
        XCTAssertEqual(axes, [35, 90, 140], "quantized to 5° and sorted")
    }

    func testBearingsAreQuantizedSoIdenticalLayoutsShareAnImage() {
        let a = AirportSymbol.runwayAxes([rw(34, 5000)])
        let b = AirportSymbol.runwayAxes([rw(36, 5000)])
        XCTAssertEqual(a, b, "34° and 36° both quantize to 35° — same drawn symbol, one cached image")
    }

    func testNonFiniteBearingIsSkippedNotDrawn() {
        let axes = AirportSymbol.runwayAxes([rw(.nan, 5000), rw(90, 5000)])
        XCTAssertEqual(axes, [90])
    }

    func testThreeSixtyFoldsToZero() {
        XCTAssertEqual(AirportSymbol.runwayAxes([rw(360, 5000)]), [0])
        XCTAssertEqual(AirportSymbol.runwayAxes([rw(180, 5000)]), [0])
    }

    // MARK: the distinct FAA glyph families

    func testHeliportSeaplaneUltralightAndClosedAreTheirOwnGlyphs() {
        XCTAssertEqual(AirportSymbol.classifyKind(.init(typeCode: "HEL")), .heliport)
        XCTAssertEqual(AirportSymbol.classifyKind(.init(typeCode: "SPB")), .seaplane)
        XCTAssertEqual(AirportSymbol.classifyKind(.init(typeCode: "ULT")), .ultralight)
        XCTAssertEqual(AirportSymbol.classifyKind(.init(typeCode: "CLS")), .abandoned)
    }

    func testMilitaryIsRecognisedByOwnerOrByName() {
        XCTAssertEqual(AirportSymbol.classifyKind(.init(owner: "M", typeCode: "ARP")), .military)
        XCTAssertEqual(AirportSymbol.classifyKind(.init(owner: "P", typeCode: "ARP",
                                                        name: "NORTH ISLAND NAS")), .military)
        XCTAssertEqual(AirportSymbol.classifyKind(.init(owner: "P", typeCode: "ARP",
                                                        name: "TRAVIS AFB")), .military)
    }

    func testPrivateUseGetsTheRestrictedGlyph() {
        XCTAssertEqual(AirportSymbol.classifyKind(.init(owner: "R", typeCode: "ARP")), .privateUse)
    }

    /// An airport we know nothing about is the FAA's "unverified" case — information is lacking. It
    /// must NOT be silently drawn as an ordinary public airport.
    func testAnAirportWithNoRecordAtAllIsUnverified() {
        XCTAssertEqual(AirportSymbol.classifyKind(.init()), .unverified)
    }

    func testAnAirportWithSomeRecordIsAnOrdinaryAirport() {
        XCTAssertEqual(AirportSymbol.classifyKind(.init(hasTower: false, hardSurface: true,
                                                        owner: "P", typeCode: "ARP")), .airport)
    }

    // MARK: fuel / beacon

    func testFuelAndBeaconAreCarriedThrough() {
        let s = AirportSymbol.spec(attributes: .init(hasTower: true, hasFuel: true, hasBeacon: true,
                                                     hardSurface: true, typeCode: "ARP"),
                                   runways: [rw(35, 5000)], category: nil)
        XCTAssertTrue(s.fuel, "fuel draws the tick marks")
        XCTAssertTrue(s.beacon, "a beacon draws the star")
    }

    func testUnknownFuelIsNotDrawnAsNoFuel() {
        // The spec flag is false (nothing drawn) but that is ABSENCE OF INFORMATION — the renderer
        // must never label it "no fuel". Pinned here so the meaning isn't lost.
        let s = AirportSymbol.spec(attributes: .init(hasTower: true, hardSurface: true, typeCode: "ARP"),
                                   runways: [rw(35, 5000)], category: nil)
        XCTAssertFalse(s.fuel)
    }

    // MARK: signature — what lets identical airports share one rendered image

    func testIdenticalAirportsShareASignatureAndDifferentOnesDoNot() {
        let a = AirportSymbol.spec(attributes: .init(hasTower: true, hasFuel: true, hardSurface: true,
                                                     typeCode: "ARP"),
                                   runways: [rw(35, 5000)], category: .vfr)
        let b = AirportSymbol.spec(attributes: .init(hasTower: true, hasFuel: true, hardSurface: true,
                                                     typeCode: "ARP"),
                                   runways: [rw(34, 5200)], category: .vfr)   // quantizes the same
        XCTAssertEqual(a.signature, b.signature, "same-looking airports must share one cached glyph")

        let c = AirportSymbol.spec(attributes: .init(hasTower: false, hasFuel: true, hardSurface: true,
                                                     typeCode: "ARP"),
                                   runways: [rw(35, 5000)], category: .vfr)
        XCTAssertNotEqual(a.signature, c.signature, "tower status must change the glyph")
    }

    func testCategoryIsPartOfTheSignature() {
        let attrs = AirportSymbol.Attributes(hasTower: true, hardSurface: true, typeCode: "ARP")
        let vfr = AirportSymbol.spec(attributes: attrs, runways: [rw(35, 5000)], category: .vfr)
        let ifr = AirportSymbol.spec(attributes: attrs, runways: [rw(35, 5000)], category: .ifr)
        XCTAssertNotEqual(vfr.signature, ifr.signature, "flight category tints the symbol")
    }
}
