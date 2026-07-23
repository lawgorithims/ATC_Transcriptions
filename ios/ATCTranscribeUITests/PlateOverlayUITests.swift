import XCTest

/// End-to-end proof that the plate-on-map opacity ACTUALLY fades the plate (the regression the pilot hit
/// twice) AND that the plate menu is REACHABLE. The decisive check: overlay a black-and-white KBOS plate
/// on the COLORED VFR sectional, swing opacity to the floor, and assert the sectional's COLOR shows
/// through — mean color saturation under the plate jumps. A B&W plate is ~zero saturation; the
/// sectional's tan/green/blue is unmistakable, so this can't pass unless the map is genuinely visible
/// through the faded plate.
///
/// Split into three tests deliberately. The opacity check used to open the menu via the corner gear, so
/// when the gear became unreachable (it was drawn UNDER the console chrome, and the LiveATC URL field ate
/// its taps) this file failed at the gear and the safety-critical opacity assertion never ran at all — a
/// layout bug masking a rendering regression. The opacity test now opens the menu with `--plate-menu` and
/// never touches the gear; reachability is asserted separately, by both routes a pilot has.
final class PlateOverlayUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "--chart-layer", "vfr",
                                "--preview-plate", "KBOS", "00058IL4R.PDF"] + extra
        app.launch()
        // A location prompt may cover the map on a fresh install. Dismiss it via Springboard directly.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        return app
    }

    /// The unoccludable route: the console strip lives INSIDE the chrome, so no map geometry can hide it.
    func testPlateMenuIsReachableFromTheConsoleStrip() {
        let app = launch([])
        let strip = app.buttons["plate-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 45),
                      "no 'Plate on map' strip — the pilot has no persistent, unoccludable way in")
        strip.tap()
        XCTAssertTrue(app.otherElements["plate-menu"].waitForExistence(timeout: 5),
                      "the console strip must open the plate menu")
        XCTAssertTrue(app.sliders["plate-opacity-slider"].exists, "menu should carry the opacity slider")
    }

    /// The on-map route: the gear must sit BELOW the console chrome, and tapping it must actually open the
    /// menu. The oracle is the runtime chrome frame plus the menu appearing — never `isHittable`, which
    /// reported TRUE for a button buried under the InputBar whose taps went to a text field.
    func testCornerGearSitsBelowTheConsoleChromeAndOpensTheMenu() {
        let app = launch([])
        let gear = app.buttons["plate-settings-button"]
        XCTAssertTrue(gear.waitForExistence(timeout: 45), "plate overlay never appeared — download failed?")

        // Measure the chrome at RUNTIME rather than hard-coding a height: that is the same mistake the
        // shipped code made. The input strip is the tallest routinely-expanded piece of top chrome.
        let inputBar = app.descendants(matching: .any).matching(identifier: "input-bar").firstMatch
        if inputBar.exists {
            XCTAssertGreaterThanOrEqual(gear.frame.minY, inputBar.frame.maxY,
                                        "the gear is drawn under the console chrome, where its taps are eaten")
        }
        gear.tap()
        XCTAssertTrue(app.otherElements["plate-menu"].waitForExistence(timeout: 5),
                      "tapping the corner gear must open the plate menu")
    }

    func testPlateMenuOpacityRevealsColoredVFRUnderneath() {
        // --plate-menu opens the menu directly, so this safety-critical check never routes through the
        // gear's geometry. (The gear is hidden by construction while the menu is open.)
        let app = launch(["--plate-menu"])

        // The menu is already open (--plate-menu), so the opacity slider is the entry point.
        let slider = app.sliders["plate-opacity-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 20), "plate menu / opacity slider did not appear")

        // Wait for the VFR sectional tiles to render: poll an OFF-PLATE region until it shows the
        // sectional's color. Bounded (Power of 10).
        var tilesReady = false, polls = 0
        while polls < 30 {                                    // ≤ 30 × 5 s for the ~50 MB pack
            if Self.meanSaturation(app.screenshot().image, band: Self.offPlateBand) > 0.05 { tilesReady = true; break }
            sleep(5); polls += 1
        }
        XCTAssertTrue(tilesReady, "VFR sectional tiles never rendered — cannot run the see-through check")

        // Baseline at the default 0.7 opacity.
        let shotDefault = app.screenshot()
        add(XCTAttachment(screenshot: shotDefault))
        let satDefault = Self.meanSaturation(shotDefault.image, band: Self.plateBand)

        // Swing the opacity to its 0.15 floor.
        slider.adjust(toNormalizedSliderPosition: 0.0)
        sleep(2)                                             // the overlay rebuilds at the new alpha
        let shotFaded = app.screenshot()
        add(XCTAttachment(screenshot: shotFaded))
        let satFaded = Self.meanSaturation(shotFaded.image, band: Self.plateBand)

        // THE check: color from the VFR chart is visible through the faded plate. An opaque plate that
        // ignores the slider (both prior regressions) leaves the band's saturation unchanged.
        XCTAssertGreaterThan(satFaded, satDefault + 0.03,
                             "VFR color did not show through the faded plate (default \(satDefault), faded \(satFaded))")

        // Invert colours — toggles without crashing (the inverted page renders off-main). Guarded: an
        // unguarded tap on a missing element dies with an unmatched-element crash rather than a readable
        // assertion, because continueAfterFailure is false.
        let invert = app.buttons["plate-menu-invert"]
        XCTAssertTrue(invert.waitForExistence(timeout: 5), "invert-colours control missing from the plate menu")
        invert.tap()
        sleep(1)

        // Hide the plate — plate + strip + menu all clear.
        let hide = app.buttons["plate-menu-hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "hide-plate control missing from the plate menu")
        hide.tap()
        XCTAssertTrue(waitGone(app.buttons["plate-strip"], timeout: 5), "plate did not clear after Hide plate")
    }

    // MARK: sampling

    /// Center of the overlaid plate (the plate is map-focused after --preview-plate).
    private static let plateBand = CGRect(x: 0.38, y: 0.36, width: 0.24, height: 0.20)
    /// Off-plate map — LEFT edge, below the top bars and above the transcript widget.
    ///
    /// This was the right edge at y 0.55 until build 77's map zoom/center control bar landed on top of
    /// it: the band then averaged the grey controls with pale chart and measured 0.049 against the 0.05
    /// floor, so the check reported "tiles never rendered" while the sectional was plainly drawn. The
    /// left edge is map-only here and measures ~0.20 — 4× the floor, so UI chrome can't tip it again.
    private static let offPlateBand = CGRect(x: 0.005, y: 0.28, width: 0.05, height: 0.22)

    /// Mean color saturation (0…1) of a fractional band: mean of (max−min)/255 over RGB, strided.
    /// B&W content ≈ 0; the VFR sectional ≫ 0.
    private static func meanSaturation(_ image: UIImage, band: CGRect) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 8, h > 8 else { return 0 }
        let rect = CGRect(x: Int(Double(w) * band.minX), y: Int(Double(h) * band.minY),
                          width: Int(Double(w) * band.width), height: Int(Double(h) * band.height))
        guard let crop = cg.cropping(to: rect) else { return 0 }
        let cw = crop.width, ch = crop.height
        var data = [UInt8](repeating: 0, count: cw * ch * 4)
        guard let ctx = CGContext(data: &data, width: cw, height: ch, bitsPerComponent: 8,
                                  bytesPerRow: cw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        var total = 0.0, count = 0
        let stride = 8
        var y = 0
        while y < ch {
            assert(y <= ch, "row bound")
            var x = 0
            while x < cw {
                assert(x <= cw, "col bound")
                let i = (y * cw + x) * 4
                let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
                total += (max(r, g, b) - min(r, g, b)) / 255.0
                count += 1
                x += stride
            }
            y += stride
        }
        return count > 0 ? total / Double(count) : 0
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {                            // bounded poll (Power of 10)
            if !el.exists { return true }
            usleep(200_000)
        }
        return !el.exists
    }
}
