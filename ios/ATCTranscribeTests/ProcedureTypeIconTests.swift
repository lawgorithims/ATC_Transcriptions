import XCTest
import SwiftUI
@testable import ATCTranscribe

/// Type icons in the chart lists.
///
/// The measurement that justifies them, and bounds them: over all 24,078 rows of the bundled d-TPP
/// index the name is self-describing for approaches (99.9%), airport diagrams (100%) and obstacle
/// departures (100%) — but only 62.3% of departures and 71.2% of arrivals, because those are named
/// after a fix. 1,975 charts called things like "BOTCH ONE" say nothing about which way they take you.
final class ProcedureTypeIconTests: XCTestCase {

    private func proc(_ code: String, _ name: String = "TEST") -> AirportProcedure {
        AirportProcedure(code: code, name: name, pdf: "00000\(code).PDF")
    }

    func testTheTwoAmbiguousKindsAreDistinguishable() {
        // THE case the feature exists for: a departure and an arrival, both named after a fix, in one
        // list. If these two ever share a symbol the icon has stopped doing its job.
        let dep = ProcedureTypeIcon.symbol(for: proc("DP", "BOTCH ONE"))
        let arr = ProcedureTypeIcon.symbol(for: proc("STR", "TARPN TWO"))
        XCTAssertNotEqual(dep, arr)
        XCTAssertEqual(dep, "airplane.departure")
        XCTAssertEqual(arr, "airplane.arrival")
    }

    func testEveryChartCodeInTheBundleHasASymbol() throws {
        // No code may fall to the generic default silently — the list would then show a document icon
        // for something the pilot needs to recognise.
        for code in ["IAP", "DP", "ODP", "STR", "APD", "MIN", "HOT", "LAH", "CVFP"] {
            let s = ProcedureTypeIcon.symbol(for: proc(code))
            XCTAssertFalse(s.isEmpty, "\(code) has no symbol")
            XCTAssertNotEqual(s, "doc.text", "\(code) fell through to the generic default")
        }
    }

    func testEverySymbolActuallyExistsInSFSymbols() {
        // A missing SF Symbol renders as nothing at all, which reads as "this row has no type".
        for code in ["IAP", "DP", "ODP", "STR", "APD", "MIN", "HOT", "LAH", "CVFP", "ZZZ"] {
            let name = ProcedureTypeIcon.symbol(for: proc(code))
            XCTAssertNotNil(UIImage(systemName: name), "\(code) -> '\(name)' is not a real SF Symbol")
        }
    }

    func testOnlyTheCautionKindIsColoured() {
        // Colour is reserved for the one distinction that is a warning rather than a category. Spending
        // the alarm palette on filing would dilute it everywhere else on the map.
        XCTAssertTrue(ProcedureTypeIcon.isCaution(proc("HOT")))
        for code in ["IAP", "DP", "ODP", "STR", "APD", "MIN", "LAH", "CVFP"] {
            XCTAssertFalse(ProcedureTypeIcon.isCaution(proc(code)), "\(code) must not claim caution colour")
        }
    }

    func testEveryCodeIsSpokenForVoiceOver() {
        // The symbol alone is not readable, and for the 1,975 fix-named charts neither is the name.
        for code in ["IAP", "DP", "ODP", "STR", "APD", "MIN", "HOT", "LAH", "CVFP"] {
            let l = ProcedureTypeIcon.accessibilityLabel(for: proc(code))
            XCTAssertFalse(l.isEmpty)
            XCTAssertNotEqual(l, "Chart", "\(code) has no spoken kind")
        }
    }

    func testAnUnknownFutureCodeDegradesRatherThanCrashes() {
        let p = proc("XYZ")
        XCTAssertEqual(ProcedureTypeIcon.symbol(for: p), "doc.text")
        XCTAssertEqual(ProcedureTypeIcon.accessibilityLabel(for: p), "Chart")
        XCTAssertFalse(ProcedureTypeIcon.isCaution(p))
    }

    func testObstacleDeparturesReadAsDepartures() {
        // ODP and DP are different chart codes but the same answer to "which way does this take me".
        XCTAssertEqual(ProcedureTypeIcon.symbol(for: proc("ODP")),
                       ProcedureTypeIcon.symbol(for: proc("DP")))
        XCTAssertNotEqual(ProcedureTypeIcon.accessibilityLabel(for: proc("ODP")),
                          ProcedureTypeIcon.accessibilityLabel(for: proc("DP")),
                          "they should still be spoken apart")
    }

    func testTheBundledIndexIsFullyCovered() throws {
        // Guards against a future cycle introducing a chart code the vocabulary does not know.
        let codes = Set(Procedures.allChartCodes())
        try XCTSkipIf(codes.isEmpty, "procedures.json not present")
        var unknown: [String] = []
        for c in codes.sorted().prefix(64) where ProcedureTypeIcon.symbol(for: proc(c)) == "doc.text" {
            unknown.append(c)                                                   // bounded (rule 2)
        }
        XCTAssertTrue(unknown.isEmpty, "chart codes with no icon: \(unknown)")
    }
}
