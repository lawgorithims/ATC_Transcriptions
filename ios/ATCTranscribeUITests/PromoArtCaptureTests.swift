import XCTest

/// The source frame for App Store **promotional artwork** — not a screenshot of the app.
///
/// # Why this is not `AppStoreScreenshotTests`
///
/// A store screenshot is the app as it ships: portrait, chrome and all, at an exact device size.
/// Featuring artwork is the opposite job. Apple lays its own title and editorial text over it,
/// crops it to several aspect ratios nobody here chooses, and prohibits a logo, a tagline, a URL
/// and any hardware or device frame. So what it wants is a wide, calm, chrome-free picture of the
/// thing the app is about, which for an electronic flight bag is the chart.
///
/// This shoots exactly one frame for `Tools/make_promo_art.py` to crop. Three things about it
/// differ from every other capture in this suite, and each is the whole point:
///
///  * **Landscape.** The portrait set is 2064 px across; the same iPad in landscape is 2752. The
///    artwork is cropped to 2.33:1 at its widest, so every portrait pixel above the crop is thrown
///    away and the width is all that survives. Shooting portrait and cropping cost a 3.1x upscale
///    on the 5244-wide targets.
///  * **Framed by `--chart-center` / `--chart-span`, not by where the aeroplane happens to be.**
///    The first attempt at this artwork had a dark wedge across one corner, which reads as missing
///    data. It is the edge of the DOWNLOADED CHART CACHE, not a chart boundary: the shot was
///    zoomed out past what the simulator had cached. A tight span well inside the cached New York
///    sectional has chart in every corner.
///  * **Every floating widget closed.** They are good UI and they are chrome; each one shrinks the
///    rectangle the artwork can be cut from.
///
/// Opt-in, because it is only ever run to regenerate artwork:
///     TEST_RUNNER_PROMO_ART=1 xcodebuild test-without-building … \
///         -only-testing:ATCTranscribeUITests/PromoArtCaptureTests
/// `Tools/promo_capture.sh` arranges the simulator, the position and the export.
///
/// # ⚠️ STATUS: THIS DOES NOT YET PRODUCE A USABLE FRAME
///
/// It is committed because it fails HONESTLY — it asserts its way out rather than exporting
/// another picture of an EFB nobody is flying — and because three findings cost a run each and
/// should not be rediscovered. The shipping artwork still comes from the portrait screenshot set
/// (`Tools/make_promo_art.py`), which does show the app in use.
///
///  1. **`--chart-center` / `--chart-span` do nothing.** Read by `ChartMapView` only, which is the
///     classic MKMapView engine; the app defaults to MapLibre. Fixed by framing from the GPS fix
///     instead. Teaching MapLibre to honour them is the clean fix, and is app code.
///  2. **Rotating after launch letterboxes the app.** The framebuffer turns, the window does not,
///     and the frame comes out with the tab bar running up the left edge. Fixed by rotating before
///     `app.launch()`. Related: `app.screenshot()` captures the framebuffer, so asserting on its
///     size rather than `app.frame` reports "the rotation did not take" when it did.
///  3. **OPEN — the location track never reaches the app.** `simctl location start` plus
///     `privacy grant location-always`, exactly as `Tools/appstore_screenshots.sh` does it and
///     that script works, yet the map stays at continental zoom saying it has no chart. Until this
///     is understood there is no landscape frame. Suspect the ordering around the erase/boot the
///     capture script does, or the grant landing before the app exists on a freshly erased device.
final class PromoArtCaptureTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testCaptureTheChartFrameForPromotionalArtwork() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO_ART"] == "1",
                          "opt-in: TEST_RUNNER_PROMO_ART=1 regenerates the promotional artwork source")

        // ⚠️ NO `--chart-center` / `--chart-span` HERE, THOUGH THEY LOOK PERFECT FOR THIS.
        // They are read by `ChartMapView.launchCenter/launchSpan` and NOWHERE ELSE, and
        // `ChartMapView` is the classic MKMapView engine. The app defaults to MapLibre, which
        // ignores them completely. Passing them produced a frame of the whole United States at
        // globe zoom with "Zoom in to load the chart here" across it — no chart, nothing in use.
        //
        // The framing comes from the aeroplane instead: `Tools/promo_capture.sh` flies a track with
        // `simctl location`, the map follows the fix, and that is what put the good portrait shots
        // over New York at a sensible enroute zoom.
        // The FEATURES are the picture. A bare chart is a chart; what sells an EFB is the chart with
        // the flying on it — the filed route, weather it has to get through, and an aeroplane on a
        // track. These stage all of that offline, so the frame is identical every run:
        //   --demo-flightplan  KBOS→KORD via ALB SYR BUF ERI DJB OBK — the route line
        //   --demo-storms      radar cells + convective, live pollers suppressed so they survive
        //   --demo-hazards     EONET events on the same corridor
        //   --hold-ownship     position, altitude, track and speed with no GPS at all, which is the
        //                      blocker that stopped the last attempt. 42.5/-77.0 is the position
        //                      --demo-storms' own documentation suggests, on the demo corridor.
        //
        //   --demo-traffic     seeded ADS-B contacts, both live feeds held off. This seam did not
        //                      exist until this artwork needed it: traffic was the only layer that
        //                      could not be staged offline, so every staged frame had an empty sky.
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "--demo-flightplan", "--demo-storms", "--demo-hazards",
                                "--demo-traffic",
                                // The glide footprint. ⚠️ `showLZEnergy` is explicitly NOT
                                // developer-gated — its own declaration says so, because the
                                // emergency button arms it for every pilot — so unlike the
                                // off-field SHADING (`offFieldLayerAvailable`, diagnostics-only)
                                // this is a feature a buyer actually gets. Advertising the shading
                                // would be advertising something nobody can see.
                                "-atc.map.lzEnergy", "YES",
                                // ⚠️ FL390, AND THE REASON IS THE OPPOSITE OF THE OBVIOUS ONE.
                                // 16,000 ft was tried first, on the theory that a flight-level
                                // footprint would be wider than the frame. It is not: the map sits
                                // at a few hundred miles across, so 14,500 ft of height drew a ring
                                // barely larger than the ownship symbol — present, and unreadable.
                                // Reach scales with height, so the flight levels are what make it
                                // big enough to see.
                                "--hold-ownship", "42.5", "-77.0", "39000", "270", "300"]

        // ⚠️ ROTATE BEFORE LAUNCH. Rotating after it was up letterboxed the app: the framebuffer
        // turned landscape while the window stayed portrait and sat in the middle of it with black
        // down both sides, and the exported frame had the tab bar running vertically up the left
        // edge. Starting the device landscape gives the scene a landscape size to lay out into.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)

        app.launch()

        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        XCTAssertTrue(app.buttons["map-zoom-in"].waitForExistence(timeout: 60),
                      "the map never came up — nothing worth shooting")

        // ⚠️ SETTING `XCUIDevice.orientation` IS A REQUEST, NOT A GUARANTEE, so re-assert it and
        // poll the app's own frame until it has actually turned.
        var landed = false
        for _ in 0..<20 {                                   // bounded: ~20 s
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            if app.frame.width > app.frame.height { landed = true; break }
        }
        XCTAssertTrue(landed, "the app is still \(app.frame.size) after 20 s of asking for "
                      + "landscape — a portrait frame is no better than the one it replaces")

        // ⚠️ THERE HAS TO BE A CHART IN FRAME, and the app says plainly when there is not. The
        // first landscape attempt produced the whole United States at globe zoom with "Zoom in to
        // load the chart here" sitting in the middle of it: a picture of an EFB not being used.
        // The run passed, because nothing was checking. Wait for the map to stop saying it.
        let noChart = NSPredicate(format: "label BEGINSWITH 'Zoom in to load' OR "
                                  + "label BEGINSWITH 'Pan and zoom in to load'")
        var charted = false
        for _ in 0..<45 {                                   // bounded: ~45 s of tile loading
            if app.staticTexts.matching(noChart).count == 0 { charted = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(charted, "the map still says it has no chart to show after 45 s — the "
                      + "location track is not reaching the app, so it never left continental zoom")

        // NRST persists across launches and parks a panel over a third of the screen.
        if app.buttons["nrst-end"].exists { app.buttons["nrst-end"].tap() }

        // Close every floating widget there is, whatever it is. Matching on the identifier prefix
        // rather than naming kinds means a widget added later is closed too, instead of silently
        // appearing in the middle of the artwork a year from now.
        //
        // Re-queried each time: closing one re-lays out the rest, and a snapshot taken before the
        // first tap goes stale — the failure mode is "Element at index N" on a perfectly good run.
        for _ in 0..<8 {                                    // bounded: more than the widget kinds
            let closes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                          "widget-close-"))
            guard let next = closes.allElementsBoundByIndex.first(where: { $0.isHittable }) else { break }
            next.tap()
            Thread.sleep(forTimeInterval: 0.4)
        }

        // ⚠️ A HALF-DRAWN CHART IS THE DEFECT THAT PASSES. The test's own "is there a chart"
        // check goes green as soon as ANY tile lands, and a frame shot then has a crisp left half
        // and a blurry right one — lower-zoom tiles still standing in for the detail that has not
        // arrived. That shipped once. A fresh simulator has no chart cache at all, so every tile in
        // frame comes over the network during this wait; it is long on purpose.
        Thread.sleep(forTimeInterval: 75)

        // ⚠️ THE ATTACHMENT COMES OUT PORTRAIT EVEN THOUGH THE APP IS LANDSCAPE, and that is not a
        // bug to fix here. `app.frame` is landscape by now — the loop above will not leave until it
        // is — but `app.screenshot()` captures the device FRAMEBUFFER, which stays in the device's
        // physical orientation. The landscape content is in there, turned a quarter turn. Asserting
        // on the screenshot's own size instead of `app.frame` is simply asserting the wrong
        // surface; it failed here twice saying "the rotation did not take" when it had.
        //
        // `Tools/promo_capture.sh` turns the exported PNG the right way up and checks the result.
        // The glide footprint is the feature most worth showing and the one most likely to decline
        // silently — it refuses on an untrusted position, a missing altitude, a terrain grid it
        // cannot read, or a height below the arrival reserve, and the artwork looks the same for
        // all four. The layer states its reason; read it out rather than guessing from the picture.
        if app.buttons["map-layers-menu"].waitForExistence(timeout: 20) {
            app.buttons["map-layers-menu"].tap()
            let status = app.staticTexts["layers-lz-energy-status"]
            if status.waitForExistence(timeout: 20) {
                print("PROMO-GLIDE-STATUS: \(status.label)")
            } else {
                print("PROMO-GLIDE-STATUS: <no status line — the layer reported nothing>")
            }
            app.buttons["map-layers-menu"].tap()        // close it again before the shutter
            Thread.sleep(forTimeInterval: 3)
        }

        let shot = app.screenshot()
        XCTAssertGreaterThan(app.frame.width, app.frame.height,
                             "the app is \(app.frame.size) at the shutter — not landscape")

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "promo-chart-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
