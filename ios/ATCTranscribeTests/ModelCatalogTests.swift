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

    func testStockCleanModelEntry() {
        // Optional, non-fine-tuned WhisperKit model exposed as "Large V2".
        let clean = ModelCatalog.cleanturbo
        XCTAssertEqual(clean.id, "cleanturbo")
        XCTAssertEqual(clean.shortLabel, "Large V2")
        XCTAssertEqual(clean.kind, .whisperKit)
        XCTAssertFalse(clean.required)
        XCTAssertNotNil(clean.repo)
        XCTAssertFalse(clean.variant?.isEmpty ?? true)
        XCTAssertTrue(ModelCatalog.all.contains { $0.id == "cleanturbo" })
        // Picker order (smallest → largest) and id→label mapping used by the badge/sidebar.
        XCTAssertEqual(ModelCatalog.whisperEntries.map(\.id), ["small", "turbo", "cleanturbo"])
        XCTAssertEqual(ModelCatalog.shortLabel(forID: "turbo"), "Large")
        XCTAssertEqual(ModelCatalog.shortLabel(forID: "cleanturbo"), "Large V2")
        XCTAssertEqual(ModelCatalog.shortLabel(forID: "mystery"), "mystery")   // unknown → raw id
    }

    func testStockModelResolvesByItsVariantFolder() throws {
        let fm = FileManager.default
        let clean = ModelCatalog.cleanturbo
        // The stock model's on-disk folder is its long WhisperKit variant id, NOT its short "cleanturbo" id.
        XCTAssertNotEqual(clean.variant, clean.id)
        try fm.createDirectory(at: ModelStore.localURL(for: clean).appendingPathComponent("AudioEncoder.mlmodelc"),
                               withIntermediateDirectories: true)
        XCTAssertTrue(ModelStore.isReady(clean))
        // Alone, it's the resolved downloaded model…
        XCTAssertEqual(ModelStore.downloadedWhisperDir(), ModelStore.localURL(for: clean).path)
        // …but the fine-tuned turbo is still preferred when both are present.
        try fm.createDirectory(at: ModelStore.whisperDir("turbo").appendingPathComponent("AudioEncoder.mlmodelc"),
                               withIntermediateDirectories: true)
        XCTAssertEqual(ModelStore.downloadedWhisperDir(), ModelStore.whisperDir("turbo").path)
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
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true)

        XCTAssertTrue(ModelStore.isReady(ModelCatalog.small))
        XCTAssertEqual(ModelStore.downloadedWhisperDir(), dir.path)
    }

    func testWhisperPrefersTurboWhenBothPresent() throws {
        let fm = FileManager.default
        // Create each model at its ACTUAL variant folder (small's is "small-v2" after the bump, not
        // "small") so isReady(small) is genuinely true — otherwise the "small" leg is a no-op and the
        // turbo-over-small ordering isn't really exercised.
        for v in [ModelCatalog.small.variant ?? ModelCatalog.small.id,
                  ModelCatalog.turbo.variant ?? ModelCatalog.turbo.id] {
            try fm.createDirectory(at: ModelStore.whisperDir(v).appendingPathComponent("AudioEncoder.mlmodelc"),
                                   withIntermediateDirectories: true)
        }
        XCTAssertEqual(ModelStore.downloadedWhisperDir(),
                       ModelStore.whisperDir(ModelCatalog.turbo.variant ?? ModelCatalog.turbo.id).path)
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
