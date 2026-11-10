import XCTest

/// The source frames for App Store **promotional artwork** — not screenshots of the app.
///
/// # Why this is not `AppStoreScreenshotTests`
///
/// A store screenshot is the app as it ships: portrait, chrome and all, at an exact device size.
/// Featuring artwork is the opposite job. Apple lays its own title and editorial text over it,
/// crops it to several aspect ratios nobody here chooses, and prohibits a logo, a tagline, a URL
/// and any hardware or device frame. So what it wants is a wide, calm, chrome-free picture of the
/// thing the app is about, which for an electronic flight bag is the chart with the flying on it.
///
/// # Two frames, because they sell different things
///
/// **Enroute** is the whole panel working at once: the filed route, radar cells across it, ADS-B
/// traffic, the flown track, and the glide footprint the aeroplane could still reach if the engine
/// stopped. **Approach** is the one capability a pilot recognises instantly — the approach plate
/// itself georeferenced onto the moving map, with its published fixes flown as the active route.
///
/// # What every frame here does differently
///
///  * **Landscape**, because the artwork is cropped to 2.33:1 at its widest and width is the only
///    dimension that survives. ⚠️ The app lays out PORTRAIT whatever the device does, even when
///    rotated before launch, so the frame arrives a quarter turn off and `Tools/promo_capture.sh`
///    turns it back. Do not "fix" that by testing the framebuffer's width against its height — the
///    framebuffer IS landscape while its contents are not, which passed a sideways frame once.
///  * **Framed by the aeroplane, not by arguments.** `--chart-center`/`--chart-span` look exactly
///    right and are read by `ChartMapView` alone, which is the classic MKMapView engine; the app
///    defaults to MapLibre and ignores them. Passing them produced the whole United States at globe
///    zoom with "Zoom in to load the chart here" across it.
///  * **Everything staged offline**, so the frame is identical every run and no live poll can land
///    on it mid-shutter. Traffic and the flown track had no seam until this artwork needed them.
///
/// Opt-in:
///     TEST_RUNNER_PROMO_ART=1 xcodebuild test-without-building … \
///         -only-testing:ATCTranscribeUITests/PromoArtCaptureTests
/// `Tools/promo_capture.sh` arranges the simulator and the export.
final class PromoArtCaptureTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var enabled: Bool { ProcessInfo.processInfo.environment["PROMO_ART"] == "1" }

    /// The whole panel working at once, at altitude.
    func testCaptureTheEnrouteFrame() throws {
        try XCTSkipUnless(enabled, "opt-in: TEST_RUNNER_PROMO_ART=1 regenerates the artwork sources")
        try shoot(named: "promo-chart-landscape", arguments: [
            "--demo-flightplan",        // KBOS→KORD via ALB SYR BUF ERI DJB OBK — the route line
            "--demo-storms",            // radar cells + convective, live pollers suppressed
            "--demo-hazards",           // EONET events on the same corridor
            "--demo-traffic",           // seeded ADS-B contacts, both live feeds held off
            "--demo-track",             // the flown trail behind the aeroplane
            "-atc.map.lzEnergy", "YES", // the glide footprint
            // ⚠️ FL390, AND THE REASON IS THE OPPOSITE OF THE OBVIOUS ONE. 16,000 ft was tried
            // first, on the theory that a flight-level footprint would be wider than the frame. It
            // is not: the map sits a few hundred miles across, so 14,500 ft of height drew a ring
            // barely larger than the ownship symbol — present, and unreadable. Reach scales with
            // height, so the flight levels are what make it big enough to see.
            "--hold-ownship", "42.5", "-77.0", "39000", "270", "300",
        ])
    }

    /// The approach being flown: the plate on the map, its published fixes as the active route.
    func testCaptureTheApproachFrame() throws {
        try XCTSkipUnless(enabled, "opt-in: TEST_RUNNER_PROMO_ART=1 regenerates the artwork sources")
        try shoot(named: "promo-approach-landscape", arguments: [
            // The plate itself, auto-aligned onto the chart. 00026IL8L is KATL's ILS OR LOC RWY 08L
            // and it IS in the georeference table — an un-georeferenced plate has no corners to pin
            // to and would simply not draw, which looks identical to the plate failing to load.
            "--preview-plate", "KATL", "00026IL8L.PDF",
            "--preview-proc", "KATL",   // the coded approach, drawn as a procedure
            "--demo-approach",          // LARII JAAJJ BAZAR SCHEL filed as the active route
            "--demo-traffic",
            "--demo-track",
            "-atc.map.lzEnergy", "YES",
            // On final between BAZAR and SCHEL, on the 095 course, at the published 3,000 ft.
            "--hold-ownship", "33.649", "-84.60", "3000", "95", "150",
        ])
    }

    // MARK: - the shot itself

    private func shoot(named name: String, arguments: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets"] + arguments

        // ⚠️ ROTATE BEFORE LAUNCH. Rotating after it was up letterboxed the app: the framebuffer
        // turned landscape while the window stayed portrait and sat in the middle of it, and the
        // exported frame had the tab bar running up the left edge.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        app.launch()

        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 60),
                      "the map never came up — nothing worth shooting")

        // Setting the orientation is a request, not a guarantee; poll the app's own frame.
        var landed = false
        for _ in 0..<20 {                                   // bounded: ~20 s
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            if app.frame.width > app.frame.height { landed = true; break }
        }
        XCTAssertTrue(landed, "the app is still \(app.frame.size) after 20 s of asking for landscape")

        if app.buttons["nrst-end"].exists { app.buttons["nrst-end"].tap() }

        // Close every floating widget there is, whatever it is. Matched on the identifier prefix so
        // a widget added later is closed too, and re-queried each time because closing one re-lays
        // out the rest and a snapshot taken before the first tap goes stale.
        for _ in 0..<8 {                                    // bounded: more than the widget kinds
            let closes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                          "widget-close-"))
            guard let next = closes.allElementsBoundByIndex.first(where: { $0.isHittable }) else { break }
            next.tap()
            Thread.sleep(forTimeInterval: 0.4)
        }

        // ⚠️ THERE HAS TO BE A CHART IN FRAME, and the app says plainly when there is not.
        let noChart = NSPredicate(format: "label BEGINSWITH 'Zoom in to load' OR "
                                  + "label BEGINSWITH 'Pan and zoom in to load'")
        var charted = false
        for _ in 0..<45 {                                   // bounded: ~45 s
            if app.staticTexts.matching(noChart).count == 0 { charted = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(charted, "the map still says it has no chart to show after 45 s")

        // ⚠️ A HALF-DRAWN CHART IS THE DEFECT THAT PASSES. The check above goes green as soon as
        // ANY tile lands, and a frame shot then has a crisp left half and a blurry right one —
        // lower-zoom tiles still standing in for detail that has not arrived. That shipped once. A
        // fresh simulator has no chart cache at all, so every tile comes over the network here.
        Thread.sleep(forTimeInterval: 75)

        // The attachment comes out portrait even though the app is landscape: `app.screenshot()`
        // captures the device framebuffer, which stays in the device's physical orientation.
        // Asserting on its size rather than `app.frame` reports "the rotation did not take" when it
        // did, twice. `Tools/promo_capture.sh` turns the exported PNG the right way up.
        let shot = app.screenshot()
        XCTAssertGreaterThan(app.frame.width, app.frame.height,
                             "the app is \(app.frame.size) at the shutter — not landscape")

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
