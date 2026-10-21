import XCTest
@testable import ATCTranscribe

/// What ships INSIDE the binary — the floor every device starts from and the only data a first
/// launch with no signal has.
///
/// These assert the artifact, not the installer. `NavDataUpdateTests` covers what happens to a
/// candidate database; nothing covered what we actually built into the app, which is how `cifp.sqlite`
/// shipped at cycle 2607 and was still there 76 days after it expired — the red "2 datasets have
/// expired" banner on a clean install, in a build being prepared for a public beta.
final class BundledNavDataTests: XCTestCase {

    private func meta(_ d: NavDataUpdate.Dataset) throws -> [String: String] {
        let url = try XCTUnwrap(d.bundledURL, "\(d.rawValue) is not in the app bundle at all")
        let m = NavDataUpdate.meta(url)
        XCTAssertFalse(m.isEmpty, "\(d.rawValue) carries no provenance")
        return m
    }

    private func date(_ iso: String) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }

    func testEveryBundledDatasetCanBeDated() throws {
        for d in NavDataUpdate.Dataset.allCases {
            let m = try meta(d)
            XCTAssertFalse((m["cycle"] ?? "").isEmpty, "\(d.rawValue) has no cycle")
            let eff = m["effective"] ?? ""
            XCTAssertNotNil(date(eff),
                            "\(d.rawValue) effective=\(eff) is not an ISO date — every staleness "
                            + "decision in the app keys off this field")
        }
    }

    /// ⚠️ THE DIRECTION NOTHING GUARDS.
    ///
    /// `activeURL` re-checks `isNotYetEffective` on the INSTALLED database, so a downloaded cycle
    /// cannot go live early. It then falls through to `d.bundledURL` **unconditionally** — the bundle
    /// is never date-checked, because it was never supposed to be ahead of anything. But the FAA
    /// posts each cycle weeks early, and "refresh the bundled databases before we submit" is exactly
    /// the moment someone grabs the next cycle sitting right there on the server. The app would then
    /// serve procedures that are not legal yet and call them current, with no banner, no refusal and
    /// nothing in the UI to notice — strictly worse than shipping stale data, which at least
    /// announces itself.
    ///
    /// This can only fail if someone bundles a future cycle, so it never goes red on its own.
    func testNoBundledDatasetIsEffectiveInTheFuture() throws {
        for d in NavDataUpdate.Dataset.allCases {
            let url = try XCTUnwrap(d.bundledURL)
            let m = try meta(d)
            XCTAssertFalse(NavDataUpdate.isNotYetEffective(url),
                           "bundled \(d.rawValue) is cycle \(m["cycle"] ?? "?"), effective "
                           + "\(m["effective"] ?? "?") — it has not taken effect. The bundle "
                           + "is served without a date check, so this would be presented as current. "
                           + "Bundle the cycle in force and stage the next one "
                           + "(publish_nav.py --stage-next) instead.")
        }
    }

    /// And the other direction, with slack. A bundle goes out of date on its own every 28 days and
    /// that is normal between releases, so this does not demand freshness — it demands that the gap
    /// stay inside one extra cycle. At 76 days past expiry (two full cycles plus) the app is not
    /// "slightly behind", it is shipping data a pilot must not brief from.
    func testNoBundledDatasetIsMoreThanOneExtraCycleStale() throws {
        let slack: TimeInterval = 56 * 24 * 3600          // two 28-day cycles past the expiry date
        for d in NavDataUpdate.Dataset.allCases {
            let m = try meta(d)
            guard let exp = m["expires"], let expired = date(exp) else { continue }
            let over = Date().timeIntervalSince(expired)
            XCTAssertLessThan(over, slack,
                              "bundled \(d.rawValue) (cycle \(m["cycle"] ?? "?")) expired \(exp), "
                              + "\(Int(over / 86400)) days ago. Rebuild it — ios/Tools/build_\(d.rawValue).py "
                              + "— before shipping; a clean install shows the expiry banner on first launch.")
        }
    }

    /// The bundle has to pass the same corpus checks a DOWNLOAD must pass. A truncated or
    /// half-written file committed by accident would otherwise be caught only on a device.
    func testTheBundledDatabasesPassTheirOwnInvariants() throws {
        for d in NavDataUpdate.Dataset.allCases {
            let url = try XCTUnwrap(d.bundledURL)
            // `allowNotYetEffective` is irrelevant here (the test above covers that) and
            // `isOlderThanBundle` compares a candidate against the bundle, which IS the bundle — so
            // this is the corpus and openability half of `verify`, which is the half that matters.
            let rejection = NavDataUpdate.verify(url, as: d, allowNotYetEffective: true)
            XCTAssertTrue(rejection == nil || rejection == .olderThanBundle,
                          "the bundled \(d.rawValue) would be REFUSED as a download: "
                          + "\(rejection?.reason ?? "")")
        }
    }
}
