import XCTest
@testable import ATCTranscribe

/// The internet ADS-B feed must stand down for a Stratux that is CONNECTED, not for one that is merely
/// switched on in Settings.
///
/// The two are not the same thing and conflating them cost the pilot all traffic from both sources. The
/// Stratux link is a preference plus a Wi-Fi association: enabling it in Settings says "I own one", and
/// it stays enabled on the ground, at home, in the car, and any time the receiver is off or out of range.
/// Gating the internet poller on that preference meant that the moment the app came to the foreground the
/// online feed shut off — so a pilot on cell data, with the traffic layer on and no Stratux actually
/// talking, saw an empty sky and a pill that claimed Stratux was supplying it.
///
/// This is the same defect that was already fixed once for OWNSHIP (`trustedStratuxOwnship`, where keying
/// on `coordinate != nil` drew a dropped link as authoritative). These pin the traffic half so the two
/// paths cannot drift apart again.
final class TrafficSourceGateTests: XCTestCase {

    /// The pill is the pilot's answer to "why do I see no aircraft?", and it takes the SUPPLYING flag —
    /// so a merely-enabled Stratux must not make it claim a live receiver feed.
    func testPillDoesNotClaimStratuxWhenItIsOnlyEnabled() {
        // What the caller now passes: stratuxEnabled: = "is it actually supplying".
        let notSupplying = AppModel.trafficFeed(enabled: true, stratuxEnabled: false, standby: false,
                                                foreground: true, status: .ok, hasCenter: true,
                                                updatedAt: Date(), aircraftCount: 3, hasPolledOnce: true)
        XCTAssertEqual(notSupplying, .liveWithAircraft,
                       "with the receiver silent the ONLINE feed is what is running, and the pill must say so")

        let supplying = AppModel.trafficFeed(enabled: true, stratuxEnabled: true, standby: false,
                                             foreground: true, status: .idle, hasCenter: false,
                                             updatedAt: nil, aircraftCount: 0, hasPolledOnce: false)
        XCTAssertEqual(supplying, .stratux,
                       "a connected receiver still owns the feed and the pill still says Stratux")
    }

    /// The layer being off outranks everything — a pilot who turned traffic off must not be told about
    /// either source.
    func testDisabledLayerReportsOffWhateverTheReceiverIsDoing() {
        for supplying in [true, false] {
            XCTAssertEqual(AppModel.trafficFeed(enabled: false, stratuxEnabled: supplying, standby: false,
                                                foreground: true, status: .ok, hasCenter: true,
                                                updatedAt: Date(), aircraftCount: 5, hasPolledOnce: true),
                           .off)
        }
    }

    /// With the online layer on and no receiver supplying, every honest not-yet state must still be
    /// reachable — this is the path the bug made unreachable, so it is the one worth pinning.
    func testOnlineFeedStatesAreReachableWithASilentReceiver() {
        func feed(_ status: ADSBStatus, hasCenter: Bool, updatedAt: Date?, count: Int,
                  polled: Bool = true, standby: Bool = false, fg: Bool = true) -> TrafficFeedState {
            AppModel.trafficFeed(enabled: true, stratuxEnabled: false, standby: standby, foreground: fg,
                                 status: status, hasCenter: hasCenter, updatedAt: updatedAt,
                                 aircraftCount: count, hasPolledOnce: polled)
        }
        XCTAssertEqual(feed(.idle, hasCenter: false, updatedAt: nil, count: 0), .waitingForCenter)
        XCTAssertEqual(feed(.idle, hasCenter: true, updatedAt: nil, count: 0, polled: false), .loading)
        XCTAssertEqual(feed(.idle, hasCenter: true, updatedAt: nil, count: 0), .idleUnexpected)
        XCTAssertEqual(feed(.ok, hasCenter: true, updatedAt: Date(), count: 0), .liveEmpty)
        XCTAssertEqual(feed(.ok, hasCenter: true, updatedAt: Date(), count: 7), .liveWithAircraft)
        if case .failed = feed(.error("no route to host"), hasCenter: true, updatedAt: nil, count: 0) {} else {
            XCTFail("a transport error must surface as failed, not as loading")
        }
        XCTAssertEqual(feed(.ok, hasCenter: true, updatedAt: Date(), count: 3, standby: true),
                       .paused("Traffic paused — Standby is on"))
        XCTAssertEqual(feed(.ok, hasCenter: true, updatedAt: Date(), count: 3, fg: false),
                       .paused("Traffic paused — app in the background"))
    }
}
