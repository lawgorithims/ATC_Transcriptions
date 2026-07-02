import XCTest
@testable import ATCTranscribe

/// The version-gating behind the "What's new" popup — when it shows, what it shows, and that the
/// changelog itself is well-formed. Pure logic (no Bundle / UserDefaults), so it's deterministic.
final class WhatsNewTests: XCTestCase {

    private var builds: [Int] { WhatsNew.releaseNotes.map(\.build) }

    // MARK: entries(newerThan:upTo:)

    func testCatchUpShowsEverythingSinceZero() {
        // A tester whose baseline predates the feature (lastSeen 0) updating to the latest build sees
        // every documented build.
        let current = builds.max()!
        let shown = WhatsNew.entries(newerThan: 0, upTo: current).map(\.build)
        XCTAssertEqual(shown, builds, "a 0-baseline catch-up should list every release note ≤ current")
    }

    func testIncrementalUpdateShowsOnlyTheNewBuild() {
        // lastSeen = second-newest build, updating to newest → only the newest build's notes.
        let sorted = builds.sorted()                       // ascending
        let newest = sorted[sorted.count - 1]
        let prev = sorted[sorted.count - 2]
        XCTAssertEqual(WhatsNew.entries(newerThan: prev, upTo: newest).map(\.build), [newest])
    }

    func testAlreadySeenShowsNothing() {
        let current = builds.max()!
        XCTAssertTrue(WhatsNew.entries(newerThan: current, upTo: current).isEmpty)
    }

    func testUpToHidesNotYetInstalledBuilds() {
        // Running an OLDER build than the newest documented one must not surface the newer build's
        // notes (e.g. notes authored ahead of an upload).
        let sorted = builds.sorted()
        guard sorted.count >= 2 else { return XCTFail("need ≥2 release notes for this test") }
        let running = sorted[sorted.count - 2]             // second-newest = currently installed
        let shown = WhatsNew.entries(newerThan: 0, upTo: running).map(\.build)
        XCTAssertFalse(shown.contains(sorted.last!), "a build newer than the running one leaked")
        XCTAssertTrue(shown.allSatisfy { $0 <= running })
    }

    // MARK: autoShowEntries (the launch decision)

    func testOnboardingSuppressesPopup() {
        // A fresh install behind the download gate hasn't "changed" — no popup.
        XCTAssertTrue(WhatsNew.autoShowEntries(lastSeen: 0, current: builds.max()!, onboarding: true).isEmpty)
    }

    func testUpdatePastOnboardingShowsCatchUp() {
        XCTAssertFalse(WhatsNew.autoShowEntries(lastSeen: 0, current: builds.max()!, onboarding: false).isEmpty)
    }

    func testRelaunchDoesNotReshow() {
        let current = builds.max()!
        XCTAssertTrue(WhatsNew.autoShowEntries(lastSeen: current, current: current, onboarding: false).isEmpty)
    }

    func testDowngradeDoesNotReplayOldNotes() {
        let sorted = builds.sorted()
        let newest = sorted.last!, older = sorted[sorted.count - 2]
        // Seen the newest, now running an older build → nothing replays.
        XCTAssertTrue(WhatsNew.autoShowEntries(lastSeen: newest, current: older, onboarding: false).isEmpty)
    }

    func testDevBuildStaysDormant() {
        // A dev/Simulator build reports CFBundleVersion "1"; with no release note ≤ 1, the auto-popup
        // never fires (the changelog is still reachable via Settings / --whats-new).
        XCTAssertTrue(WhatsNew.autoShowEntries(lastSeen: 0, current: 1, onboarding: false).isEmpty)
    }

    // MARK: changelog hygiene

    func testReleaseNotesAreWellFormed() {
        XCTAssertFalse(WhatsNew.releaseNotes.isEmpty)
        // Strictly newest-first, unique, positive build numbers.
        let bs = builds
        XCTAssertEqual(bs, bs.sorted(by: >), "release notes must be ordered newest build first")
        XCTAssertEqual(Set(bs).count, bs.count, "duplicate build numbers")
        XCTAssertTrue(bs.allSatisfy { $0 > 0 })
        for note in WhatsNew.releaseNotes {
            XCTAssertFalse(note.headline.isEmpty)
            XCTAssertFalse(note.version.isEmpty)
            XCTAssertFalse(note.highlights.isEmpty, "build \(note.build) has no highlights")
            for h in note.highlights {
                XCTAssertFalse(h.icon.isEmpty)
                XCTAssertFalse(h.title.isEmpty)
                XCTAssertFalse(h.detail.isEmpty, "highlight \"\(h.title)\" has no detail")
            }
        }
    }

    /// Pin the concrete shipped contract (not just self-consistency) so a renumber or a dropped entry
    /// is caught, and so the dev-dormant guarantee (no note ≤ build 1) is explicit.
    func testConcreteChangelogContract() {
        XCTAssertEqual(builds, [29, 28, 27, 26, 25, 24, 23, 22, 21, 18, 17, 16, 15, 14, 13, 12, 11, 10, 8], "the shipped build list changed — update the gate tests")
        XCTAssertEqual(WhatsNew.releaseNotes.first?.build, 29)
        XCTAssertTrue(builds.allSatisfy { $0 > 1 }, "the dev-dormant guarantee assumes no release note ≤ build 1")
    }

    /// A tester who skipped a build (lastSeen between two non-contiguous entries) gets every build
    /// after their baseline and not the one they were on — the half-open (lastSeen, current] interval.
    func testGapSkipCatchUp() {
        XCTAssertEqual(WhatsNew.entries(newerThan: 8, upTo: 12).map(\.build), [12, 11, 10])
        XCTAssertFalse(WhatsNew.entries(newerThan: 8, upTo: 12).map(\.build).contains(8))
        XCTAssertEqual(WhatsNew.entries(newerThan: 10, upTo: 12).map(\.build), [12, 11])   // 10 excluded
    }

    /// The persisted baseline only moves forward, so a downgrade reinstall can't replay an old log.
    func testBaselineNeverMovesBackwards() {
        XCTAssertEqual(WhatsNew.advancedBaseline(stored: 12, current: 11), 12)   // downgrade: held
        XCTAssertEqual(WhatsNew.advancedBaseline(stored: 11, current: 12), 12)   // update: advances
        XCTAssertEqual(WhatsNew.advancedBaseline(stored: 0, current: 8), 8)      // fresh: seeds current
    }
}
