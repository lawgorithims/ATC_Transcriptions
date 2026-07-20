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

    // MARK: favorites

    func testFavoritesToggleAndPersistInCatalogOrder() {
        let key = "atc.wx.favorites"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let fav = WXFavorites()
        XCTAssertFalse(fav.isFavorite("sat-ir"))
        fav.toggle("sat-ir"); fav.toggle("prog-sfc")
        XCTAssertTrue(fav.isFavorite("sat-ir"))
        // products() returns catalog order regardless of toggle order, and only real products.
        let ids = fav.products(from: WXCatalog.all).map(\.id)
        XCTAssertTrue(ids.contains("sat-ir") && ids.contains("prog-sfc"))
        XCTAssertEqual(ids, WXCatalog.all.map(\.id).filter { ids.contains($0) }, "favorites keep catalog order")
        // A stale/unknown id never surfaces a product.
        fav.toggle("does-not-exist")
        XCTAssertFalse(fav.products(from: WXCatalog.all).map(\.id).contains("does-not-exist"))
        // Toggling off removes it; persistence survives a fresh instance.
        fav.toggle("sat-ir")
        XCTAssertFalse(fav.isFavorite("sat-ir"))
        XCTAssertTrue(WXFavorites().isFavorite("prog-sfc"), "favorites persist across launches")
    }

    // MARK: freshness (update button)

    func testFreshnessThresholdsByCategoryCadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ min: Double) -> Date { now.addingTimeInterval(-min * 60) }
        // Satellite budget 20 min: <20 fresh, 20–40 aging, ≥40 stale.
        XCTAssertEqual(WXFreshness.of(category: .satellite, fetchedAt: age(5), now: now), .fresh)
        XCTAssertEqual(WXFreshness.of(category: .satellite, fetchedAt: age(25), now: now), .aging)
        XCTAssertEqual(WXFreshness.of(category: .satellite, fetchedAt: age(60), now: now), .stale)
        // Prog charts budget 360 min: a 2-hour-old prog is still fresh (slow cadence).
        XCTAssertEqual(WXFreshness.of(category: .progs, fetchedAt: age(120), now: now), .fresh)
        // Never fetched → unknown.
        XCTAssertEqual(WXFreshness.of(category: .winds, fetchedAt: nil, now: now), .unknown)
    }

    func testFreshnessAggregateWorstKnownWins() {
        XCTAssertEqual(WXFreshness.aggregate([]), .unknown)
        XCTAssertEqual(WXFreshness.aggregate([.unknown, .unknown]), .unknown)
        XCTAssertEqual(WXFreshness.aggregate([.fresh, .unknown]), .fresh)     // unknown ignored if any cached
        XCTAssertEqual(WXFreshness.aggregate([.fresh, .aging]), .aging)
        XCTAssertEqual(WXFreshness.aggregate([.fresh, .aging, .stale]), .stale)
    }

    func testUrlCategoryMapsEveryVariantNotJustDefault() {
        // A non-default variant (winds-aloft FL300 / +12 h) maps to its category — so freshness/update can
        // reflect the specific altitude the pilot actually cached, not only the default FL050.
        let winds = WXCatalog.all.first { $0.id == "winds-wafs" }!
        XCTAssertEqual(WXCatalog.urlCategory[winds.url(a: 4, b: 1)], .winds)
        // Every product's default url is categorized too.
        for p in WXCatalog.all {
            XCTAssertEqual(WXCatalog.urlCategory[p.url()], p.category, "\(p.id) default url uncategorized")
        }
        // More variant entries than products (multi-axis products expand).
        XCTAssertGreaterThan(WXCatalog.urlCategory.count, WXCatalog.all.count)
    }
}
