import XCTest
import CoreGraphics
@testable import ATCTranscribe

/// Pure tests for the floating-widget layout model + docking geometry (no view state).
final class WidgetLayoutTests: XCTestCase {
    private let container = CGSize(width: 1000, height: 800)

    // MARK: geometry

    func testRectResolvesTopTrailingFlushToCorner() {
        let f = WidgetFrame(kind: .stratux, anchor: .topTrailing, offset: .zero,
                            size: CGSize(width: 300, height: 150), opacity: 1, visible: true, pinned: false, z: 1)
        let r = WidgetGeometry.rect(for: f, in: container)
        let m = WidgetGeometry.margin
        XCTAssertEqual(r.maxX, container.width - m, accuracy: 0.5)   // pinned to the right edge
        XCTAssertEqual(r.minY, m, accuracy: 0.5)                      // and the top edge
    }

    func testRectClampsFullyOnScreen() {
        // A huge positive offset must not strand the card off the right/bottom.
        let f = WidgetFrame(kind: .transcript, anchor: .topLeading, offset: CGSize(width: 5, height: 5),
                            size: CGSize(width: 300, height: 200), opacity: 1, visible: true, pinned: false, z: 1)
        let r = WidgetGeometry.rect(for: f, in: container)
        XCTAssertLessThanOrEqual(r.maxX, container.width)
        XCTAssertLessThanOrEqual(r.maxY, container.height)
        XCTAssertGreaterThanOrEqual(r.minX, 0)
        XCTAssertGreaterThanOrEqual(r.minY, 0)
    }

    func testSnapPicksNearestAnchorAndMagnetizesFlush() {
        let size = CGSize(width: 300, height: 150)
        // Drop the card near the bottom-right corner → snaps to .bottomTrailing, flush (zero offset).
        let brOrigin = WidgetGeometry.anchorOrigin(.bottomTrailing, size: size, container: container)
        let (anchor, offset) = WidgetGeometry.snap(droppedOrigin: brOrigin, size: size, in: container)
        XCTAssertEqual(anchor, .bottomTrailing)
        XCTAssertEqual(offset.width, 0, accuracy: 0.001)
        XCTAssertEqual(offset.height, 0, accuracy: 0.001)
    }

    func testSnapKeepsResidualOffsetWhenDroppedMidZone() {
        let size = CGSize(width: 300, height: 150)
        // Drop well away from any anchor → nearest anchor + a non-zero residual offset (free placement).
        let dropped = CGPoint(x: 500, y: 300)
        let (_, offset) = WidgetGeometry.snap(droppedOrigin: dropped, size: size, in: container)
        XCTAssertTrue(abs(offset.width) > 0 || abs(offset.height) > 0)
    }

    // MARK: model

    func testDefaultsShowTranscriptAndHideDiagnostics() {
        let d = WidgetLayout.defaults()
        XCTAssertEqual(d.frame(.transcript)?.visible, true)
        XCTAssertNil(d.frame(.flightPlan), "flight plan is the strip now — no widget in defaults")
        XCTAssertEqual(d.frame(.latency)?.visible, false)      // diagnostics off by default
        XCTAssertEqual(d.frame(.diagnostics)?.visible, false)
        XCTAssertEqual(d.frame(.objectInfo)?.visible, false)   // only shows on a tap
    }

    /// A pre-redesign saved layout (which includes a `flightPlan` card) must still decode — the
    /// retired kind's case survives for Codable — and the retired frame is dropped at load rather
    /// than resetting the user's whole layout to defaults.
    func testLoadDropsRetiredFlightPlanFrameButKeepsLayout() throws {
        var old = WidgetLayout.defaults()
        old.items.append(WidgetFrame(kind: .flightPlan, anchor: .topLeading, offset: .zero,
                                     size: CGSize(width: 340, height: 150), opacity: 0.92,
                                     visible: true, pinned: false, z: 2))
        old.update(.transcript) { $0.opacity = 0.33 }          // a user customization to preserve
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: WidgetLayout.storageKey)
        defer { WidgetLayout.clear() }
        let loaded = WidgetLayout.load()
        XCTAssertNotNil(loaded, "layout with a retired kind must still load")
        XCTAssertNil(loaded?.frame(.flightPlan), "retired frame dropped")
        XCTAssertEqual(loaded?.frame(.transcript)?.opacity, 0.33, "customizations preserved")
    }

    func testCodableRoundTrip() throws {
        var layout = WidgetLayout.defaults()
        layout.update(.transcript) { $0.opacity = 0.4; $0.pinned = true; $0.anchor = .center }
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(WidgetLayout.self, from: data)
        XCTAssertEqual(back, layout)
        XCTAssertEqual(back.frame(.transcript)?.opacity, 0.4)
        XCTAssertEqual(back.frame(.transcript)?.pinned, true)
    }

    func testBringToFrontRaisesZ() {
        var layout = WidgetLayout.defaults()
        let before = layout.frame(.host)?.z ?? 0
        layout.bringToFront(.host)
        XCTAssertGreaterThan(layout.frame(.host)?.z ?? 0, before)
        XCTAssertEqual(layout.frame(.host)?.z, layout.maxZ)
    }

    func testMigrationMakesListedWidgetsVisible() {
        let m = WidgetLayout.migrating(fromSidebarIDs: ["diagnostics", "latency"])
        XCTAssertEqual(m.frame(.diagnostics)?.visible, true)   // user had them → keep visible
        XCTAssertEqual(m.frame(.latency)?.visible, true)
        XCTAssertEqual(m.frame(.transcript)?.visible, true)    // default-visible untouched
    }
}
