import XCTest
import UIKit
@testable import ATCTranscribe

/// The chart marker for deteriorating weather: which stations get one, how severe, and what it looks like.
final class WxTrendMarkerTests: XCTestCase {

    private func result(_ ident: String, ceilRate: Double?, visRate: Double? = nil,
                        current: Metar.Category = .vfr,
                        p1: Metar.Category? = nil, p2: Metar.Category? = nil,
                        significant: Bool = true) -> MetarTrend.Result {
        MetarTrend.Result(ident: ident, current: current, ceilingRateFtPerHr: ceilRate,
                          visRateSmPerHr: visRate, direction: .deteriorating,
                          projected1h: p1 ?? current, projected2h: p2 ?? current,
                          isSignificant: significant, sampleCount: 4)
    }

    // MARK: severity — the distinction that changes a go/no-go

    /// Falling fast but staying in category is the lighter marker; crossing INTO a worse category is the
    /// one a pilot must not miss.
    func testCrossingIntoAWorseCategoryIsTheHeavierMarker() {
        let holding = result("KAAA", ceilRate: -300, current: .vfr, p1: .vfr, p2: .vfr)
        let dropping = result("KBBB", ceilRate: -800, current: .vfr, p1: .mvfr, p2: .ifr)
        XCTAssertFalse(holding.projectsCategoryDrop)
        XCTAssertTrue(dropping.projectsCategoryDrop)

        let pins = WxTrendPin.pins(from: [holding, dropping])
        XCTAssertEqual(pins.count, 2, "both are significant, both get a marker")
        XCTAssertEqual(pins.first { $0.ident == "KAAA" }?.severity, .falling)
        XCTAssertEqual(pins.first { $0.ident == "KBBB" }?.severity, .dropping)
    }

    // MARK: placement — never guess a location

    func testAStationThatCannotBePlacedIsDroppedNotGuessed() {
        let pins = WxTrendPin.pins(from: [result("ZZZZ9", ceilRate: -400)])
        XCTAssertTrue(pins.isEmpty, "an unplaceable ident must not land at 0,0 in the Atlantic")
    }

    func testAKnownAirportResolvesToItsRealCoordinate() throws {
        try XCTSkipUnless(NavDatabase.resolve("KBOS", near: nil) != nil, "nav database not bundled")
        let pins = WxTrendPin.pins(from: [result("KBOS", ceilRate: -400)])
        let pin = try XCTUnwrap(pins.first)
        XCTAssertEqual(pin.coord.lat, 42.36, accuracy: 0.3)
        XCTAssertEqual(pin.coord.lon, -71.01, accuracy: 0.3)
    }

    func testTheMarkerSetIsBounded() {
        let many = (0..<200).map { result("KBOS", ceilRate: -400 - Double($0)) }
        XCTAssertLessThanOrEqual(WxTrendPin.pins(from: many).count, 60)
    }

    // MARK: caption — knowing WHICH field without tapping

    func testCaptionCarriesTheIdentAndTheRate() {
        let pin = WxTrendPin.pins(from: [result("KBOS", ceilRate: -400)]).first
        XCTAssertEqual(pin?.caption, "KBOS ↓400")
    }

    func testAVisibilityDrivenTrendCaptionsInMiles() throws {
        try XCTSkipUnless(NavDatabase.resolve("KBOS", near: nil) != nil, "nav database not bundled")
        let pin = WxTrendPin.pins(from: [result("KBOS", ceilRate: nil, visRate: -2.0)]).first
        XCTAssertEqual(pin?.caption, "KBOS ↓2.0SM")
    }

    // MARK: the drawn marker

    func testTheTwoSeveritiesRenderDifferently() {
        let a = WxTrendMarker.image(severity: .falling)
        let b = WxTrendMarker.image(severity: .dropping)
        XCTAssertNotEqual(a.pngData(), b.pngData(), "the severities must be told apart at a glance")
        XCTAssertEqual(a.size, WxTrendMarker.size)
    }

    func testTheMarkerIsNotBlank() throws {
        let img = WxTrendMarker.image(severity: .dropping)
        let data = try XCTUnwrap(img.pngData())
        XCTAssertGreaterThan(data.count, 200, "a blank PNG would compress to almost nothing")
    }

    /// The markers must not be confusable with an airport glyph — they're read together on the chart.
    func testTheMarkerDoesNotRenderIdenticallyToAnAirportGlyph() {
        let apt = AirportSymbolRenderer.image(for: AirportSymbol.Spec(
            kind: .airport, shape: .filledCircleWithRunways, towered: true, fuel: false,
            beacon: false, runwayAxesDeg: [40], category: .vfr))
        XCTAssertNotEqual(apt.pngData(), WxTrendMarker.image(severity: .dropping).pngData())
    }

    /// A labelled sheet for visual confirmation, alongside the airport-glyph sheet.
    func testRenderMarkerSheet() throws {
        let size = CGSize(width: 240, height: 110)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.09, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, sev) in [WxTrendMarker.Severity.falling, .dropping].enumerated() {
                let m = WxTrendMarker.image(severity: sev)
                m.draw(at: CGPoint(x: CGFloat(i) * 120 + 45, y: 20))
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let label = sev == .falling ? "falling fast\n(same category)" : "drops a category\nwithin 2 hr"
                NSAttributedString(string: label, attributes: [
                    .font: UIFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: UIColor(white: 0.85, alpha: 1),
                    .paragraphStyle: para])
                    .draw(in: CGRect(x: CGFloat(i) * 120 + 5, y: 58, width: 110, height: 40))
            }
        }
        let out = URL(fileURLWithPath: "/tmp/wx_marker_sheet.png")
        try img.pngData()!.write(to: out)
        print("WXSHEET \(out.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }
}
