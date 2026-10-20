import XCTest
@testable import ATCTranscribe

/// Keeps the transcription gate and the Info.plist from drifting apart.
///
/// `Features.transcription` is a compilation condition; the microphone string and the `audio`
/// background mode are Info.plist entries written by `project.yml`. They are two edits in two
/// places, which is exactly the shape that rots: someone flips the symbol to bring transcription
/// back, forgets the plist, and `AVAudioApplication.requestRecordPermission` traps at runtime
/// because iOS terminates an app that asks for a permission it never declared. Or the reverse —
/// the beta ships declaring microphone access and background audio for a feature no screen
/// exposes, which is a documented App Review rejection.
///
/// Neither failure is visible at build time, and the crash only reproduces on a device with the
/// gate on. So it is asserted here instead: whichever way the gate is set, the suite fails unless
/// the plist agrees.
final class TranscriptionGateTests: XCTestCase {

    private var info: [String: Any] {
        Bundle(for: AppModel.self).infoDictionary ?? [:]
    }

    /// The mic string must be present exactly when transcription is compiled in.
    func testMicrophoneUsageDescriptionMatchesTheGate() {
        let declared = info["NSMicrophoneUsageDescription"] as? String
        if Features.transcription {
            XCTAssertNotNil(
                declared,
                "COMMSIGHT_TRANSCRIPTION is defined but Info.plist has no NSMicrophoneUsageDescription. "
                + "Requesting mic permission without it TERMINATES the app. Restore the key in the "
                + "transcription block of project.yml and re-run xcodegen.")
            XCTAssertFalse(
                (declared ?? "").isEmpty,
                "NSMicrophoneUsageDescription is present but empty — iOS treats an empty purpose string "
                + "the same as a missing one and kills the app on request.")
        } else {
            XCTAssertNil(
                declared,
                "Transcription is gated OFF but Info.plist still declares NSMicrophoneUsageDescription. "
                + "A public beta that asks for microphone access for a feature no screen exposes is a "
                + "documented App Review rejection. Remove the key from the transcription block in "
                + "project.yml.")
        }
    }

    /// The `audio` background mode exists only to keep transcription running when backgrounded.
    func testAudioBackgroundModeMatchesTheGate() {
        let modes = (info["UIBackgroundModes"] as? [String]) ?? []
        if Features.transcription {
            XCTAssertTrue(
                modes.contains("audio"),
                "COMMSIGHT_TRANSCRIPTION is defined but UIBackgroundModes lacks `audio`, so a session "
                + "started before backgrounding is suspended mid-transmission.")
        } else {
            XCTAssertFalse(
                modes.contains("audio"),
                "Transcription is gated OFF but UIBackgroundModes still declares `audio`. Nothing can "
                + "start an audio session in this build (AppModel.start() is unreachable), so the "
                + "entitlement is unused — and App Review asks what it is for.")
        }
    }

    /// The Stratux link is EFB, not transcription, so its permission string survives either way.
    /// Deleting it alongside the cockpit-audio keys makes every connection to the receiver fail
    /// silently: iOS refuses local-network access with no prompt and no error to catch.
    func testLocalNetworkPermissionSurvivesTheGate() {
        let s = info["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(s, "NSLocalNetworkUsageDescription must be present in EVERY build — the Stratux "
                        + "ADS-B traffic and GPS link needs it and is an EFB feature.")
        XCTAssertFalse((s ?? "").isEmpty)
    }

    /// A beta build must not describe itself as a transcription product in its permission strings.
    func testNoUserFacingStringAdvertisesTranscriptionWhenGated() throws {
        try XCTSkipIf(Features.transcription, "only meaningful for the EFB-only build")
        for key in ["NSLocalNetworkUsageDescription", "NSLocationWhenInUseUsageDescription"] {
            let s = (info[key] as? String ?? "").lowercased()
            XCTAssertFalse(s.contains("transcrib"),
                           "\(key) advertises transcription: \"\(info[key] ?? "")\". This string is shown "
                           + "in a system permission dialog, so it is the one piece of hidden-feature copy "
                           + "a beta tester is guaranteed to read.")
        }
    }

    /// Guards the list the other tests iterate, so adding a key without a test is caught.
    func testTranscriptionOnlyKeyListIsWhatWeThinkItIs() {
        XCTAssertEqual(Features.transcriptionOnlyInfoPlistKeys, ["NSMicrophoneUsageDescription"],
                       "If a transcription-only plist key is added, assert it against the gate above too.")
    }
}
