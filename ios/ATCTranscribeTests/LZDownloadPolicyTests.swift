import XCTest
@testable import ATCTranscribe

/// The landability pack transfer — ~88 MB, the largest single download the app makes — against the
/// two controls the pilot is given over their data.
///
/// ⚠️ IT ESCAPED BOTH OF THEM. `LZPackLibrary.download` went straight to `FileDownloader`: it never
/// consulted `DownloadPolicy`, so a pilot who had set "Wi-Fi only" could still pull a pack over
/// cellular from the per-cell row, and it never registered with `NetworkActivity`, so the biggest
/// transfer in the app was the one thing absent from the Data activity queue — invisible,
/// unpausable, and uncounted against the concurrency limit that exists to stop a weak link being
/// split six ways. Only the catalog fetch, a few kilobytes, was ever in either.
final class LZDownloadPolicyTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lzdl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A cell the catalog could legitimately publish. Never fetched — the point of the test is that
    /// the transfer is held before a byte moves.
    private func cell(_ id: String) throws -> LZPackCatalog.Cell {
        let json = """
        {"id":"\(id)","path":"cells/\(id).lzpack","bytes":88000000,"bounds":[-108,32,-107,33]}
        """
        return try JSONDecoder().decode(LZPackCatalog.Cell.self, from: Data(json.utf8))
    }

    /// Pausing "Landability packs" must hold the transfer BEFORE it starts — not let it run and
    /// hide the row.
    @MainActor
    func testAPausedCategoryHoldsAPackBeforeAnyByteMoves() async throws {
        let activity = NetworkActivity.shared
        activity.setPaused(.landability, true)
        let lib = LZPackLibrary(directory: tmp)
        let c = try cell("n33w107")

        lib.download(c)

        // Poll rather than sleep a fixed interval: the job has to cross two actors to register.
        var job: NetworkActivity.Job?
        for _ in 0..<50 {                                     // bounded (rule 2)
            job = activity.activeJobs.first { $0.category == .landability }
            if job?.state == .paused { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertNotNil(job, "the pack transfer never registered with the data queue — it is "
                        + "invisible and unpausable, which is the defect this test exists for")
        XCTAssertEqual(job?.state, .paused, "the pilot paused this category and it started anyway")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.localURL(c).path),
                       "bytes landed on disk while the category was paused")

        // Leave the shared queue as we found it, and stop the parked job before unpausing so it
        // cannot start a real transfer against a fabricated cell id.
        lib.cancel(c.id)
        activity.setPaused(.landability, false)
    }

    /// The row the pilot taps carries a plain-language label, not a URL or a UUID — this is the
    /// text that appears in the queue when they are wondering what the app is doing.
    @MainActor
    func testTheQueuedPackSaysWhatItIs() async throws {
        let activity = NetworkActivity.shared
        activity.setPaused(.landability, true)
        let lib = LZPackLibrary(directory: tmp)
        let c = try cell("n34w112")
        lib.download(c)

        var label = ""
        for _ in 0..<50 {                                     // bounded (rule 2)
            if let j = activity.activeJobs.first(where: { $0.category == .landability }) {
                label = j.label; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(label.contains("n34w112"), "queue row reads \"\(label)\" — name the pack")
        XCTAssertTrue(label.lowercased().contains("landability"), "queue row reads \"\(label)\"")

        lib.cancel(c.id)
        activity.setPaused(.landability, false)
    }

    /// The category exists, is pausable, and is not treated as flight-critical — off-field terrain
    /// is advisory ground data, unlike radar or weather.
    func testLandabilityIsAPausableNonCriticalCategory() {
        XCTAssertFalse(NetworkActivity.Category.landability.isFlightCritical)
        XCTAssertEqual(NetworkActivity.Category.landability.title, "Landability packs")
    }
}
