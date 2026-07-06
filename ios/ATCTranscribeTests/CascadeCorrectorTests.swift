import XCTest
@testable import ATCTranscribe

/// The two-pass cascade: local always, remote only within the latency budget, merges
/// transparent, and a slow remote can never hold the pipeline past the cap.
final class CascadeCorrectorTests: XCTestCase {

    private final class StubCorrector: LLMCorrector, @unchecked Sendable {
        let backend: String
        let delay: TimeInterval
        let result: (String) -> Correction
        private(set) var callCount = 0
        init(backend: String, delay: TimeInterval = 0, result: @escaping (String) -> Correction) {
            self.backend = backend
            self.delay = delay
            self.result = result
        }
        func correct(text: String, history: [String], retrieved: RetrievedContext) async -> Correction {
            callCount += 1
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            return result(text)
        }
    }

    private let retrieved = RetrievedContext(block: "", vocab: [], languageSuspect: false)

    private func fix(_ from: String, _ to: String, backend: String) -> (String) -> Correction {
        { text in
            Correction(raw: text,
                       corrected: text.replacingOccurrences(of: from, with: to),
                       changed: text.contains(from),
                       edits: text.contains(from) ? [CorrectionEdit(from: from, to: to, reason: "t", backend: backend)] : [],
                       backend: backend)
        }
    }

    func testNoSecondaryPassesLocalThrough() async {
        let local = StubCorrector(backend: "L", result: fix("aaa", "bbb", backend: "L"))
        let cascade = CascadeCorrector(primary: local, secondary: nil)
        let out = await cascade.correct(text: "aaa xyz", history: [], retrieved: retrieved)
        XCTAssertEqual(out.corrected, "bbb xyz")
        XCTAssertEqual(out.backend, "L")
    }

    func testSecondaryStacksOnLocalResult() async {
        let local = StubCorrector(backend: "L", result: fix("aaa", "bbb", backend: "L"))
        let remote = StubCorrector(backend: "R", result: fix("xyz", "zzz", backend: "R"))
        let cascade = CascadeCorrector(primary: local, secondary: remote)
        let out = await cascade.correct(text: "aaa xyz", history: [], retrieved: retrieved)
        XCTAssertEqual(out.corrected, "bbb zzz", "remote must see the locally-corrected text")
        XCTAssertEqual(out.edits.map(\.backend), ["L", "R"])
        XCTAssertEqual(out.backend, "L+R")
        XCTAssertTrue(out.raw == "aaa xyz", "raw stays the original transcript")
    }

    func testSlowRemoteIsAbandonedAtBudget() async {
        let local = StubCorrector(backend: "L", result: fix("aaa", "bbb", backend: "L"))
        let remote = StubCorrector(backend: "R", delay: 3.0, result: fix("xyz", "zzz", backend: "R"))
        var cascade = CascadeCorrector(primary: local, secondary: remote)
        cascade.budget = 0.8
        cascade.minSecondaryBudget = 0.1
        let start = Date()
        let out = await cascade.correct(text: "aaa xyz", history: [], retrieved: retrieved)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "must not wait out the slow remote")
        XCTAssertEqual(out.corrected, "bbb xyz", "local result survives the timeout")
        XCTAssertEqual(out.backend, "L")
    }

    func testRemoteSkippedWhenBudgetSpent() async {
        let local = StubCorrector(backend: "L", delay: 0.5, result: fix("aaa", "bbb", backend: "L"))
        let remote = StubCorrector(backend: "R", result: fix("xyz", "zzz", backend: "R"))
        var cascade = CascadeCorrector(primary: local, secondary: remote)
        cascade.budget = 0.5
        cascade.minSecondaryBudget = 0.3
        _ = await cascade.correct(text: "aaa xyz", history: [], retrieved: retrieved)
        XCTAssertEqual(remote.callCount, 0, "no remote start with the budget spent")
    }

    func testUnchangedRemoteKeepsLocal() async {
        let local = StubCorrector(backend: "L", result: fix("aaa", "bbb", backend: "L"))
        let remote = StubCorrector(backend: "R") { .unchanged($0, backend: "R") }
        let cascade = CascadeCorrector(primary: local, secondary: remote)
        let out = await cascade.correct(text: "aaa xyz", history: [], retrieved: retrieved)
        XCTAssertEqual(out.corrected, "bbb xyz")
        XCTAssertEqual(out.backend, "L")
    }

    func testRemoteFromSettingsDisabledByDefault() {
        UserDefaults.standard.removeObject(forKey: "atc.remoteFixerURL")
        XCTAssertNil(RemoteLLMCorrector.fromSettings(knowledge: .shared, feedKey: nil))
        UserDefaults.standard.set("not a url", forKey: "atc.remoteFixerURL")
        XCTAssertNil(RemoteLLMCorrector.fromSettings(knowledge: .shared, feedKey: nil))
        UserDefaults.standard.set("https://example.com/fix", forKey: "atc.remoteFixerURL")
        XCTAssertNotNil(RemoteLLMCorrector.fromSettings(knowledge: .shared, feedKey: nil))
        UserDefaults.standard.removeObject(forKey: "atc.remoteFixerURL")
    }
}
