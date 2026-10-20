import Foundation

/// Build-time feature gates.
///
/// # Why `transcription` is COMPILE-time and not a UserDefaults flag
///
/// The live-ATC transcription half of CommSight needs `NSMicrophoneUsageDescription` and the
/// `audio` background mode. Both are **Info.plist** entries, which are fixed when the app is
/// built — there is no way to add them at runtime. A *runtime* gate would therefore be able to
/// disagree with the plist:
///
///   - Ship a beta whose plist has no mic string, flip a runtime flag on that same IPA, and
///     `AVAudioApplication.requestRecordPermission` traps — iOS kills an app that asks for a
///     permission it never declared. A crash, not a degraded feature.
///   - Or keep the mic string so the flag is always safe, and hand App Review a public beta that
///     declares microphone access and a background audio mode for a feature no screen exposes.
///     That is a documented rejection reason, not a theoretical one.
///
/// So the gate is a compilation condition, it is `let` rather than `var`, and nothing writes it.
/// There is deliberately no UserDefaults key and no launch argument: a value that cannot be set at
/// runtime cannot drift from the plist at runtime.
///
/// # The polarity is deliberate
///
/// The symbol is **absent by default**, so the default build is the EFB-only one. The tempting
/// shape — a `hideTranscription` / `efbOnly` boolean read with `UserDefaults.standard.bool(forKey:)`
/// — defaults to `false` for a missing key, and this project registers no defaults anywhere
/// (`register(defaults:)` appears nowhere), so that shape would have shipped the hidden half fully
/// visible on every fresh install. Naming the flag for what it *enables* keeps "off" as the safe
/// state.
///
/// # Re-enabling
///
/// Add `COMMSIGHT_TRANSCRIPTION` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `project.yml` **and**
/// restore the plist keys in the block beside it, then `xcodegen generate`. Those two edits are one
/// unit: `TranscriptionGateTests` fails the suite if they disagree, so neither can be forgotten.
enum Features {

    /// Whether the live-ATC transcription pipeline is exposed in the UI.
    ///
    /// The engine, models, correction layer and their ~170 unit tests are compiled either way —
    /// this gates **presentation and launch-time side effects** (the onboarding download wall, the
    /// model downloads, the seeded sample transcript, the transcript tab/card/widgets, the audio
    /// source picker), not the code that would do the work.
    #if COMMSIGHT_TRANSCRIPTION
    static let transcription = true
    #else
    static let transcription = false
    #endif

    /// The Info.plist keys that exist **only** to serve transcription, asserted against
    /// `transcription` by `TranscriptionGateTests`.
    ///
    /// `NSLocalNetworkUsageDescription` is deliberately NOT here: the Stratux ADS-B traffic + GPS
    /// link is an EFB feature that needs it, so it stays in every build. Deleting it as part of
    /// "strip the cockpit-audio plist entries" would make every connection to the receiver fail
    /// silently, with no permission prompt and no error.
    static let transcriptionOnlyInfoPlistKeys = ["NSMicrophoneUsageDescription"]
}
