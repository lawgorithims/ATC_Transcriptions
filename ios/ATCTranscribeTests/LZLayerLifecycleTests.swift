import XCTest
@testable import ATCTranscribe

/// A layer that is switched off must stop speaking — through every surface, not just the shading.
///
/// The heatmap is only the visible half of this feature. It also puts a row on the tap card and a
/// ranked list in a floating panel, and both of those outlived the toggle: the panel's visibility is
/// PERSISTED, so a pilot who revealed the list once had it back on the next launch with the layer
/// off, still naming ground the map was not drawing. The panel's own gate read
/// `showLZRisk || packAvailable` — an OR — so merely having packs on disk kept it answering.
///
/// "The layer is off" and "the layer has nothing to say" must look the same to a pilot, because
/// there is no way to tell them apart from the cockpit.
@MainActor
final class LZLayerLifecycleTests: XCTestCase {

    /// THE REGRESSION. Revealing the ranked list and then switching the layer off must put the list
    /// away with it.
    func testSwitchingTheLayerOffPutsTheRankedListAway() {
        let model = AppModel()
        model.showLZRisk = true
        model.widgetStore.reveal(.landable)
        XCTAssertTrue(model.widgetStore.isVisible(.landable), "the list did not open")

        model.showLZRisk = false
        XCTAssertFalse(model.widgetStore.isVisible(.landable),
                       "the ranked list is still up for a layer that is off — and its visibility "
                       + "persists, so it comes back on the next launch")
    }

    /// The emergency stand-down goes through the same flag, so it must inherit the same behaviour —
    /// the one moment a stale panel would be most confusing.
    func testTheEmergencyStandDownAlsoClearsTheList() {
        let model = AppModel()
        model.showLZRisk = true
        model.showLZEnergy = true
        model.widgetStore.reveal(.landable)
        model.standDownEmergency(compact: true)
        XCTAssertFalse(model.showLZRisk)
        XCTAssertFalse(model.widgetStore.isVisible(.landable),
                       "standing down left the landable list on screen")
    }

    /// NOT SYMMETRICAL, DELIBERATELY. Switching the layer on must not shove a panel onto the map —
    /// what to have open is a decluttering decision the pilot makes separately, and the layers panel
    /// offers the list as a button rather than doing it for them.
    func testSwitchingTheLayerOnDoesNotOpenAnything() {
        let model = AppModel()
        model.showLZRisk = false
        XCTAssertFalse(model.widgetStore.isVisible(.landable))
        model.showLZRisk = true
        XCTAssertFalse(model.widgetStore.isVisible(.landable),
                       "switching the layer on opened a panel the pilot did not ask for")
    }

    /// Setting the flag to the value it already holds must not disturb anything: a redundant write
    /// from a view update would otherwise close a panel the pilot had just opened.
    func testAWriteThatChangesNothingClosesNothing() {
        let model = AppModel()
        model.showLZRisk = true
        model.widgetStore.reveal(.landable)
        model.showLZRisk = true                       // same value again
        XCTAssertTrue(model.widgetStore.isVisible(.landable),
                      "a no-op write to the toggle closed the list")
    }
}
