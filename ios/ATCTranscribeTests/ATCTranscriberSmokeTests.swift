import XCTest
@testable import ATCTranscribe

/// On-device smoke test: load a converted CoreML model and transcribe the bundled
/// ATCO2 diagnostic clips, proving the fine-tuned model runs end-to-end through
/// `ATCTranscriber` (model load → audio decode → WhisperKit inference → text).
///
/// Skipped unless `ATC_MODEL_DIR` (+ `ATC_AUDIO_DIR`) are set, so the normal unit
/// suite is unaffected. Run on the Mac (paths forwarded into the Simulator via the
/// `SIMCTL_CHILD_` prefix):
///
///   MODEL=$(find ~/atc-coreml/small -name AudioEncoder.mlmodelc -exec dirname {} \;)
///   SIMCTL_CHILD_ATC_MODEL_DIR="$MODEL" \
///   SIMCTL_CHILD_ATC_AUDIO_DIR="$HOME/ATC_Transcribe/tests/diagnostic_data" \
///   xcodebuild test-without-building -scheme ATCTranscribe \
///     -only-testing:ATCTranscribeTests/ATCTranscriberSmokeTests -destination '...'
final class ATCTranscriberSmokeTests: XCTestCase {
    /// Reference transcripts from `tests/diagnostic_data/manifest.json`.
    private static let clips: [(file: String, reference: String)] = [
        ("luigisaetta_00367.wav", "roger station calling please pass your message"),
        ("luigisaetta_00270.wav", "Hotel Echo X-ray number one runway two five"),
        ("luigisaetta_00460.wav", "thank you QNH is one zero two three"),
        ("luigisaetta_00464.wav", "one six right cleared to land Rex Sixty One Thirty Four"),
        ("luigisaetta_00550.wav", "tower Bauhinia Two Zero One Seven established ILS three four left"),
    ]

    func testTranscribesBundledATCClips() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelDir = env["ATC_MODEL_DIR"], !modelDir.isEmpty,
              let audioDir = env["ATC_AUDIO_DIR"], !audioDir.isEmpty else {
            throw XCTSkip("Set ATC_MODEL_DIR and ATC_AUDIO_DIR to run the on-device transcription smoke test.")
        }

        // CPU-only: the iOS Simulator has no Neural Engine.
        let transcriber = ATCTranscriber(modelFolder: modelDir, cpuOnly: true)
        try await transcriber.load()

        var produced = 0
        for clip in Self.clips {
            let path = (audioDir as NSString).appendingPathComponent(clip.file)
            let audio = try AudioFile.load16kMono(path: path)
            let text = try await transcriber.transcribe(audio)
            print("SMOKE \(clip.file)\n   ref: \(clip.reference)\n   got: \(text)")
            if !text.isEmpty { produced += 1 }
        }
        XCTAssertGreaterThan(produced, 0, "Expected at least one non-empty transcript from the model.")
    }
}
