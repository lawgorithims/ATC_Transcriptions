import XCTest
@testable import ATCTranscribe

/// The download manager's state machine (notDownloaded → downloading → ready / failed), driven by
/// an injected fake downloader so no network is touched. State is published on the main actor.
@MainActor
final class ModelDownloadManagerTests: XCTestCase {

    /// Stub transfer: emits a couple of progress ticks, then succeeds or throws.
    struct FakeDownloader: ModelDownloading {
        let fail: Bool
        func downloadWhisper(variant: String, repo: String, into dest: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
            progress(0.25); progress(1.0)
            if fail { throw NSError(domain: "test", code: 1) }
        }
        func downloadFile(from url: URL, to dest: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
            progress(0.5); progress(1.0)
            if fail { throw NSError(domain: "test", code: 1) }
        }
    }

    override func setUp() {
        ModelStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("dlmgr-test-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        if let root = ModelStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        ModelStore.rootOverride = nil
    }

    func testInitialStateIsNotDownloaded() {
        let mgr = ModelDownloadManager(downloader: FakeDownloader(fail: false))
        XCTAssertEqual(mgr.state("small"), .notDownloaded)
    }

    func testSuccessfulDownloadReachesReadyAndFiresOnReady() async {
        let mgr = ModelDownloadManager(downloader: FakeDownloader(fail: false))
        var readyId: String?
        mgr.onReady = { readyId = $0.id }

        await mgr.download(ModelCatalog.small)?.value
        XCTAssertEqual(mgr.state("small"), .ready)
        XCTAssertEqual(readyId, "small")
    }

    func testFailedDownloadReachesFailed() async {
        let mgr = ModelDownloadManager(downloader: FakeDownloader(fail: true))
        await mgr.download(ModelCatalog.llm)?.value
        guard case .failed = mgr.state("llm") else {
            return XCTFail("expected .failed, got \(mgr.state("llm"))")
        }
    }

    func testDeleteResetsToNotDownloaded() async {
        let mgr = ModelDownloadManager(downloader: FakeDownloader(fail: false))
        await mgr.download(ModelCatalog.small)?.value
        XCTAssertEqual(mgr.state("small"), .ready)
        mgr.delete(ModelCatalog.small)
        XCTAssertEqual(mgr.state("small"), .notDownloaded)   // wiped + resettable
    }

    func testRedownloadReachesReadyAgain() async {
        let mgr = ModelDownloadManager(downloader: FakeDownloader(fail: false))
        await mgr.download(ModelCatalog.small)?.value
        await mgr.redownload(ModelCatalog.small)?.value        // delete + fetch again
        XCTAssertEqual(mgr.state("small"), .ready)
    }

    func testInFlightDownloadIsDeduped() async {
        let mgr = ModelDownloadManager(downloader: FakeDownloader(fail: false))
        var readyCount = 0
        mgr.onReady = { _ in readyCount += 1 }

        let first = mgr.download(ModelCatalog.small)
        _ = mgr.download(ModelCatalog.small)   // deduped onto the in-flight task — no second run
        await first?.value

        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(mgr.state("small"), .ready)
    }
}
