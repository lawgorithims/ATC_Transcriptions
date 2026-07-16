import XCTest

/// End-to-end proof that the plate-on-map opacity ACTUALLY fades the plate (the regression the pilot hit
/// twice) AND that the new plate menu works. The decisive check: overlay a black-and-white KBOS plate on
/// the COLORED VFR sectional, open the plate menu from the plate's corner gear, swing opacity to the
/// floor, and assert the sectional's COLOR shows through — mean color saturation under the plate jumps.
/// A B&W plate is ~zero saturation; the sectional's tan/green/blue is unmistakable, so this can't pass
/// unless the map is genuinely visible through the faded plate.
final class PlateOverlayUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testPlateMenuOpacityRevealsColoredVFRUnderneath() {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "--chart-layer", "vfr",
                                "--preview-plate", "KBOS", "00058IL4R.PDF"]
        app.launch()

        // A location prompt may cover the map on a fresh install. Dismiss it via Springboard directly.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        // The gear button riding the plate's top-right corner appears once the plate is overlaid.
        let gear = app.buttons["plate-settings-button"]
        XCTAssertTrue(gear.waitForExistence(timeout: 45), "plate overlay never appeared — download failed?")

        // Wait for the VFR sectional tiles to render: poll an OFF-PLATE region (right edge) until it
        // shows the sectional's color. Bounded (Power of 10).
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

        // Open the plate menu from the plate's corner gear; the opacity slider lives in the menu (in
        // normal screen space — no MapKit gesture conflict). Swing it to the 0.15 floor.
        gear.tap()
        let slider = app.sliders["plate-opacity-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "plate menu / opacity slider did not appear")
        slider.adjust(toNormalizedSliderPosition: 0.0)
        sleep(2)                                             // the overlay rebuilds at the new alpha
        let shotFaded = app.screenshot()
        add(XCTAttachment(screenshot: shotFaded))
        let satFaded = Self.meanSaturation(shotFaded.image, band: Self.plateBand)
        print("DIAG satDefault:", satDefault, "satFaded:", satFaded)

        // THE check: color from the VFR chart is visible through the faded plate. An opaque plate that
        // ignores the slider (both prior regressions) leaves the band's saturation unchanged.
        XCTAssertGreaterThan(satFaded, satDefault + 0.03,
                             "VFR color did not show through the faded plate (default \(satDefault), faded \(satFaded))")

        // Invert colours — toggles without crashing (the inverted page renders off-main).
        app.buttons["plate-menu-invert"].tap()
        sleep(1)

        // Hide the plate — plate + gear + menu all clear.
        app.buttons["plate-menu-hide"].tap()
        XCTAssertTrue(waitGone(gear, timeout: 5), "plate did not clear after Hide plate")
    }

    // MARK: sampling

    /// Center of the overlaid plate (the plate is map-focused after --preview-plate).
    private static let plateBand = CGRect(x: 0.38, y: 0.36, width: 0.24, height: 0.20)
    /// Off-plate map — right edge, above the bottom-right performance widget, below the top bars.
    private static let offPlateBand = CGRect(x: 0.88, y: 0.55, width: 0.10, height: 0.12)

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
