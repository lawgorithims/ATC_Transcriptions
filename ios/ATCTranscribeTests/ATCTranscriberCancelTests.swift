import XCTest
@testable import ATCTranscribe

/// H2 (remediation): a superseded model load must bail BEFORE starting the WhisperKit/CoreML
/// compile. `ATCTranscriber.load()` checks cancellation as its first act — a cancelled load task
/// must throw `CancellationError` (never a folder/model error, which would prove the compile path
/// was entered) and leave the transcriber unloaded.
final class ATCTranscriberCancelTests: XCTestCase {

    func testLoadBailsBeforeCompileWhenCancelled() async {
        let t = ATCTranscriber(modelFolder: "/nonexistent")
        let task = Task {
            // Cancel THIS task before load() runs — the flag is set deterministically, no race.
            withUnsafeCurrentTask { $0?.cancel() }
            try await t.load()
        }
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // pass — bailed before the compile
        } catch {
            XCTFail("expected CancellationError, got \(error) — the pre-compile check is missing")
        }
        let loaded = await t.isLoaded
        XCTAssertFalse(loaded, "a cancelled load must not leave a model resident")
    }
}
