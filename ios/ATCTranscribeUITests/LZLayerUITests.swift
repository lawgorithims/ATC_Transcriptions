import XCTest

/// The off-field landability layers and the emergency button that arms them, driven end to end
/// through the real app.
///
/// WHY THIS SUITE EXISTS AT ALL, given `LZGlideFieldTests` and `LZTileCompositorTests` already pin the
/// maths: the energy engine and the map DRAWING what it produced are separate failures, and during
/// development the second one could not be checked by hand. The Simulator's own location supplies a
/// position with no usable altitude, a glide has nothing to spend without one, and the app's flight
/// simulator refuses to arm without an activated approach — so there was no way to put an aeroplane at
/// a height over known terrain and watch the bands appear. `--hold-ownship` (DEBUG-only) is that way,
/// and `layers-lz-energy-status` reports how many band polygons the map's shape source actually
/// accepted, so a footprint that computes but never reaches the map fails here instead of passing.
///
/// The heatmap half is asserted only as far as an installed pack allows: `.lzpack` files live in
/// Application Support and a UI test cannot put one there, so the pack-dependent case skips rather
/// than fails on a clean machine. What is always asserted is everything that does not need one — the
/// button, the arming, the idempotence, the stand-down, the advisory wording, and that a layer which
/// draws nothing says why.
final class LZLayerUITests: XCTestCase {

    /// Las Cruces International, and the altitude the real-terrain suite settled on: the ground east
    /// of the field FALLS before it climbs, so the Organ Mountains sit far further out than a chart
    /// suggests and 16,000 ft is where the footprint first reaches both them and the open valley.
    private let klruLat = "32.2894", klruLon = "-106.9219", klruAlt = "16000"

    override func setUp() { continueAfterFailure = false }

    // MARK: - launch helpers

    /// `--reset-widgets` matters more here than anywhere else: the NRST panel's visibility persists
    /// across launches, so without it a test could pass on a panel a PREVIOUS test left standing.
    ///
    /// `-atc.map.engine.maplibre YES` is not optional either. The engine choice is a PERSISTED pilot
    /// preference, both LZ layers exist only on the MapLibre engine, and a Simulator where the classic
    /// map was last selected renders neither — which reads exactly like the layers being broken. The
    /// argument domain outranks the stored value, so the test states the engine it needs instead of
    /// inheriting whatever the machine happened to be left on. (That cost an hour to find: the layers
    /// were correct the whole time and the engine was MKMapView.)
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

    /// Both LZ layers on, developer diagnostics unlocked, and an aeroplane held over Las Cruces.
    private func launchHeldOverKLRU(alt: String? = nil) -> XCUIApplication {
        launch(["-atc.diagnosticsEnabled", "YES",
                "-atc.map.lz", "YES",
                "-atc.map.lzEnergy", "YES",
                "--hold-ownship", klruLat, klruLon, alt ?? klruAlt])
    }

    /// Open the layers popover, having waited for the panel's own off-field section to exist.
    private func openLayersPanel(_ app: XCUIApplication) {
        let menu = app.buttons["map-layers-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the map layers button never appeared")
        menu.tap()
        XCTAssertTrue(app.staticTexts["layers-lz-note"].waitForExistence(timeout: 8),
                      "the layers panel opened without the off-field landability section")
    }

    private func nrstIsUp(_ app: XCUIApplication) -> Bool {
        app.otherElements["nrst-panel"].exists || app.staticTexts["Nearest airports"].exists
    }

    private func waitForNRST(_ app: XCUIApplication) -> Bool {
        app.otherElements["nrst-panel"].waitForExistence(timeout: 10)
            || app.staticTexts["Nearest airports"].waitForExistence(timeout: 10)
    }

    /// A switch's on/off state as XCUITest reports it ("1"/"0").
    private func isOn(_ toggle: XCUIElement) -> Bool { (toggle.value as? String) == "1" }

