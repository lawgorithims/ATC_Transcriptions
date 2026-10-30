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

    // MARK: - Composition with the runtime entitlement
    //
    // Monetization adds a SECOND gate in front of transcription: a paid tier. The two must compose
    // by AND, with the compile-time gate dominant — a purchase cannot conjure an Info.plist key, and
    // `AVAudioApplication.requestRecordPermission` terminates an app that asks for a permission it
    // never declared. These tests are what makes that AND load-bearing rather than conventional.

    /// No tier, no currency, and no combination of the two can unlock transcription in a build
    /// without the compilation condition.
    ///
    /// This is the test that stops a plausible-looking "unlock transcription for Pro + Performance"
    /// change from shipping a crash. If someone later gives `Capability.transcription` a
    /// `minimumTier` without also restoring the plist keys, this fails — which is the whole point.
    func testEntitlementCannotEnableTranscriptionWithoutTheCompileFlag() throws {
        try XCTSkipIf(Features.transcription,
                      "only meaningful for a build with the symbol absent — the AND is trivially "
                      + "satisfied when the compile gate is already true")

        let currencies: [EntitlementCurrency] = [
            .verified(asOf: Date()), .unverified(lastVerified: Date()),
            .lapsed(since: Date()), .revoked(at: Date()), .none,
        ]
        for tier in Tier.allCases {
            for currency in currencies {
                XCTAssertFalse(
                    Entitlements.allows(.transcription, tier: tier, currency: currency),
                    "transcription was granted at tier \(tier) / currency \(currency) in a build "
                    + "where COMMSIGHT_TRANSCRIPTION is ABSENT. The Info.plist has no microphone "
                    + "string in this build, so anything that then starts a session terminates the "
                    + "app. The entitlement must AND with Features.transcription, never override it.")
                XCTAssertFalse(
                    EntitlementGate(tier: tier, currency: currency).transcription,
                    "the flattened gate disagrees with the policy for transcription at "
                    + "\(tier)/\(currency) — view code reads the gate, so this is the value that matters.")
            }
        }
    }

    /// The flip is a THREE-part atomic unit, and this names the third part.
    ///
    /// `project.yml`'s compilation condition and its two plist blocks are asserted by the tests
    /// above. The third is `Capability.transcription.minimumTier`, which is `nil` (not sold) while
    /// the model licence and the cockpit audio path are unresolved. Flipping only the first two
    /// yields a transcription UI whose model download refuses — a policy decision that looks like a
    /// bug. Asserting the two together means neither half can be forgotten.
    func testTranscriptionIsNotSellableWhileItIsCompiledOut() throws {
        try XCTSkipIf(Features.transcription, "only meaningful for the EFB-only build")
        XCTAssertNil(
            Capability.transcription.minimumTier,
            "transcription has a minimumTier (it is for sale) but COMMSIGHT_TRANSCRIPTION is absent, "
            + "so this build cannot deliver it. Selling a tier the binary cannot honour is a refund "
            + "queue and a 2.3.1 problem. Set minimumTier in the SAME change that flips the symbol "
            + "and restores the plist blocks.")
    }

    /// Guards the list the composition test iterates, mirroring
    /// `testTranscriptionOnlyKeyListIsWhatWeThinkItIs`.
    ///
    /// A new transcription-dependent capability must be added to
    /// `Features.transcriptionGatedCapabilities`, not just to the `Capability` enum — otherwise a
    /// tier could switch it on in a build that cannot deliver it. Pinning the list by value is what
    /// forces that second edit to be a conscious one.
    func testTranscriptionGatedCapabilityListIsWhatWeThinkItIs() {
        XCTAssertEqual(Features.transcriptionGatedCapabilities, [.transcription],
                       "If a transcription-dependent capability is added, add it to this list so the "
                       + "compile gate covers it, and assert it in the composition test above.")
    }

    /// Every member of the gated list is refused when the symbol is absent — asserted over the
    /// list itself, so the guarantee extends automatically to anything added to it.
    func testEveryGatedCapabilityIsRefusedWithoutTheCompileFlag() throws {
        try XCTSkipIf(Features.transcription, "only meaningful for the EFB-only build")
        let currencies: [EntitlementCurrency] = [
            .verified(asOf: Date()), .unverified(lastVerified: Date()),
            .lapsed(since: Date()), .revoked(at: Date()), .none,
        ]
        for capability in Features.transcriptionGatedCapabilities {
            for tier in Tier.allCases {
                for currency in currencies {
                    XCTAssertFalse(
                        Entitlements.allows(capability, tier: tier, currency: currency),
                        "\(capability.rawValue) is compile-gated but was granted at \(tier)/\(currency) "
                        + "in a build where COMMSIGHT_TRANSCRIPTION is absent.")
                }
            }
        }
    }
}
