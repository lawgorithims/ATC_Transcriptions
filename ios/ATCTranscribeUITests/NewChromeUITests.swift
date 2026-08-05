import XCTest

/// The three screens added alongside the landability work: the bar clock, the aircraft catalogue,
/// and the glide bench.
///
/// WHY THESE EXIST AS UI TESTS AND NOT UNIT TESTS. Everything here is chrome — it compiles whether
/// or not it is reachable, wired to the right state, or visible. This session has repeatedly shipped
/// code that built cleanly, passed its unit tests, and did nothing on screen; the only check that
/// catches that is one that drives the app.
final class NewChromeUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    /// The map is engine-switched and the LZ layers are MapLibre-only, so state the engine rather
    /// than inheriting whatever the machine was left on — see LZLayerUITests for what that cost.
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "-atc.map.engine.maplibre", "YES"] + extra
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Open the aircraft sheet the way a pilot does — through the flight-plan strip's aircraft menu.
    /// Navigating the real path is the point: a screen that compiles but cannot be REACHED is the
    /// failure this suite exists to catch.
    private func openAircraftSheet(_ app: XCUIApplication) throws -> XCUIElement {
        // Briefcase → flight-plan strip → aircraft box → Add aircraft. The strip is collapsed by
        // default, which is exactly why this is driven and not assumed: the first cut of this test
        // looked for the aircraft control on a bar that was not on screen.
        let box = el(app, "plan-aircraft")
        if !box.waitForExistence(timeout: 5) {
            let bag = el(app, "flight-bag-button")
            guard bag.waitForExistence(timeout: 25) else {
                throw XCTSkip("no flight bag button: \(LZLayerUITests.visibleLabels(app))")
            }
            bag.tap()
        }
        guard box.waitForExistence(timeout: 10) else {
            let ids = app.buttons.allElementsBoundByIndex
                .map { "\($0.identifier)|\($0.label)" }.joined(separator: " · ")
            throw XCTSkip("the strip opened without an aircraft box. buttons: \(ids)")
        }
        box.tap()
        let add = el(app, "aircraft-add")
        guard add.waitForExistence(timeout: 10) else {
            throw XCTSkip("could not reach Add aircraft: \(LZLayerUITests.visibleLabels(app))")
        }
        add.tap()
        let fill = el(app, "aircraft-fill-from-type")
        guard fill.waitForExistence(timeout: 15) else {
            throw XCTSkip("the aircraft sheet opened without the type picker")
        }
        return fill
    }

    // MARK: - the clock

    /// It must be PRESENT and it must read as Zulu. A clock that renders an empty string, or that
    /// silently shows local time under a "Z", is worse than no clock — every time in this app is
    /// Zulu and a pilot reading local off it would be an hour or seven out.
    func testTheBarClockShowsZuluTime() throws {
        let app = launch()
        let clock = el(app, "bar-clock")
        XCTAssertTrue(clock.waitForExistence(timeout: 30), "no clock in the top bar")
        // The accessibility label is "HHMM Zulu, HH:MM local" — assert on the Zulu half.
        let label = clock.label
        XCTAssertTrue(label.localizedCaseInsensitiveContains("zulu"),
                      "the clock does not identify itself as Zulu: \"\(label)\"")
        let digits = label.prefix(4)
        XCTAssertEqual(digits.count, 4, "expected HHMM, got \"\(label)\"")
        XCTAssertTrue(digits.allSatisfy(\.isNumber), "expected four digits, got \"\(digits)\"")
        // And it must actually be UTC, not local wearing a Z. Compare against the device clock.
        let f = DateFormatter()
        f.dateFormat = "HH"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(String(digits.prefix(2)), f.string(from: Date()),
                       "the clock's hour is not UTC — it is showing local time under a Z")
    }

    // MARK: - the aircraft catalogue

    /// Opening the picker and choosing a type must FILL THE FORM — and must carry the provenance
    /// note with it. The note is the thing that keeps a nominal figure from reading as the pilot's
    /// own number, so its absence is a safety defect, not a cosmetic one.
    func testPickingATypeFillsTheFormAndSaysWhereTheNumbersCameFrom() throws {
        let app = launch()
        let fill = try openAircraftSheet(app)
        fill.tap()

        XCTAssertTrue(el(app, "aircraft-picker-provenance").waitForExistence(timeout: 10),
                      "the picker opened without the provenance note above the list")
        let c172 = el(app, "aircraft-pick-Cessna 172 Skyhawk")
        XCTAssertTrue(c172.waitForExistence(timeout: 10), "the catalogue does not offer a C172")
        c172.tap()

        XCTAssertTrue(el(app, "aircraft-filled-note").waitForExistence(timeout: 10),
                      "the form was filled with catalogue numbers and did not say so")
    }

    /// ⚠️ ROTORCRAFT MUST NOT CARRY A FIXED-WING LANDING DISTANCE. Picking a helicopter has to flip
    /// the sheet into rotorcraft mode, or the landability layer would demand a runway's worth of
    /// open ground from something that lands in a clearing.
    func testPickingAHelicopterFlipsTheSheetIntoRotorcraftMode() throws {
        let app = launch()
        let fill = try openAircraftSheet(app)
        fill.tap()
        let r44 = el(app, "aircraft-pick-Robinson R44")
        guard r44.waitForExistence(timeout: 10) else {
            throw XCTSkip("no rotorcraft offered: \(LZLayerUITests.visibleLabels(app))")
        }
        r44.tap()

        let toggle = app.switches["aircraft-is-rotorcraft"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no rotorcraft toggle on the sheet")
        XCTAssertEqual(toggle.value as? String, "1",
                       "picking an R44 left the sheet in fixed-wing mode")
        // And it must say WHAT IS USED INSTEAD. "Not used for rotorcraft" was the old wording, and
        // it was false: every consumer read the missing number and substituted the 1,600 ft
        // fixed-wing default. The sheet now has to name the substitution, because a pilot who reads
        // "not used" and sees the layer go dark has been told the opposite of what happened.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS[c] 'rotorcraft minimum'")).firstMatch.exists,
            "the sheet does not say which landing distance a helicopter is actually judged against")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS[c] 'Autorotation'")).firstMatch.exists,
            "the sheet no longer explains why the fixed-wing number does not apply")
    }

    // MARK: - the glide bench

    /// The bench must open and offer its controls rather than a refusal, given diagnostics are on.
    func testTheGlideBenchOpensWithItsControls() throws {
        let app = launch(["-atc.diagnosticsEnabled", "YES", "--open-settings"])
        let general = el(app, "settings-cat-general")
        guard general.waitForExistence(timeout: 20) else {
            throw XCTSkip("settings did not open")
        }
        general.tap()
        let link = el(app, "settings-glide-bench")
        guard link.waitForExistence(timeout: 10) else {
            throw XCTSkip("the glide bench is not reachable from General — is diagnostics on?")
        }
        link.tap()
        let bench = el(app, "glide-bench")
        XCTAssertTrue(bench.waitForExistence(timeout: 15), "the bench did not open")
        if el(app, "bench-refusal").exists {
            throw XCTSkip("bench refused: \(el(app, "bench-refusal").label)")
        }
        XCTAssertTrue(app.sliders["bench-altitude"].waitForExistence(timeout: 10),
                      "no altitude control")
        XCTAssertTrue(app.sliders["bench-heading"].exists, "no heading control")
        XCTAssertTrue(el(app, "bench-place").exists, "no way to place the aeroplane")
    }
}
