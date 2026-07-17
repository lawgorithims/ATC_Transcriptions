import XCTest
import CoreGraphics
@testable import ATCTranscribe

/// The edge-dock split-screen side panes: edge detection + the dock/undock/replace state machine.
@MainActor
final class WidgetPaneTests: XCTestCase {

    /// A store with a known-clean pane state (init reads persisted UserDefaults, which other runs dirty).
    private func freshStore() -> WidgetStore {
        let s = WidgetStore()
        s.leftPane = nil; s.rightPane = nil
        return s
    }

    // A deliberate horizontal toss toward an edge (finger ends in the zone, drag directed that way).
    private let tossLeft = CGSize(width: -300, height: 10)
    private let tossRight = CGSize(width: 300, height: 10)

    func testEdgeDockZones() {
        let c = CGSize(width: 1000, height: 700)
        let mid = CGRect(x: 350, y: 200, width: 300, height: 200)               // card well away from edges
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 10, drag: tossLeft, droppedRect: mid, container: c), .left)
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 995, drag: tossRight, droppedRect: mid, container: c), .right)
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 500, drag: tossLeft, droppedRect: mid, container: c)) // middle → snap
    }

    func testCardTouchingEdgeDocksEvenWithFingerMidScreen() {
        // The reported bug: the pilot drags until the CARD hits the edge, but the finger (on the header)
        // is still mid-screen — that drop must dock, not snap back. A shove past the edge docks any direction.
        let c = CGSize(width: 1000, height: 700)
        let atLeft = CGRect(x: -40, y: 200, width: 300, height: 200)            // card pushed past the left edge
        let atRight = CGRect(x: 720, y: 200, width: 300, height: 200)           // maxX = 1020 ≥ width + shove
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 400, drag: tossLeft, droppedRect: atLeft, container: c), .left)
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 600, drag: tossRight, droppedRect: atRight, container: c), .right)
        // A card merely NEAR the edge (at its normal 12 pt anchor margin) must NOT dock.
        let anchored = CGRect(x: 12, y: 200, width: 300, height: 200)
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 400, drag: tossLeft, droppedRect: anchored, container: c))
    }

    /// Robustness (the brittleness fix): a drop whose finger lands in the edge band but WITHOUT a
    /// deliberate sideways toss must NOT dock — a vertical drag along the edge, a short nudge, or a
    /// drag in the opposite direction.
    func testEdgeDockRejectsAccidentalGestures() {
        let c = CGSize(width: 1000, height: 700)
        let nearLeft = CGRect(x: 20, y: 200, width: 300, height: 200)
        // Vertical drag along the left edge (finger in the zone) → no dock.
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 20, drag: CGSize(width: 4, height: 260),
                                             droppedRect: nearLeft, container: c))
        // A tiny nudge that ends at the edge → below the travel threshold → no dock.
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 20, drag: CGSize(width: -12, height: 2),
                                             droppedRect: nearLeft, container: c))
        // Finger in the LEFT zone but the drag went RIGHT (a drift back) → no dock.
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 30, drag: CGSize(width: 120, height: 0),
                                             droppedRect: nearLeft, container: c))
        // A real leftward toss ending in the same spot DOES dock (proves the zone still works).
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 30, drag: tossLeft, droppedRect: nearLeft, container: c), .left)
    }

    func testTwoFingerCenterDockNeedsDeliberatePush() {
        let c = CGSize(width: 1000, height: 700)
        // Centre in the outer-left band with a leftward push → dock left.
        XCTAssertEqual(WidgetGeometry.edgeDockByCenter(centerX: 120, drag: tossLeft, container: c), .left)
        XCTAssertEqual(WidgetGeometry.edgeDockByCenter(centerX: 880, drag: tossRight, container: c), .right)
        // Centre in the band but a mostly-vertical two-finger pan → no dock.
        XCTAssertNil(WidgetGeometry.edgeDockByCenter(centerX: 120, drag: CGSize(width: 6, height: 200), container: c))
        // Centre mid-screen → no dock regardless of push.
        XCTAssertNil(WidgetGeometry.edgeDockByCenter(centerX: 500, drag: tossLeft, container: c))
    }

    func testDockHidesFloatingCardAndOccupiesSide() {
        let s = freshStore()
        s.show(.transcript)                         // floating + visible
        XCTAssertTrue(s.isVisible(.transcript))
        s.dockToSide(.transcript, .left)
        XCTAssertEqual(s.leftPane, .transcript)
        XCTAssertFalse(s.isVisible(.transcript))    // no longer rendered as a floating card
    }

    func testMostRecentWinsWhenTwoDockToTheSameSide() {
        let s = freshStore()
        s.dockToSide(.transcript, .left)
        s.dockToSide(.stratux, .left)               // second widget to the SAME side
        XCTAssertEqual(s.leftPane, .stratux)        // most recent shows
        XCTAssertFalse(s.isVisible(.transcript))    // the previous occupant is closed out
    }

    func testDockingToOtherSideMovesIt() {
        let s = freshStore()
        s.dockToSide(.stratux, .left)
        s.dockToSide(.stratux, .right)              // same widget, other side
        XCTAssertNil(s.leftPane)                    // gone from the left
        XCTAssertEqual(s.rightPane, .stratux)
    }

    func testUndockPopsBackToFloating() {
        let s = freshStore()
        s.dockToSide(.stratux, .right)
        s.undockToWidget(.right)
        XCTAssertNil(s.rightPane)
        XCTAssertTrue(s.isVisible(.stratux))        // back as a floating card
    }

    func testClosePaneRemovesWithoutFloating() {
        let s = freshStore()
        s.dockToSide(.stratux, .right)
        s.closePane(.right)
        XCTAssertNil(s.rightPane)
        XCTAssertFalse(s.isVisible(.stratux))       // closed out, not popped to floating
    }

    func testShowClearsPaneSoItNeverDoubleRenders() {
        let s = freshStore()
        s.dockToSide(.transcript, .left)
        s.show(.transcript)                         // re-show from the widgets menu
        XCTAssertNil(s.leftPane)                     // popped out of the pane
        XCTAssertTrue(s.isVisible(.transcript))
    }

    func testObjectInfoDocksAndClosingThePaneClearsTheTap() {
        let s = freshStore()
        s.mapProbe = MapProbeResult(id: "t", objects: [])
        s.dockToSide(.objectInfo, .left)            // the tapped-object card docks like any widget now
        XCTAssertEqual(s.leftPane, .objectInfo)
        s.closePane(.left)
        XCTAssertNil(s.leftPane)
        XCTAssertNil(s.mapProbe, "closing a docked object pane must clear the tap (else the floating card reappears)")
    }

    func testClearingTheTapClosesADockedObjectPane() {
        let s = freshStore()
        s.mapProbe = MapProbeResult(id: "t", objects: [])
        s.dockToSide(.objectInfo, .right)
        s.mapProbe = nil                             // tap dismissed elsewhere (e.g. card's own ✕)
        XCTAssertNil(s.rightPane, "an object pane with no tapped object left must close")
    }
}
