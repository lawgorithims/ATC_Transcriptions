import XCTest

/// The national avoid map downloaded the way a pilot does it, from the REAL hosted catalog: Settings ›
/// Downloads › Where not to go, every band fetched, verified and installed, and the map then saying it
/// covers the contiguous US.
///
/// OPT-IN: it moves about 1.5 GB, so it skips unless the runner's environment has AVOID_DOWNLOAD_E2E=1
/// (`TEST_RUNNER_AVOID_DOWNLOAD_E2E=1 xcodebuild test-without-building …`). Run it after every publish:
/// `lz/avoid/publish.py --verify` proves the files answer; this proves the APP can use them.
final class AvoidDownloadUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AVOID_DOWNLOAD_E2E"] == "1",
                          "opt-in: TEST_RUNNER_AVOID_DOWNLOAD_E2E=1 downloads the national map (~1.5 GB)")
    }

    func testTheHostedMapDownloadsAndInstallsEveryBand() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets", "--open-settings"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

        let link = el("settings-cat-downloads")
        XCTAssertTrue(link.waitForExistence(timeout: 60), "Settings → Charts & downloads could not be reached")
        link.tap()
        // The section sits below the chart layers; a List only builds the rows it has scrolled to.
        let download = el("downloads-avoid-download")
        for _ in 0..<8 where !download.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(download.exists, "no download button: the hosted catalog was not read")
        XCTAssertTrue(download.label.contains("GB") || download.label.contains("MB"),
                      "the button does not say how much it will fetch: \(download.label)")
        download.tap()
        let metered = el("downloads-avoid-download-metered")      // the Wi-Fi-only policy held it back
        if metered.waitForExistence(timeout: 5) { metered.tap() }

        let installed = el("downloads-avoid-installed")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Installed · built'"),
                                             object: installed)
        let result = XCTWaiter().wait(for: [done], timeout: 1_800)
        XCTAssertEqual(result, .completed, "the map never finished installing; it says \"\(installed.label)\"")
        XCTAssertFalse(el("downloads-avoid-update").exists, "every band installed, yet it offers more to fetch")
    }
}
