import XCTest
@testable import ATCTranscribe

/// Validates the Clearance Test Bench CATALOG against the real detection pipeline — the same gates
/// `AppModel.interpretForEFB` runs, replicated here purely (no AppModel): normalize → ownship gate →
/// CIFP grounding → parse. This both proves the scenarios are well-authored and guards the parser:
/// if a future change breaks recognition of a scripted clearance, or lets a decoy through, this fails.
final class ClearanceScenarioTests: XCTestCase {

    /// Run one transmission through the real detection gates; returns the staged command, or nil.
    private func staged(_ tx: ScriptedTransmission, in s: ClearanceScenario) -> ATCCommand? {
        guard tx.role == .controller else { return nil }              // detector acts on controller text only
        let normalized = ATCNormalize.normalize(tx.text)
        let identity = OwnshipIdentity(callsign: s.aircraft.callsign, aircraftType: s.aircraft.type)
        guard identity.isValid, identity.isAddressed(inNormalized: normalized) else { return nil }
        let grounding = AppModel.buildEFBGrounding(
            ident: s.airport, routeIdents: s.seed.route,
            endpointAirports: [s.seed.departure, s.seed.destination, s.seed.alternate])
        return ATCCommandParser.parse(normalized, grounding: grounding,
                                      addressee: identity.addressee(airlineStarts: []))
    }

    // MARK: positives — the target fires with the expected command; nothing else fires

    func testPositiveScenariosStageTheExpectedCommand() {
        for s in ClearanceScenarioCatalog.all where s.category.expectsSuggestion {
            guard let target = s.target else { return XCTFail("\(s.id): bad targetIndex") }
            guard let cmd = staged(target, in: s) else {
                return XCTFail("\(s.id): the clearance to ownship did not stage a command:\n  \"\(target.text)\"")
            }
            XCTAssertEqual(cmd.kind.rawValue, s.expected.commandKind,
                           "\(s.id): wrong command kind for \"\(target.text)\"")
            if let want = s.expected.target {
                XCTAssertEqual(cmd.target, want, "\(s.id): wrong command target")
            } else {
                XCTAssertFalse(cmd.target.isEmpty, "\(s.id): command target should be non-empty")
            }
        }
    }

    func testPositiveScenariosDoNotFireOnDecoys() {
        for s in ClearanceScenarioCatalog.all where s.category.expectsSuggestion {
            for (i, tx) in s.script.enumerated() where i != s.targetIndex {
                XCTAssertNil(staged(tx, in: s),
                             "\(s.id): a NON-target line staged a command — false fire:\n  \"\(tx.text)\"")
            }
        }
    }

    // MARK: fail-safes — the critical safety property: NOTHING may fire, anywhere

    func testFailsafeScenariosNeverFire() {
        for s in ClearanceScenarioCatalog.all where !s.category.expectsSuggestion {
            for tx in s.script {
                XCTAssertNil(staged(tx, in: s),
                             "\(s.id): a fail-safe scenario staged a command — MUST NOT:\n  \"\(tx.text)\"")
            }
        }
    }

    // MARK: catalog hygiene

    func testCatalogWellFormed() {
        let all = ClearanceScenarioCatalog.all
        XCTAssertGreaterThanOrEqual(all.count, 5)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate scenario ids")
        // Coverage: every supported clearance kind + the fail-safe class is represented.
        let kinds = Set(all.compactMap { $0.expected.commandKind })
        for k in ["directTo", "loadSID", "loadStar", "clearedApproach"] {
            XCTAssertTrue(kinds.contains(k), "no scenario exercises \(k)")
        }
        XCTAssertTrue(all.contains { $0.category == .failsafe }, "no fail-safe scenario")
        for s in all {
            XCTAssertFalse(s.title.isEmpty); XCTAssertFalse(s.detail.isEmpty)
            XCTAssertFalse(s.script.isEmpty, "\(s.id): empty script")
            XCTAssertTrue(s.targetIndex >= 0 && s.targetIndex < s.script.count, "\(s.id): targetIndex OOB")
            XCTAssertFalse(s.airport.isEmpty, "\(s.id): no context airport")
        }
    }

    /// The seed plan carries ownship identity + endpoints the grounding needs.
    func testSeedPlanCarriesOwnshipAndEndpoints() {
        let s = ClearanceScenarioCatalog.directToFix
        let p = s.seedPlan()
        XCTAssertEqual(p.callsign, "N8925T")
        XCTAssertEqual(p.aircraftType, "Piper Seneca")
        XCTAssertEqual(p.destination, "KJFK")
        XCTAssertTrue(p.route.contains("STOLI"))
    }
}
