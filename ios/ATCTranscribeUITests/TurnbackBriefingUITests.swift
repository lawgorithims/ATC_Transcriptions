import XCTest

/// The turn-back briefing, driven the way a pilot meets it: a planned flight in an aircraft with no
/// turn-back number raises the prompt, and the number the pilot enters from it reaches the BRIEF
/// popover converted to what the altimeter will read.
///
/// The number is the pilot's own and the app never computes one, so what this suite pins is the
/// path: a prompt that cannot reach the editor, or a number that is saved and never briefed, is the
/// failure. The arithmetic and the density-altitude rules have their own unit tests.
final class TurnbackBriefingUITests: XCTestCase {

    /// A callsign no pilot will have saved, so the teardown can remove exactly what this test made.
    private let callsign = "N111TB"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testThePromptLeadsToABriefingWithThePilotsNumber() throws {
        let app = XCUIApplication()
        // The wind overlay and diagnostics PERSIST; state them so a previous suite's leftovers cannot
        // move a control this test taps.
        app.launchArguments += ["-atc.onboardingDismissed", "YES", "--reset-widgets",
                                "-atc.map.wind", "NO", "-atc.diagnosticsEnabled", "NO"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        func field(placeholder: String) -> XCUIElement {
            app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
        }
        // Aircraft, plan and strip all PERSIST. Leave the app as a fresh install has it, even when an
        // assertion below stops the test early: the aircraft deleted, the plan cleared, the strip shut.
        addTeardownBlock { [callsign] in
            if app.state != .runningForeground { app.launch() }
            let dismiss = app.descendants(matching: .any)["PopoverDismissRegion"]
            if dismiss.exists { dismiss.tap() }
            let cancel = app.buttons["Cancel"]
            if cancel.exists { cancel.tap() }                   // an editor sheet left open
            let chip = el("plan-aircraft")
            if chip.waitForExistence(timeout: 3) {
                chip.tap()
                let edit = app.buttons["Edit \(callsign)…"]
                if edit.waitForExistence(timeout: 3) {
                    edit.tap()
                    let delete = el("aircraft-delete")
                    if delete.waitForExistence(timeout: 5) { delete.tap() }
                } else if dismiss.exists {
                    dismiss.tap()                               // close the menu it opened
                }
            }
            let clear = el("plan-clear")
            if clear.waitForExistence(timeout: 3) {
                clear.tap()
                let confirm = app.alerts.buttons["Clear"]
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            }
            let done = el("plan-bar-done")
            if done.waitForExistence(timeout: 3) { done.tap() }
        }

        // 1. File a departure.
        let bag = app.buttons["flight-bag-button"]
        XCTAssertTrue(bag.waitForExistence(timeout: 30), "no flight-plan control")
        let route = el("plan-route")
        if !route.waitForExistence(timeout: 3) { bag.tap() }
        guard route.waitForExistence(timeout: 10) else { return XCTFail("the flight-plan strip did not open") }
        route.tap()
        let old = (route.value as? String) ?? ""
        route.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 4) + "KLRU KTUS\n")

        // 2. Add an aircraft with no turn-back number. Saving it selects it for the plan.
        let chip = el("plan-aircraft")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no aircraft box in the strip")
        chip.tap()
        let add = el("aircraft-add")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the aircraft menu has no Add aircraft")
        add.tap()
        let callsignField = field(placeholder: "e.g. N8925T")
        XCTAssertTrue(callsignField.waitForExistence(timeout: 10), "the aircraft sheet has no callsign field")
        callsignField.tap()
        callsignField.typeText(callsign)
        let typeField = field(placeholder: "e.g. Piper Seneca")
        typeField.tap()
        typeField.typeText("Test single")
        el("aircraft-save").tap()

        // 3. The prompt asks for the number, and its button opens the editor at the right aircraft.
        let prompt = el("turnback-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 15),
                      "a planned flight in an aircraft with no turn-back number raised no prompt")
        el("turnback-prompt-set").tap()
        let turnback = field(placeholder: "ft above the runway — yours")
        XCTAssertTrue(turnback.waitForExistence(timeout: 10), "Set it did not open the aircraft editor")
        for _ in 0..<4 where !turnback.isHittable { app.swipeUp() }     // the card sits below Glide
        XCTAssertTrue(turnback.isHittable, "the turn-back field is not reachable in the editor")
        turnback.tap()
        turnback.typeText("1000")
        el("aircraft-save").tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 10), "the prompt outlived the number it asked for")

        // 4. BRIEF carries the pilot's number, and the briefing converts it to the altimeter.
        let brief = el("plan-briefing")
        XCTAssertTrue(brief.waitForExistence(timeout: 10), "no BRIEF cell in the trip stats")
        expectation(for: NSPredicate(format: "label CONTAINS 'TB 1,000'"), evaluatedWith: brief)
        waitForExpectations(timeout: 10)
        brief.tap()
        let line = el("briefing-turnback")
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the briefing has no turn-back line: \(el("flight-briefing").label)")
        // KLRU is 4,457 ft: 1,000 ft above the field reads 5,457 on the altimeter.
        XCTAssertTrue(line.label.contains("1,000 ft above the field"), "the pilot's number is not briefed: \(line.label)")
        XCTAssertTrue(line.label.contains("5,457 ft on the altimeter"), "no altimeter reading: \(line.label)")
        XCTAssertFalse(el("briefing-turnback-unset").exists, "a set number still briefed as unset")
    }
}
