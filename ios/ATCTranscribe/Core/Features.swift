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

    /// Whether cloud sync of the logbook and the note library is switched on.
    ///
    /// # Why this is COMPILE-time too, for a different reason than transcription
    ///
    /// Transcription's gate exists because its Info.plist keys cannot be added at runtime. This one
    /// exists because of **entitlements**: CloudKit needs
    /// `com.apple.developer.icloud-container-identifiers` and a container that actually exists in the
    /// team's account. A build carrying that entitlement against a container nobody created fails to
    /// launch, so the entitlement cannot ship speculatively — and a runtime flag would be able to ask
    /// for a container the binary was never entitled to reach.
    ///
    /// So the flag, the entitlement block in `project.yml` and the container id are one unit, the same
    /// shape as the transcription flip. The polarity matches too: **absent by default**, so the
    /// default build signs and launches exactly as it did before any of this existed.
    ///
    /// The merge, the ledger, the coordinator and `CloudKitTransport` are compiled either way — only
    /// `CKContainer` instantiation and the launch-time sync are behind this. Same arrangement as the
    /// transcription engine: the code and its tests survive the gate that hides the behaviour.
    #if COMMSIGHT_CLOUDSYNC
    static let cloudSync = true
    #else
    static let cloudSync = false
    #endif

    /// # Not a paid feature
    ///
    /// The logbook and the note library are on the never-gate list, so their sync is free too, and the
    /// usual counter-argument does not apply: this syncs through the **pilot's own** private CloudKit
    /// database, so the storage is their iCloud quota and costs us nothing to serve. That is the second
    /// half of the never-gate rationale, not just the safety half. Putting a pilot's own notes behind a
    /// tier — or worse, stranding them on one iPad when a subscription lapses — is the kind of thing
    /// the never-gate list exists to prevent.
    ///
    /// The CloudKit container backing `cloudSync`. Derived from the bundle id by Apple's convention
    /// (`iCloud.` + the app's bundle identifier) and must match the entitlement in `project.yml`
    /// exactly — a mismatch is a runtime failure on the first sync, not a build error.
    static let cloudSyncContainerID = "iCloud.com.flycommsight.atctranscribe"

    /// The Info.plist keys that exist **only** to serve transcription, asserted against
    /// `transcription` by `TranscriptionGateTests`.
    ///
    /// `NSLocalNetworkUsageDescription` is deliberately NOT here: the Stratux ADS-B traffic + GPS
    /// link is an EFB feature that needs it, so it stays in every build. Deleting it as part of
    /// "strip the cockpit-audio plist entries" would make every connection to the receiver fail
    /// silently, with no permission prompt and no error.
    static let transcriptionOnlyInfoPlistKeys = ["NSMicrophoneUsageDescription"]

    /// The capabilities that cannot be granted unless `transcription` is compiled in, whatever a
    /// pilot has paid for. `Entitlements.allows` ANDs every one of these against the gate, and
    /// `TranscriptionGateTests` asserts both the list and the behaviour.
    ///
    /// WHY A LIST AND NOT A SINGLE CASE. `transcription` is the obvious member, but the voice
    /// clearance loader is a second: it exists only to act on a transcript, its UI is compiled out
    /// with the rest of the presentation layer, and it would be meaningless (and would advertise a
    /// feature the build does not have) if a tier could switch it on alone. Keeping them in one
    /// list, next to the plist keys, means the two halves of the gate are read together — a new
    /// transcription-dependent feature is added here rather than discovered later.
    static let transcriptionGatedCapabilities: [Capability] = [.transcription]
}
