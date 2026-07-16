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

    func testEdgeDockZones() {
        let c = CGSize(width: 1000, height: 700)
        let mid = CGRect(x: 350, y: 200, width: 300, height: 200)               // card well away from edges
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 10, droppedRect: mid, container: c), .left)
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 995, droppedRect: mid, container: c), .right)
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 500, droppedRect: mid, container: c))   // middle → normal snap
    }

    func testCardTouchingEdgeDocksEvenWithFingerMidScreen() {
        // The reported bug: the pilot drags until the CARD hits the edge, but the finger (on the header)
        // is still mid-screen — that drop must dock, not snap back.
        let c = CGSize(width: 1000, height: 700)
        let atLeft = CGRect(x: -40, y: 200, width: 300, height: 200)            // card pushed past the left edge
        let atRight = CGRect(x: 720, y: 200, width: 300, height: 200)           // maxX = 1020 ≥ width
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 400, droppedRect: atLeft, container: c), .left)
        XCTAssertEqual(WidgetGeometry.edgeDock(fingerX: 600, droppedRect: atRight, container: c), .right)
        // A card merely NEAR the edge (at its normal 12 pt anchor margin) must NOT dock.
        let anchored = CGRect(x: 12, y: 200, width: 300, height: 200)
        XCTAssertNil(WidgetGeometry.edgeDock(fingerX: 400, droppedRect: anchored, container: c))
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

    func testObjectInfoNeverDocks() {
        let s = freshStore()
        s.dockToSide(.objectInfo, .left)            // tap-driven panel — must not dock
        XCTAssertNil(s.leftPane)
    }
}
