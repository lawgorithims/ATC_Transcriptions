import XCTest

/// End-to-end check that the plate-on-map opacity slider VISIBLY changes the overlay — the exact
/// regression shipped in build 50 (the slider moved but the plate never faded, because MapKit's
/// cached overlay tiles ignored `setNeedsDisplay()`). Launches with a georeferenced KBOS ILS plate
/// auto-overlaid (`--preview-plate`), drags the slider from 0.7 to its minimum, and asserts the
/// map's center region — covered by the near-white plate — actually got darker.
final class PlateOverlayUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testOpacitySliderVisiblyFadesThePlate() {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "--preview-plate", "KBOS", "00058IL4R.PDF"]
        app.launch()

        // A location prompt may cover the map on a fresh install. Dismiss it via Springboard
        // directly (no blind app.tap() — that would tap-to-identify the map and open a panel).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        // The control bar appears once the plate PDF is downloaded + rendered + overlaid.
        let slider = app.sliders["plate-opacity-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 45), "plate overlay never appeared — download failed?")
        sleep(3)                                        // let map tiles + overlay settle

        sleep(3)                                        // let the plate overlay settle
        let shotBefore = app.screenshot()
        add(XCTAttachment(screenshot: shotBefore))
        let before = Self.plateBandLuminance(shotBefore.image)
        slider.adjust(toNormalizedSliderPosition: 0.0)  // opacity 0.7 → 0.1
        sleep(2)                                        // the overlay rebuilds at the new alpha
        let shotAfter = app.screenshot()
        add(XCTAttachment(screenshot: shotAfter))
        let after = Self.plateBandLuminance(shotAfter.image)

        // THE regression: in build 50 the slider moved but the plate never changed (this band was
        // pixel-identical before/after — a delta of 0.0). A working slider materially changes the band
        // as the plate fades and the base map shows through. Direction depends on the plate's content vs
        // the map underneath (dark chart detail on white can read brighter as it fades), so assert on
        // magnitude, not sign — the fix turns a 0.0 delta into a clearly non-zero one.
        XCTAssertGreaterThan(abs(after - before), 0.02,
                             "opacity slider had no visible effect (before \(before), after \(after))")
    }

    /// Mean luminance (0…1) of the upper-center band of a screenshot — squarely on the overlaid plate,
    /// below the dark header bar and above the bottom floating widgets (`--reset-widgets` pins those to
    /// the corners). Downsamples by striding; bounded loops (Power of 10).
    private static func plateBandLuminance(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 8, h > 8 else { return 0 }
        let rect = CGRect(x: Int(Double(w) * 0.30), y: Int(Double(h) * 0.26),
                          width: Int(Double(w) * 0.40), height: Int(Double(h) * 0.24))
        guard let crop = cg.cropping(to: rect) else { return 0 }
        let cw = crop.width, ch = crop.height
        var data = [UInt8](repeating: 0, count: cw * ch * 4)
        guard let ctx = CGContext(data: &data, width: cw, height: ch, bitsPerComponent: 8,
                                  bytesPerRow: cw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        var total = 0.0, count = 0
        let stride = 16                                  // sample every 16th pixel — plenty for a mean
        var y = 0
        while y < ch {
            assert(y <= ch, "row bound")
            var x = 0
            while x < cw {
                assert(x <= cw, "col bound")
                let i = (y * cw + x) * 4
                total += (0.299 * Double(data[i]) + 0.587 * Double(data[i + 1]) + 0.114 * Double(data[i + 2])) / 255.0
                count += 1
                x += stride
            }
            y += stride
        }
        return count > 0 ? total / Double(count) : 0
    }
}
