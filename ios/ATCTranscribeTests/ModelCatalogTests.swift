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

    func testCatalogHasRequiredAndOptionalEntries() {
        XCTAssertTrue(ModelCatalog.required.required)
        XCTAssertEqual(ModelCatalog.required.id, "small")
        XCTAssertTrue(ModelCatalog.all.contains { $0.id == "turbo" })
        XCTAssertTrue(ModelCatalog.all.contains { $0.id == "llm" && $0.kind == .ggufFile })
        XCTAssertNotNil(ModelCatalog.llm.directURL)
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

        let dir = ModelStore.whisperDir("small")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)

        XCTAssertTrue(ModelStore.isReady(ModelCatalog.small))
        XCTAssertEqual(ModelStore.downloadedWhisperDir(), dir.path)
    }

    func testWhisperPrefersTurboWhenBothPresent() throws {
        let fm = FileManager.default
        for v in ["small", "turbo"] {
            try fm.createDirectory(at: ModelStore.whisperDir(v).appendingPathComponent("AudioEncoder.mlmodelc"),
                                   withIntermediateDirectories: true)
        }
        XCTAssertEqual(ModelStore.downloadedWhisperDir(), ModelStore.whisperDir("turbo").path)
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