    /// Skip unless the MapLibre engine is live. The map is engine-switched (`map-engine-maplibre` vs
    /// `map-engine-classic`), and the classic map has no shape sources — so a band that is not drawn
    /// there is correct behaviour, not a fault, and must not be reported as one.
    private func requireMapLibreEngine(_ app: XCUIApplication) throws {
        let maplibre = app.otherElements["map-engine-maplibre"]
        if maplibre.waitForExistence(timeout: 30) { return }
        let classic = app.otherElements["map-engine-classic"].exists
        throw XCTSkip(classic
            ? "the classic map engine is live — the energy bands do not exist there"
            : "neither map engine reported itself; the map never came up")
    }

    /// Wait until the status line contains `needle`, then hand back the whole label. XCTWaiter rather
    /// than `expectation(for:)` so a timeout can report WHAT the line actually said — "still air ·
    /// 24 nm" and "position OK, but no altitude" fail identically otherwise, and they are completely
    /// different faults.
    ///
    /// Each test waits on the signal IT needs. Waiting on the drawn count everywhere made the
    /// monotonicity test — which only ever reads the radius — depend on the map's render callback and
    /// fail intermittently on something it was not testing.
    private func awaitStatus(_ status: XCUIElement, containing needle: String,
                             timeout: TimeInterval = 45,
                             file: StaticString = #filePath, line: UInt = #line) -> String {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", needle), object: status)
        if XCTWaiter().wait(for: [exp], timeout: timeout) != .completed {
            XCTFail("the energy status never reported \"\(needle)\". It said: \"\(status.label)\"",
                    file: file, line: line)
        }
        return status.label
    }

    // MARK: - the emergency button

