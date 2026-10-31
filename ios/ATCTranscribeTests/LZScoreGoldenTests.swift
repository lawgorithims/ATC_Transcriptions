import XCTest
import CryptoKit
@testable import ATCTranscribe

/// The pin between the device's scoring and the offline ground-truth evaluator.
///
/// `lz/eval_groundtruth.py` measures the packs by re-implementing the device verdict in Python — the
/// only way to sample tens of thousands of real places without a simulator. A re-implementation that
/// drifts from the device measures a different layer and reports it as this one. So the Python side
/// writes 3,000 fact tuples with the scores IT computes (`lz/eval/golden_scores.json`), and this test
/// recomputes every one on the real `LZTileCompositor`. Any disagreement — a ruleset edit, a rounding
/// change, a new cap — fails here until both sides are brought back together.
final class LZScoreGoldenTests: XCTestCase {

    private static let golden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lz/eval/golden_scores.json")

    private struct Golden: Decodable {
        let ruleset_sha256: String
        let cases: [[Int]]
    }

    func testTheDeviceScoresEveryPinnedCaseExactlyAsTheEvaluatorDoes() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.golden.path),
                          "no golden file — run lz/eval_groundtruth.py --golden-write")
        let g = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.golden))
        let doc = try XCTUnwrap(LZRulesetCompiler.loadDocument(bundle: Bundle(for: Self.self))
                                ?? LZRulesetCompiler.loadDocument(bundle: .main))
        let sha = SHA256.hash(data: doc).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, g.ruleset_sha256,
                       "the golden cases were made from a different ruleset — run "
                       + "`lz/eval_groundtruth.py --golden-write` and re-run this test")

        // The DEFAULT aircraft (no profile) — what the evaluator and every deep-dive table used.
        let rules = try XCTUnwrap(LZRulesetCompiler.compile(document: doc, aircraft: nil,
                                                            themeKey: "day", packStamp: "golden"))
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzgolden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let comp = LZTileCompositor(store: LZPackStore(directory: empty), rules: rules, night: false)

        XCTAssertGreaterThan(g.cases.count, 1_000, "the pin is too thin to mean anything")
        var mismatches: [String] = []
        for c in g.cases {
            XCTAssertEqual(c.count, 9, "malformed golden row \(c)")
            guard c.count == 9 else { continue }
            let got = comp.verdictCode(cls: UInt8(c[0]), conf: UInt8(c[1]), slope: UInt8(c[2]),
                                       rough: UInt8(c[3]), hazard: UInt8(c[4]), flags: UInt8(c[5]),
                                       coarse: c[6] != 0, extent: UInt8(c[7]))
            if got != c[8], mismatches.count < 10 { mismatches.append("\(c.prefix(8)) device \(got) ≠ eval \(c[8])") }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "the evaluator no longer measures the device's layer:\n" + mismatches.joined(separator: "\n"))
    }
}
