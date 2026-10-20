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

    /// What floats over the map on a fresh install, in both builds.
    ///
    /// Renamed from `testDefaultsShowTranscriptAndHideDiagnostics`: the old name asserted a spec that is
    /// now only half true. `.transcript` and `.proofOfLife` were the ONLY two default-visible frames, so
    /// an EFB-only build that merely hid them would ship the flagship iPad layout completely empty —
    /// `.gps` takes their place there, and this is the test that says so.
    func testDefaultsAreTheRightFurnitureForThisBuild() {
        let d = WidgetLayout.defaults()
        XCTAssertNil(d.frame(.flightPlan), "flight plan is the strip now — no widget in defaults")
        XCTAssertEqual(d.frame(.latency)?.visible, false)      // diagnostics off by default
        XCTAssertEqual(d.frame(.diagnostics)?.visible, false)
        XCTAssertEqual(d.frame(.objectInfo)?.visible, false)   // only shows on a tap

        if Features.transcription {
            XCTAssertEqual(d.frame(.transcript)?.visible, true)
            XCTAssertEqual(d.frame(.proofOfLife)?.visible, true)
            XCTAssertEqual(d.frame(.gps)?.visible, false)
        } else {
            XCTAssertEqual(d.frame(.transcript)?.visible, false)
            XCTAssertEqual(d.frame(.proofOfLife)?.visible, false)
            XCTAssertEqual(d.frame(.gps)?.visible, true,
                           "hiding both transcription frames without raising another leaves the iPad "
                           + "floating canvas empty on first launch")
        }

        // The FRAMES must survive either way: WidgetLayout.update silently no-ops on a missing frame, so
        // deleting them would quietly break show/reveal/dismiss/toggle/bringToFront -- and it would throw
        // away the pilot's saved size and position for when transcription returns.
        XCTAssertNotNil(d.frame(.transcript), "keep the frame, hide the widget")
        XCTAssertNotNil(d.frame(.proofOfLife), "keep the frame, hide the widget")
    }

    /// A saved build-109 layout has the transcript and performance cards stored as visible. They must
    /// come back hidden in an EFB-only build -- and their frames must still be there.
    func testLoadHidesTranscriptionFramesWithoutDeletingThem() throws {
        var saved = WidgetLayout.defaults()
        for i in saved.items.indices where saved.items[i].kind.isTranscription {
            saved.items[i].visible = true              // what build 109 persisted
        }
        saved.save()
        defer { WidgetLayout.clear() }
        let loaded = try XCTUnwrap(WidgetLayout.load())
        for kind in FloatingWidgetKind.allCases where kind.isTranscription {
            XCTAssertNotNil(loaded.frame(kind), "\(kind) frame must survive the load")
            if !Features.transcription {
                XCTAssertEqual(loaded.frame(kind)?.visible, false,
                               "\(kind) was saved visible by an older build and must load hidden")
            }
        }
    }

    /// The Widgets menu is driven by `userManageable`, so a hidden kind must never be offerable --
    /// otherwise a tester can tick a checkbox for a card that cannot render.
    func testHiddenKindsAreNotUserManageable() {
        for kind in FloatingWidgetKind.allCases where kind.hiddenFromUI {
            XCTAssertFalse(kind.userManageable, "\(kind) is hidden but still offered in the Widgets menu")
        }
        // EFB widgets stay reachable in every build.
        XCTAssertTrue(FloatingWidgetKind.gps.userManageable)
        XCTAssertTrue(FloatingWidgetKind.stratux.userManageable,
                      "the Stratux card reports the receiver link, GPS and traffic -- that is EFB")
        XCTAssertTrue(FloatingWidgetKind.diagnostics.userManageable,
                      "the diagnostics card reports CPU and memory -- that is EFB")
    }

    /// Classification guard: if a widget is added or reclassified, this is the test that notices.
    func testTranscriptionClassification() {
        let t = FloatingWidgetKind.allCases.filter(\.isTranscription).map(\.rawValue).sorted()
        XCTAssertEqual(t, ["host", "latency", "proofOfLife", "transcript"],
                       "host shows the active speech model and proofOfLife shows WER -- both transcription. "
                       + "stratux/diagnostics/gps/nrst/landable/objectInfo are EFB and must stay out of this list.")
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
        XCTAssertEqual(m.frame(.diagnostics)?.visible, true)   // user had it → keep visible (EFB card)
        if Features.transcription {
            XCTAssertEqual(m.frame(.latency)?.visible, true)
            XCTAssertEqual(m.frame(.transcript)?.visible, true)    // default-visible untouched
        } else {
            // `migrating` only raises `userManageable` kinds, and a hidden kind is not one — so a pilot's
            // old sidebar list cannot smuggle a transcription card back into an EFB-only build.
            XCTAssertEqual(m.frame(.latency)?.visible, false,
                           "latency is transcription; an old sidebar list must not resurrect it")
            XCTAssertEqual(m.frame(.transcript)?.visible, false)
        }
    }
}
