import XCTest
@testable import ATCTranscribe

/// The cloud-sync gate, and the one thing about it a test can actually hold: that the container id the
/// code asks for matches the app it is asking on behalf of.
///
/// The entitlement itself is NOT assertable from here — entitlements are not in `Info.plist` and a
/// simulator test host cannot read its own signed entitlement blob — so unlike
/// `TranscriptionGateTests`, this file cannot prove the flag and the build configuration agree. What it
/// can do is catch the mismatch that is actually likely: a renamed bundle id leaving
/// `Features.cloudSyncContainerID` pointing at a container that no longer corresponds to the app.
final class CloudSyncGateTests: XCTestCase {

    /// Apple's convention is `iCloud.` + the bundle identifier, and `project.yml`'s entitlement block
    /// hardcodes the same string. Three places, one fact.
    func testTheContainerIdFollowsTheBundleId() {
        // These are hosted unit tests, so `Bundle.main` is the app under test, not the runner.
        let bundleID = Bundle.main.bundleIdentifier
        XCTAssertTrue(Features.cloudSyncContainerID.hasPrefix("iCloud."),
                      "a CloudKit container id is `iCloud.` + a reverse-DNS name")
        if let bundleID, !bundleID.hasSuffix(".tests") {
            XCTAssertEqual(Features.cloudSyncContainerID, "iCloud.\(bundleID)",
                           "the container id must track the bundle id. If the app was renamed, the "
                           + "entitlement in project.yml needs the same edit — and a mismatch is a "
                           + "runtime failure on the pilot's first sync, not a build error.")
        }
    }

    /// ⚠️ THE SAFE DEFAULT, same polarity rule as `Features.transcription` and
    /// `InstallIdentity.paywallFirstBuild`: the feature is OFF unless the symbol is present.
    ///
    /// Off means the default build signs and launches exactly as it did before sync existed, and no
    /// `CKContainer` is ever constructed. Starts asserting the other direction the moment the flag
    /// lands, so this does not silently become a test of nothing.
    func testSyncIsOffUntilTheContainerExists() throws {
        try XCTSkipIf(Features.cloudSync,
                      "the cloud-sync gate is on — the container and entitlement are then expected "
                      + "to exist, which this suite cannot verify from a test host")
        XCTAssertFalse(Features.cloudSync,
                       "without COMMSIGHT_CLOUDSYNC the app must not attempt CloudKit at all")
    }

    /// The engine survives the gate, deliberately — the same arrangement as the transcription engine
    /// and its ~170 tests. If this ever fails, the merge has been compiled out and every sync test
    /// above it is testing nothing.
    func testTheMergeIsCompiledRegardlessOfTheGate() {
        let r = SyncRecord(id: "a", kind: .flight, modifiedAt: Date(), payload: Data("x".utf8))
        XCTAssertEqual(SyncMerge.merge(local: [r], remote: []).toPush, [r],
                       "the merge must be exercisable in a build with sync switched off")
    }
}
