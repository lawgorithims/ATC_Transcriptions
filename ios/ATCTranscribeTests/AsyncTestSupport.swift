import XCTest

/// Waiting on an EVENT instead of on the clock.
///
/// A fixed `Task.sleep` used as a synchronization primitive is a defect, not a style choice. It was
/// measured breaking a real test on 2026-07-29: the background refiner runs at background QoS, whose
/// timer wake-ups macOS defers under CPU load, and a 0.1 s deadline went unreported for 1.08 s — past
/// the 1 s that test slept before reading its sink, so it saw zero outcomes and failed. Every sleep
/// tuned on an idle machine is that bug waiting for a busy one, and the tighter the budget the sooner
/// it fires.
///
/// The fix is to make the DEADLINE a liveness bound rather than a tuned delay: poll until the thing
/// you are waiting for has actually happened, and only fail if it never does. A slow machine then
/// makes the test slower, never red.
///
/// This does NOT apply to asserting an ABSENCE ("it must not have polled"). There is no event to wait
/// for, so a sleep is the right tool — and a longer one only makes that assertion stronger, which is
/// the opposite of the failure mode above. Those sites say so in a comment.
extension XCTestCase {

    /// Poll `condition` until it holds, or fail the test after `timeout`.
    ///
    /// `timeout` is deliberately generous: it exists to stop a hung test, not to time the work, so
    /// raising it never weakens an assertion. `what` names the event, so a timeout failure reads as
    /// "the thing never happened" rather than "an assertion about nothing was false".
    @discardableResult
    func waitUntil(_ what: String,
                   timeout: TimeInterval = 10,
                   poll: TimeInterval = 0.01,
                   file: StaticString = #filePath,
                   line: UInt = #line,
                   _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {                       // bounded by wall clock (rule 2)
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        if condition() { return true }                  // one last look, in case the deadline raced us
        XCTFail("timed out after \(timeout)s waiting for \(what)", file: file, line: line)
        return false
    }
}
