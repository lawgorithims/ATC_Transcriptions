import XCTest
@testable import ATCTranscribe

/// The opt-in JSONL transcript log — DTO round-trip + store append/rotation/gating.
final class TranscriptLogTests: XCTestCase {

    private func uniqueDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testEntryRoundTripNoInteriorNewline() throws {
        var e = TranscriptLogEntry(type: "record", id: "r1")
        e.rawText = "cleared direct bosox"
        e.gateConfidence = 0.9
        e.parsed = ParsedInstructionLog(callsign: "N1", kind: "altitude", target: "8000", value: 8000,
                                        unit: "ft", modifier: "descend", confidence: "high")
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(e)
        XCTAssertFalse(data.contains(0x0A), "one JSON object per line — no interior newline")
        let back = try JSONDecoder().decode(TranscriptLogEntry.self, from: data)
        XCTAssertEqual(back.rawText, "cleared direct bosox")
        XCTAssertEqual(back.parsed?.value, 8000)
    }

    func testStoreWritesOneLinePerEntryWithSessionContext() async throws {
        let dir = try uniqueDir()
        guard let store = TranscriptLogStore(directory: dir, sessionId: "s1", source: "mic", modelId: "small") else {
            return XCTFail("store failed to open")
        }
        for i in 0..<5 { await store.log(TranscriptLogEntry(type: "record", id: "r\(i)")) }
        let url = await store.exportFileURL()
        await store.close()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            let e = try JSONDecoder().decode(TranscriptLogEntry.self, from: Data(line.utf8))
            XCTAssertEqual(e.sessionId, "s1")
            XCTAssertEqual(e.source, "mic")
            XCTAssertEqual(e.modelId, "small")
            XCTAssertGreaterThan(e.loggedAtMs, 0)
        }
    }

    func testStoreRotatesPastSizeCap() async throws {
        let dir = try uniqueDir()
        var cfg = TranscriptLogStore.Config(); cfg.maxBufferLines = 1; cfg.maxFileBytes = 10
        guard let store = TranscriptLogStore(directory: dir, sessionId: "s", source: "mic", modelId: "m", config: cfg) else {
            return XCTFail("store failed to open")
        }
        for i in 0..<3 { await store.log(TranscriptLogEntry(type: "record", id: "r\(i)")) }
        await store.close()
        let rotated = dir.appendingPathComponent("atc-transcripts.jsonl.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "size cap should have rotated the file")
    }
}
