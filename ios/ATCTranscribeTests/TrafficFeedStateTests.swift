import XCTest
@testable import ATCTranscribe

/// The online-traffic pill's decision table. The bug this pins: the pill inferred its text from
/// `aircraftUpdatedAt == nil` alone, so a poller that was NOT RUNNING (ADSBStatus.idle — the initial
/// value and what stop() publishes) rendered an eternal spinning "Loading traffic…". A pilot in
/// standby watched a promise that could never be kept, and the state was undiagnosable remotely.
final class TrafficFeedStateTests: XCTestCase {

    /// Defaults describe the healthy case — enabled, foregrounded, centered, a snapshot arrived,
    /// aircraft in range — so each test overrides only the one input it is about.
    private func state(enabled: Bool = true, stratux: Bool = false, standby: Bool = false,
                       foreground: Bool = true, status: ADSBStatus = .ok, hasCenter: Bool = true,
                       updatedAt: Date? = Date(), aircraftCount: Int = 3,
                       hasPolledOnce: Bool = true) -> TrafficFeedState {
        AppModel.trafficFeed(enabled: enabled, stratuxEnabled: stratux, standby: standby,
                             foreground: foreground, status: status, hasCenter: hasCenter,
                             updatedAt: updatedAt, aircraftCount: aircraftCount,
                             hasPolledOnce: hasPolledOnce)
    }

    // MARK: THE REGRESSION — a stopped poller must never claim to be loading

    /// `.idle` means two OPPOSITE things and they must not share a pill:
    ///   * before the first poll returns, it is the ordinary starting status of a healthy fetch;
    ///   * after a poll has reported, it means the poller stopped.
    /// The first version of this conflated them and told a pilot to "toggle the layer to retry" while a
    /// perfectly good first fetch was in flight.
    func testIdleBeforeTheFirstPollIsLoadingNotAStuckFeed() {
        let firstPoll = state(status: .idle, updatedAt: nil, hasPolledOnce: false)
        XCTAssertEqual(firstPoll, .loading, "the opening fetch is loading, not a dead feed")
        XCTAssertTrue(firstPoll.pillSpins, "a real fetch in flight is the one thing that may spin")
        XCTAssertNotEqual(firstPoll.pillText, "Traffic feed idle — toggle the layer to retry")
    }

    func testIdleAfterAPollHasReportedIsAStuckFeed() {
        // The service has spoken at least once, yet there is still no snapshot → genuinely not running.
        let s = state(status: .idle, updatedAt: nil, hasPolledOnce: true)
        XCTAssertEqual(s, .idleUnexpected)
        XCTAssertFalse(s.pillSpins, "an idle feed must not spin — that implies progress that isn't happening")
        XCTAssertNotEqual(s.pillText, "Loading traffic…")
    }

    func testStandbyReportsStandbyNotLoading() {
        // The exact shape of the user's report: a good fix, layer on, yet nothing ever arrives.
        let s = state(standby: true, status: .idle, updatedAt: nil)
        XCTAssertEqual(s, .paused("Traffic paused — Standby is on"))
        XCTAssertFalse(s.pillSpins)
        XCTAssertEqual(s.pillIcon, "pause.circle")
    }

    func testBackgroundedReportsPausedNotLoading() {
        let s = state(foreground: false, status: .idle, updatedAt: nil)
        XCTAssertEqual(s, .paused("Traffic paused — app in the background"))
        XCTAssertFalse(s.pillSpins)
    }

    /// Standby outranks a stale error: the actionable reason wins, so the pilot is told what to DO.
    func testActionableReasonOutranksAStaleError() {
        XCTAssertEqual(state(standby: true, status: .error("offline"), updatedAt: nil),
                       .paused("Traffic paused — Standby is on"))
    }

    // MARK: the rest of the table

    func testOffAndStratuxShowNoPill() {
        XCTAssertEqual(state(enabled: false), .off)
        XCTAssertNil(state(enabled: false).pillText)
        // An enabled Stratux link owns traffic; its own widget reports status, so the map stays quiet.
        XCTAssertEqual(state(stratux: true), .stratux)
        XCTAssertNil(state(stratux: true).pillText)
    }

    func testWaitingForCenterWhenNothingToPollAround() {
        let s = state(hasCenter: false, updatedAt: nil)
        XCTAssertEqual(s, .waitingForCenter)
        XCTAssertEqual(s.pillIcon, "location.slash")
        XCTAssertFalse(s.pillSpins)
    }

    func testGenuineLoadingIsTheOnlySpinningState() {
        let loading = state(status: .ok, updatedAt: nil)
        XCTAssertEqual(loading, .loading)
        XCTAssertTrue(loading.pillSpins, "a real in-flight fetch is the ONLY state that spins")
        // Every other state must be still.
        for s: TrafficFeedState in [.off, .stratux, .paused("x"), .waitingForCenter, .idleUnexpected,
                                    .failed("x"), .liveEmpty, .liveWithAircraft] {
            XCTAssertFalse(s.pillSpins, "\(s) must not spin")
        }
    }

    func testFailureSurfacesAsUnavailable() {
        let s = state(status: .error("offline"), updatedAt: nil)
        XCTAssertEqual(s, .failed("offline"))
        XCTAssertEqual(s.pillIcon, "wifi.exclamationmark")
    }

    func testLiveEmptyVersusDrawnAircraft() {
        XCTAssertEqual(state(aircraftCount: 0), .liveEmpty)
        XCTAssertEqual(state(aircraftCount: 0).pillText, "Traffic live — no aircraft nearby")
        // With aircraft on screen the pill goes silent — the planes are their own evidence.
        XCTAssertEqual(state(aircraftCount: 7), .liveWithAircraft)
        XCTAssertNil(state(aircraftCount: 7).pillText)
    }

    /// No input combination may leave the pilot with a spinner AND no aircraft forever: whenever the
    /// state is not a genuine fetch, the text must name a reason or the layer is simply off/live.
    func testEveryCombinationIsHonest() {
        for enabled in [true, false] {
            for standby in [true, false] {
                for foreground in [true, false] {
                    for hasCenter in [true, false] {
                        for status: ADSBStatus in [.idle, .ok, .error("x")] {
                            for updated in [nil, Date()] as [Date?] {
                              for polled in [false, true] {
                                let s = AppModel.trafficFeed(enabled: enabled, stratuxEnabled: false,
                                                             standby: standby, foreground: foreground,
                                                             status: status, hasCenter: hasCenter,
                                                             updatedAt: updated, aircraftCount: 0,
                                                             hasPolledOnce: polled)
                                if s.pillSpins {
                                    XCTAssertEqual(s, .loading, "only .loading may spin, got \(s)")
                                    XCTAssertNil(updated, "a spinner implies no snapshot yet")
                                    XCTAssertTrue(enabled && !standby && foreground && hasCenter,
                                                  "a spinner implies the poller can actually run")
                                }
                              }
                            }
                        }
                    }
                }
            }
        }
    }
}
