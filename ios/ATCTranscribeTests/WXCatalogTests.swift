import XCTest
@testable import ATCTranscribe

/// The WX tab's product catalog (URL templating) + the offline image cache.
@MainActor final class WXCatalogTests: XCTestCase {

    // MARK: catalog / URL templating

    func testEveryProductResolvesEveryVariantWithNoPlaceholders() {
        for p in WXCatalog.all {
            let aCount = p.axisA?.options.count ?? 1
            let bCount = p.axisB?.options.count ?? 1
            XCTAssertLessThanOrEqual(aCount * bCount, 100, "\(p.id): variant explosion")
            for a in 0..<aCount {                                        // bounded (catalog is static)
                for b in 0..<bCount {
                    let url = p.url(a: a, b: b)
                    XCTAssertFalse(url.contains("{A}") || url.contains("{B}"), "\(p.id): unresolved placeholder")
                    XCTAssertTrue(url.hasPrefix("https://"), "\(p.id): non-https URL")
                    XCTAssertNotNil(URL(string: url), "\(p.id): malformed URL \(url)")
                }
            }
        }
    }

    func testWAFSWindsCoverAllAltitudesAndHours() {
        let winds = WXCatalog.all.first { $0.id == "winds-wafs" }
        XCTAssertNotNil(winds)
        XCTAssertEqual(winds?.axisA?.options.count, 9)                  // FL050…FL630
        XCTAssertEqual(winds?.axisB?.options.count, 6)                  // +6…+36 h
        XCTAssertEqual(winds?.url(a: 4, b: 1), "https://aviationweather.gov/data/products/fax/F12_wind_300_a.gif")
    }

    func testCategoriesWithNoProductsAreHidden() {
        XCTAssertFalse(WXCatalog.categories.contains(.pireps),         // no static PIREP image exists on new AWC
                       "empty categories must be hidden from the tab")
        XCTAssertTrue(WXCatalog.categories.contains(.satellite))
        XCTAssertTrue(WXCatalog.categories.contains(.winds))
        XCTAssertTrue(WXCatalog.categories.contains(.icing))
        XCTAssertTrue(WXCatalog.categories.contains(.turbulence))
    }

    func testProductIDsAreUnique() {
        let ids = WXCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate WX product ids")
    }

    // MARK: cache

    private func tempCache() -> WXImageCache {
        WXImageCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wxtest-\(UUID().uuidString)"))
    }

    func testFileNameIsStableAndKeepsExtension() {
        let a = WXImageCache.fileName(for: "https://x.gov/a/b/chart.png")
        let b = WXImageCache.fileName(for: "https://x.gov/a/b/chart.png")
        XCTAssertEqual(a, b, "cache filename must be stable across calls/launches")
        XCTAssertTrue(a.hasSuffix(".png"))
        XCTAssertNotEqual(a, WXImageCache.fileName(for: "https://x.gov/a/b/other.png"))
    }

    func testCachedReturnsNilForUnknownURL() {
        XCTAssertNil(tempCache().cached("https://example.gov/never-fetched.gif"))
    }
}
