import XCTest
@testable import ATCTranscribe

/// The offline plate cache (PlateStore) + the bundled d-TPP index (Procedures). The network download
/// itself is not unit-tested (it hits FAA); these cover the cache keying, freshness, and pruning.
final class PlateStoreTests: XCTestCase {

    private func proc(_ pdf: String, _ cat: AirportProcedure.Category = .approach) -> AirportProcedure {
        AirportProcedure(category: cat, name: "TEST \(pdf)", pdf: pdf)
    }

    func testLocalURLKeysByPdfAndCycle() throws {
        try XCTSkipIf(Procedures.cycle.isEmpty, "no bundled d-TPP cycle in the test host")
        let url = try XCTUnwrap(PlateStore.localURL(proc("00058IL4R.PDF")))
        XCTAssertEqual(url.pathExtension.lowercased(), "pdf")
        XCTAssertEqual(url.lastPathComponent, "00058IL4R-\(Procedures.cycle).pdf",
                       "plate cache file must be keyed by pdf stem + chart cycle")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "plates")
    }

    func testLocalURLNilForEmptyPdf() {
        XCTAssertNil(PlateStore.localURL(proc("")), "no pdf reference → nothing to cache")
    }

    func testIsCachedFalseWhenAbsent() throws {
        try XCTSkipIf(Procedures.cycle.isEmpty, "no bundled d-TPP cycle in the test host")
        // A random pdf name is never on disk.
        XCTAssertFalse(PlateStore.isCached(proc("ZZNONEXISTENT9.PDF")))
    }

    func testPruneRemovesOtherCycleFilesOnly() throws {
        try XCTSkipIf(Procedures.cycle.isEmpty, "no bundled d-TPP cycle in the test host")
        let fm = FileManager.default
        let cur = PlateStore.dir.appendingPathComponent("KEEPME-\(Procedures.cycle).pdf")
        let old = PlateStore.dir.appendingPathComponent("DROPME-0001.pdf")   // a bogus old cycle
        try? Data("%PDF-cur".utf8).write(to: cur)
        try? Data("%PDF-old".utf8).write(to: old)
        defer { try? fm.removeItem(at: cur); try? fm.removeItem(at: old) }

        _ = PlateStore.pruneStaleCycles()
        XCTAssertTrue(fm.fileExists(atPath: cur.path), "current-cycle plate must survive pruning")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "an old-cycle plate must be pruned")
    }

    // MARK: - Procedures (the bundled plate index)

    func testProceduresIndexLoadsAndReferencesPlates() throws {
        try XCTSkipIf(Procedures.airportCount == 0, "procedures.json not bundled in the test host")
        // A large hub always publishes approaches; pick one that's certainly in the index.
        let plates = Procedures.forAirport("KBOS")
        try XCTSkipIf(plates.isEmpty, "KBOS not in the bundled cycle")
        XCTAssertTrue(plates.contains { $0.category == .approach }, "KBOS must publish approach plates")
        let iap = try XCTUnwrap(plates.first { $0.category == .approach })
        XCTAssertFalse(iap.pdf.isEmpty)
        let url = try XCTUnwrap(iap.plateURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://aeronav.faa.gov/d-tpp/"),
                      "plate URL must point at the FAA d-TPP for the bundled cycle")
    }
}
