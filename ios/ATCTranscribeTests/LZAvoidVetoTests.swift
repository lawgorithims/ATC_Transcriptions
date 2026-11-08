import XCTest
@testable import ATCTranscribe

/// The avoid-map veto: the landability layer refusing ground it used to offer.
///
/// ⚠️ WHAT THESE PIN, AND WHY THEY ARE NOT THE PROOF. The first ground-truth eval measured the
/// device offering 79% of solar farms and 53% of Fresno's orchards and vineyards as landing
/// candidates, and ground directly under transmission lines 27% of the time, because the packs
/// classify by LAND COVER and a solar farm reads as open firm ground while an orchard reads as
/// crop. These tests prove the veto is wired correctly and cannot change the score when the avoid
/// map is absent. They do NOT prove the rates moved — only `lz/eval_groundtruth.py --gate` can say
/// that, against real OpenStreetMap ground, and it has not been run against this change.
final class LZAvoidVetoTests: XCTestCase {

    /// The four bits the packs are blind to — and ONLY those.
    func testTheVetoMaskIsExactlyTheHazardsLandCoverCannotSee() {
        let m = LZTileCompositor.avoidVetoMask
        for r in [AvoidReason.orchard, .solar, .wires, .obstacle] {
            XCTAssertNotEqual(m & r.rawValue, 0, "\(r) must veto — the packs cannot see it")
        }
        // ⚠️ Water, developed, trees and steep are judged by the pack's own class veto and slope
        // veto. Vetoing them here too would add exclusions where the pack already has an opinion,
        // which is how the OTHER half of the eval — ~40% of runway centrelines already vetoed —
        // gets worse.
        for r in [AvoidReason.water, .developed, .trees, .steep] {
            XCTAssertEqual(m & r.rawValue, 0, "\(r) is the pack's judgement, not the avoid map's")
        }
    }

    /// ⚠️ NIL IS NOT ZERO. The avoid map is an optional ~1 GB download; a pilot without it must get
    /// exactly the scores they got before this veto existed, not a blank map.
    func testWithoutTheAvoidMapEveryScoreIsUnchanged() throws {
        let c = try compositor()
        for cls in [LZPack.classOpenFirm, LZPack.classCrop, LZPack.classBrush] {
            let before = c.verdictCode(cls: cls, conf: 200, slope: 10, rough: 10, hazard: 0,
                                       flags: 0, coarse: false, extent: nil, avoid: nil)
            let clear = c.verdictCode(cls: cls, conf: 200, slope: 10, rough: 10, hazard: 0,
                                      flags: 0, coarse: false, extent: nil, avoid: 0)
            XCTAssertEqual(before, clear,
                           "a consulted-and-clear cell must score the same as an unconsulted one")
            XCTAssertGreaterThan(before, 0, "setup: this cell should be offered at all")
        }
    }

    /// The reported failure, at the level this code can test: ground the pack calls open firm or
    /// crop is excluded once the avoid map says solar, orchard or wires.
    func testGroundThePackLikesIsExcludedWhenTheAvoidMapNamesAHazard() throws {
        let c = try compositor()
        for (reason, label) in [(AvoidReason.solar, "solar farm"), (.orchard, "orchard"),
                                (.wires, "under power lines"), (.obstacle, "tower")] {
            for cls in [LZPack.classOpenFirm, LZPack.classCrop] {
                let code = c.verdictCode(cls: cls, conf: 200, slope: 10, rough: 10, hazard: 0,
                                         flags: 0, coarse: false, extent: nil,
                                         avoid: reason.rawValue)
                XCTAssertEqual(code, -1, "\(label) on class \(cls) must be EXCLUDED, not scored")
            }
        }
    }

    /// A bit the mask does not carry must change nothing, or the veto is really a blanket one.
    func testABitOutsideTheMaskDoesNotVeto() throws {
        let c = try compositor()
        let clear = c.verdictCode(cls: LZPack.classOpenFirm, conf: 200, slope: 10, rough: 10,
                                  hazard: 0, flags: 0, coarse: false, extent: nil, avoid: 0)
        let treed = c.verdictCode(cls: LZPack.classOpenFirm, conf: 200, slope: 10, rough: 10,
                                  hazard: 0, flags: 0, coarse: false, extent: nil,
                                  avoid: AvoidReason.trees.rawValue)
        XCTAssertEqual(clear, treed, "trees are the pack's call; this veto must not touch them")
    }

    /// ⚠️ UNSURVEYED GROUND STAYS UNSURVEYED. The veto sits after the two `.unknown` returns, so it
    /// can only remove green — never paint a claim over ground the pack knows nothing about.
    func testAHazardOverUnknownGroundIsStillUnknown() throws {
        let c = try compositor()
        let code = c.verdictCode(cls: LZPack.classUnknown, conf: 200, slope: 10, rough: 10,
                                 hazard: 0, flags: 0, coarse: false, extent: nil,
                                 avoid: AvoidReason.solar.rawValue)
        XCTAssertEqual(code, -2, "unknown ground must stay unknown, not become an exclusion")
    }

    private func compositor() throws -> LZTileCompositor {
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: Bundle(for: Self.self))
                                ?? LZRulesetCompiler.loadDocument(bundle: .main))
        let rules = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: nil,
                                                            themeKey: "day", packStamp: "veto-test"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzveto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return LZTileCompositor(store: LZPackStore(directory: dir), rules: rules, night: false)
    }
}