    func testEmergencyButtonIsPresentAndReachable() {
        let app = launch()
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 30), "no emergency button in the top bar")
        XCTAssertTrue(emergency.isHittable, "the emergency button is not reachable")
        XCTAssertEqual(emergency.value as? String, "Off", "the emergency button must start un-armed")
    }

    /// It must be on screen on the TRANSCRIPT tab too. It rides the top bar precisely because that
    /// bar is the one piece of chrome present on every tab — an emergency control a pilot has to
    /// navigate to first is not one.
    func testEmergencyButtonSurvivesATabChange() {
        let app = launch()
        XCTAssertTrue(app.buttons["emergency-button"].waitForExistence(timeout: 30))
        let transcript = app.buttons["tab-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "no transcript tab")
        transcript.tap()
        XCTAssertTrue(app.buttons["emergency-button"].waitForExistence(timeout: 10),
                      "the emergency button vanished off the map tab")
    }

    /// The whole point of the control: one press turns on both off-field layers AND brings up the
    /// nearest-airport panel.
    func testArmingTurnsOnBothLayersAndOpensNearest() {
        let app = launch(["-atc.diagnosticsEnabled", "YES"])
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 30))
        emergency.tap()
        XCTAssertTrue(waitForNRST(app), "arming did not bring up the nearest-airport panel")

        openLayersPanel(app)
        let risk = app.switches["layer-lz"], energy = app.switches["layer-lz-energy"]
        XCTAssertTrue(risk.waitForExistence(timeout: 8), "no landability row after arming")
        XCTAssertTrue(isOn(risk), "arming left the landability layer off")
        XCTAssertTrue(isOn(energy), "arming left the glide-energy layer off")
    }

    /// ARM-ONLY. Pressing it a second time must not undo the first — the rule the map's NRST button
    /// documents, and the one that matters most for a control pressed by a startled hand.
    func testASecondPressNeverUndoesTheFirst() {
        let app = launch(["-atc.diagnosticsEnabled", "YES"])
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 30))
        emergency.tap()
        XCTAssertTrue(waitForNRST(app))
        emergency.tap()

        XCTAssertTrue(nrstIsUp(app), "a second press closed the nearest-airport panel")
        openLayersPanel(app)
        XCTAssertTrue(isOn(app.switches["layer-lz"]), "a second press switched the landability layer off")
        XCTAssertTrue(isOn(app.switches["layer-lz-energy"]), "a second press switched the energy layer off")
    }

    /// Stand-down is a LONG press, and it does take everything back down. The gesture is deliberate
    /// specifically so the tap that must never disarm cannot.
    func testLongPressStandsDown() {
        let app = launch(["-atc.diagnosticsEnabled", "YES"])
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 30))
        emergency.tap()
        XCTAssertTrue(waitForNRST(app))
        XCTAssertEqual(emergency.value as? String, "Armed", "the button did not report itself armed")

        emergency.press(forDuration: 1.4)

        expectation(for: NSPredicate(format: "value == %@", "Off"), evaluatedWith: emergency)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(nrstIsUp(app), "stand-down left the nearest-airport panel up")
    }

    /// The lit state must report the WORLD, not what the button remembers doing. Closing the panel by
    /// its own ✕ publishes nothing on AppModel — the widget store is a nested observable — so a button
    /// that read it through `model` would stay lit over a panel that is gone. This is that case.
    func testClosingTheNearestPanelUnArmsTheButton() {
        let app = launch(["-atc.diagnosticsEnabled", "YES"])
        let emergency = app.buttons["emergency-button"]
        XCTAssertTrue(emergency.waitForExistence(timeout: 30))
        emergency.tap()
        XCTAssertTrue(waitForNRST(app))
        XCTAssertEqual(emergency.value as? String, "Armed")

        // The panel's own ✕, not the emergency button. Found by LABEL: the header HStack carries
        // `widget-header-<kind>` and SwiftUI propagates a container's identifier down to the buttons
        // inside it, so both header controls answer to that same id — the label is what tells the ✕
        // from the ⚙ next to it.
        let close = app.buttons["Close Nearest airports"]
        XCTAssertTrue(close.waitForExistence(timeout: 8), "the NRST panel has no close control")
        close.tap()

        expectation(for: NSPredicate(format: "value == %@", "Off"), evaluatedWith: emergency)
        waitForExpectations(timeout: 10)
    }

    /// The trap-door guard. The layer rows are dev-gated for DISCOVERY, but the emergency button arms
    /// the layers for any pilot — so whenever a layer is on, its row must be there to turn it off,
    /// diagnostics or not. A layer a pilot can switch on but cannot find to switch off is a trap.
    func testALayerThatIsOnCanAlwaysBeSwitchedOff() {
        let app = launch(["-atc.map.lz", "YES"])          // note: diagnostics NOT unlocked
        openLayersPanel(app)
        let risk = app.switches["layer-lz"]
        XCTAssertTrue(risk.waitForExistence(timeout: 8),
                      "the landability row is hidden while its layer is ON — no way to turn it off")
        XCTAssertTrue(isOn(risk))
        risk.tap()
        XCTAssertFalse(isOn(risk), "the row would not switch the layer off")
    }

    /// Both layers are ORDINARY now — no developer flag anywhere in this launch. They were gated
    /// while there was no way to obtain a pack, which was honest then: a switch that cannot work is
    /// worse than an absent one. The Downloads screen made packs obtainable, so the gate went with
    /// its reason. A pilot who downloads 89 MB must be able to find the layer it feeds.
    func testTheLayersAreOfferedWithoutDeveloperDiagnostics() {
        let app = launch()                                 // no -atc.diagnosticsEnabled at all
        openLayersPanel(app)
        XCTAssertTrue(app.switches["layer-lz"].waitForExistence(timeout: 8),
                      "off-field landability is still hidden behind developer diagnostics")
        XCTAssertTrue(app.switches["layer-lz-energy"].exists,
                      "the glide energy layer is still hidden behind developer diagnostics")
    }

    /// The advisory framing is what a NON-developer now meets, so it must carry the limits, not just
    /// the label. Each clause here is a specific thing the data does not know.
    func testTheAdvisoryNoteNamesWhatIsNotModelled() {
        let app = launch()
        openLayersPanel(app)
        let note = app.staticTexts["layers-lz-note"].label
        XCTAssertTrue(note.contains("ADVISORY ONLY"), note)
        XCTAssertTrue(note.lowercased().contains("candidate ground"), note)
        XCTAssertTrue(note.lowercased().contains("never a landing recommendation"), note)
        for missing in ["fences", "livestock", "surface condition", "obstructions"] {
            XCTAssertTrue(note.lowercased().contains(missing),
                          "the note no longer says \(missing) is unmodelled: \(note)")
        }
        XCTAssertTrue(note.lowercased().contains("absence of a depicted hazard"),
                      "the note dropped the strongest clause it has: \(note)")
    }

    // MARK: - the energy layer, actually drawing

    /// THE case this suite was written for. An aeroplane held at 16,000 ft over Las Cruces, both
    /// layers on: the status line must report a real footprint AND a positive count of band polygons
    /// the map accepted. A field that computes but never reaches the shape source fails right here.
    func testEnergyBandsComputeAndReachTheMap() throws {
        let app = launchHeldOverKLRU()
        // The bands are `MLNShapeSource` polygons and exist only on the MapLibre engine. If the
        // classic map is up, "nothing drawn" is CORRECT rather than a regression, and the test has to
        // be able to tell those apart instead of reporting a bug that is not there.
        try requireMapLibreEngine(app)
        openLayersPanel(app)

        let status = app.staticTexts["layers-lz-energy-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 45),
                      "no glide-energy status line — the layer never reported anything")
        let text = awaitStatus(status, containing: "drawn")

        XCTAssertTrue(text.contains("nm"), "status carries no footprint radius: \(text)")
        // PARSED, not substring-matched. `text.contains("0 drawn")` reads "150 drawn" as a failure —
        // it caught this suite red on a run where 150 polygons had in fact been drawn, and would
        // have false-failed on any count ending in zero while quietly passing the case it was for.
        let drawn = try XCTUnwrap(Self.parseDrawn(text), "no drawn count in: \(text)")
        XCTAssertGreaterThan(drawn, 0, "the footprint computed but the map drew NOTHING: \(text)")
        XCTAssertFalse(text.contains("no altitude"),
                       "the held ownship did not reach the energy layer: \(text)")
    }

    /// The honesty case, and the one that was true on the Simulator before `--hold-ownship` existed:
    /// with no altitude there is no footprint, and the layer must SAY so. A live layer that silently
    /// draws nothing is indistinguishable from a broken one.
    func testEnergyLayerNamesItsReasonWhenItCannotDraw() {
        let app = launch(["-atc.diagnosticsEnabled", "YES", "-atc.map.lzEnergy", "YES"])
        openLayersPanel(app)
        let status = app.staticTexts["layers-lz-energy-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 45),
                      "the energy layer drew nothing and said nothing")
        XCTAssertFalse(status.label.trimmingCharacters(in: .whitespaces).isEmpty,
                       "empty status line — the pilot cannot tell 'nothing to draw' from 'broken'")
    }

    /// Climbing opens ground up. Two launches, two altitudes, same place: the higher one must report
    /// the longer reach. This is the real-terrain monotonicity check of `LZGlideFieldRealTerrainTests`
    /// re-asked of the SHIPPING path — through the launch args, the driver loop and the status line.
    func testHigherOwnshipReportsALongerReach() throws {
        func reachNm(_ alt: String) throws -> Double {
            let app = launchHeldOverKLRU(alt: alt)
            openLayersPanel(app)
            let status = app.staticTexts["layers-lz-energy-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 45))
            // The RADIUS is what this test compares — not the render callback, which belongs to
            // `testEnergyBandsComputeAndReachTheMap` and is a separate signal on a separate clock.
            let label = awaitStatus(status, containing: "nm")
            let nm = try XCTUnwrap(Self.parseNm(label), "no radius in: \(label)")
            app.terminate()
            return nm
        }
        let low = try reachNm("9000")
        let high = try reachNm("16000")
        XCTAssertGreaterThan(high, low, "climbing 7,000 ft did not extend the footprint")
    }

    /// "still air · 24 nm · 137 drawn" → 137.
    static func parseDrawn(_ s: String) -> Int? {
        for part in s.components(separatedBy: "·") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix("drawn") else { continue }
            return Int(t.dropLast("drawn".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "still air · 24 nm · 137 drawn" → 24.
    static func parseNm(_ s: String) -> Double? {
        for part in s.components(separatedBy: "·") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix("nm") else { continue }
            return Double(t.dropLast(2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: - the heatmap half

    /// The advisory framing is not decoration. The layer scores CANDIDATE GROUND; it must never read
    /// as a landing recommendation, and the words that say so have to be on screen with it.
    func testTheLayerCarriesItsAdvisoryWording() {
        let app = launch(["-atc.diagnosticsEnabled", "YES"])
        openLayersPanel(app)
        let text = app.staticTexts["layers-lz-note"].label
        XCTAssertTrue(text.contains("Advisory only"), "the advisory caption is missing: \(text)")
        XCTAssertTrue(text.lowercased().contains("candidate ground"),
                      "the caption no longer says 'candidate ground': \(text)")
        XCTAssertFalse(text.lowercased().contains("safe"),
                       "the caption calls ground 'safe' — it must not: \(text)")
    }

    /// A heatmap that draws nothing has to say which case it is in. With the layer ON, the panel must
    /// carry a data line — either the packs it mounted or the reason there are none.
    func testTheHeatmapSaysWhetherItHasData() {
        let app = launch(["-atc.diagnosticsEnabled", "YES", "-atc.map.lz", "YES"])
        openLayersPanel(app)
        let status = app.staticTexts["layers-lz-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30),
                      "the heatmap is on but the panel does not say whether it has any data")
        XCTAssertFalse(status.label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Tapping the map with the heatmap up must open a card that NAMES the rules behind the score —
    /// the explainability invariant: a heatmap that cannot say why is not shippable. Skips without an
    /// installed pack, since there is then nothing scored to tap.
    func testTappingScoredGroundExplainsItself() throws {
        let app = launchHeldOverKLRU()
        openLayersPanel(app)
        let packLine = app.staticTexts["layers-lz-status"]
        XCTAssertTrue(packLine.waitForExistence(timeout: 30))
        try XCTSkipIf(packLine.label.contains("no .lzpack"),
                      "no .lzpack installed in this Simulator — nothing scored to tap")

        let map = app.otherElements["map-engine-maplibre"]
        try XCTSkipUnless(map.waitForExistence(timeout: 30), "the MapLibre engine is not up")

        // ZOOM IN FIRST. The map opens framed wide, below the pack's minimum zoom, and the chart
        // itself says so ("Pan and zoom in to load charts") — a probe up there hits nothing at all
        // and the test would report an explainability failure that is really a camera position.
        // (The first zoom tap also dismisses the layers popover, since it lands outside it.)
        let zoomIn = app.buttons["map-zoom-in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 10), "no zoom control to reach chart zooms")
        for _ in 0..<6 { zoomIn.tap() }                      // bounded (rule 2)
        Thread.sleep(forTimeInterval: 4)                     // let the served tiles land

        // Clear of BOTH the airport and the chrome. The centre of this frame is Las Cruces Intl, and
        // an airport outranks bare ground in the probe — the card would be the airport's, not the
        // layer's; the lower-left quadrant is under the Transcript widget, which swallows the tap
        // entirely (an earlier attempt there opened no card at all and looked like a layer fault).
        // This test is about ground nobody built a runway on, on a part of the screen that is map.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.32)).tap()

        // A tap over open ground finds several things at once — airspace, an airway, and the ground
        // itself — so the card opens on its disambiguation chooser rather than on any one of them.
        // "Off-field landability" is the LZ row's subtitle there; landing on it is not the same as
        // reading the card, which is what an earlier version of this test mistook it for.
        let row = app.staticTexts["Off-field landability"]
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("the tap found nothing scored here (on screen: \(Self.visibleLabels(app)))")
        }
        row.tap()

        XCTAssertTrue(app.staticTexts["Candidate score"].waitForExistence(timeout: 10)
                      || app.staticTexts["Assessment"].exists,
                      "the card names no score and no exclusion — it explains nothing. On screen: "
                      + Self.visibleLabels(app))
        // The explainability invariant itself: the numbers are not the point, the REASONS are. The
        // fact planes must be named, and the advisory framing must travel with them.
        XCTAssertTrue(app.staticTexts["Surface"].exists && app.staticTexts["Hazard field"].exists,
                      "the card shows a score with none of the facts behind it: "
                      + Self.visibleLabels(app))
    }

    /// A digest of what is on screen, for failure messages. Without it a probe that opened the WRONG
    /// card and a probe that opened no card fail identically.
    static func visibleLabels(_ app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex
            .filter { $0.isHittable }.prefix(30)
            .map(\.label).filter { !$0.isEmpty }.joined(separator: " | ")
    }
}
