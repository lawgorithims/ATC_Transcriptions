import XCTest
@testable import ATCTranscribe

/// Catalog completeness + `ModelStore` path construction and `isReady` marker checks. These run
/// against a temp directory (`ModelStore.rootOverride`) so no real Application Support is touched.
final class ModelCatalogTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelstore-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        ModelStore.rootOverride = tmp
    }

    override func tearDownWithError() throws {
        ModelStore.rootOverride = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Create a COMPLETE WhisperKit model folder (all three sub-models) so `isReady` passes — mirrors a
    /// finished download. `isReady` now requires Mel + Audio + Decoder, not just AudioEncoder.
    private func makeWhisperModel(at dir: URL) throws {
        for part in ModelStore.whisperModelParts {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("\(part).mlmodelc"), withIntermediateDirectories: true)
        }
    }

    func testPartialWhisperDownloadIsNotReady() throws {
        // A partial/interrupted download (only AudioEncoder) must NOT read as ready — else it loads
        // then fails "model file not found". This is the on-device download-load failure class.
        let dir = ModelStore.whisperDir(ModelCatalog.small.variant ?? ModelCatalog.small.id)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertFalse(ModelStore.isReady(ModelCatalog.small), "a partial whisper folder must not be ready")
        try makeWhisperModel(at: dir)   // add Mel + Decoder → complete
        XCTAssertTrue(ModelStore.isReady(ModelCatalog.small))
    }

    func testCatalogHasRequiredAndOptionalEntries() {
        XCTAssertTrue(ModelCatalog.required.required)
        XCTAssertEqual(ModelCatalog.required.id, "small")
        XCTAssertTrue(ModelCatalog.all.contains { $0.id == "llm" && $0.kind == .ggufFile })
        XCTAssertNotNil(ModelCatalog.llm.directURL)
    }

    func testSmallIsTheOnlySpeechModel() {
        // The large-v3-turbo variants ("Large" / "Large V2") were removed — they can't run on an M1
        // iPad Air. `small` must be the sole selectable speech model, and the removed ids must be gone.
        XCTAssertEqual(ModelCatalog.whisperEntries.map(\.id), ["small"])
        XCTAssertFalse(ModelCatalog.all.contains { $0.id == "turbo" || $0.id == "cleanturbo" })
        XCTAssertEqual(ModelCatalog.shortLabel(forID: "small"), "Small")
        XCTAssertEqual(ModelCatalog.shortLabel(forID: "mystery"), "mystery")   // unknown → raw id
    }

    func testDestinationPaths() {
        // Layout below the store root (the test overrides root, so don't assert on "Models").
        XCTAssertTrue(ModelStore.whisperDir("small").path.hasSuffix("whisper/small"))
        XCTAssertEqual(ModelStore.localURL(for: ModelCatalog.llm).lastPathComponent,
                       "qwen2.5-0.5b-instruct-q4_k_m.gguf")
    }

    func testWhisperReadyOnlyWithMarker() throws {
        XCTAssertFalse(ModelStore.isReady(ModelCatalog.small))
        XCTAssertNil(ModelStore.downloadedWhisperDir())

        // Use the catalog's actual variant folder (the `small` entry's on-disk variant can be bumped,
        // e.g. small → small-v2, to force a re-download) so this stays correct across model updates.
        let dir = ModelStore.whisperDir(ModelCatalog.small.variant ?? ModelCatalog.small.id)
        try makeWhisperModel(at: dir)

        XCTAssertTrue(ModelStore.isReady(ModelCatalog.small))
        XCTAssertEqual(ModelStore.downloadedWhisperDir(), dir.path)
    }

    func testGGUFReadyAndPath() throws {
        XCTAssertFalse(ModelStore.isReady(ModelCatalog.llm))
        XCTAssertNil(ModelStore.downloadedLLMPath())

        let path = ModelStore.localURL(for: ModelCatalog.llm)
        try FileManager.default.createDirectory(at: ModelStore.llmDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path.path, contents: Data("gguf".utf8))

        XCTAssertTrue(ModelStore.isReady(ModelCatalog.llm))
        XCTAssertEqual(ModelStore.downloadedLLMPath(), path.path)
    }
}
