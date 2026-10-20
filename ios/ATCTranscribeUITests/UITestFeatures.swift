import XCTest
import Foundation
/// The app's `Features.transcription` gate, mirrored for the UI-test process.
///
/// UI tests drive the app from OUTSIDE it, so they cannot import `Features` — there is no
/// `@testable import` across a `bundle.ui-testing` boundary. What they CAN share is the compilation
/// condition itself: `COMMSIGHT_TRANSCRIPTION` is declared in `settings.base` in project.yml, so
/// every target compiles with the same value and this mirror cannot drift from the app's.
///
/// Two rules for using it, learned from what the gate broke the first time:
///
///   * Prefer ASSERTING the gated behaviour over skipping. A test that skips proves nothing about
///     the beta; a test that asserts the transcript tab is absent proves the gate works. The skips
///     below are only for flows whose subject genuinely does not exist in this build (starting a
///     capture session, picking an audio source).
///   * Never assert a bare absence as the whole test. "No power button" also passes if the app
///     failed to launch — pair it with a positive check that the EFB chrome IS there.
enum UITestFeatures {
    #if COMMSIGHT_TRANSCRIPTION
    static let transcription = true
    #else
    static let transcription = false
    #endif

    /// Skip a test whose subject is compiled out of this build.
    static func requireTranscription(
        _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try XCTSkipUnless(
            transcription,
            "\(what) is not present in an EFB-only build (COMMSIGHT_TRANSCRIPTION undefined). "
            + "Re-run with the symbol defined in project.yml to exercise it.",
            file: file, line: line)
    }
}

