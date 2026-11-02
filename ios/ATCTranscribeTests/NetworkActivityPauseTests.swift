import XCTest
@testable import ATCTranscribe

/// What "pause" and "stop" actually do to the data queue.
///
/// These are the behaviours a pilot reported as broken: a paused category that kept producing
/// download rows, and a row with no way to stop it. The admission RULE is tested exhaustively next
/// door in `NetworkActivityTests` as a pure function; what cannot be tested that way is the part
/// that went wrong — the queue's interaction with callers that ask again by themselves, and whether
/// a stop reaches work that has already started. So these drive a real queue.
///
/// Each test builds its OWN `NetworkActivity` rather than touching `.shared`: the singleton is alive
/// for the whole test host, and a leftover pause or a parked job would make these pass or fail
/// depending on what ran before them.
@MainActor
final class NetworkActivityPauseTests: XCTestCase {

    /// A mutable flag an escaping closure can set without the test capturing a `var` across tasks.
    private final class Flag { var hit = false }

    /// Long enough for a parked job to reach `.paused`, short enough not to slow the suite. The
    /// waits here are on a continuation the queue itself resumes, so this is slack and not a race.
    private let settle: UInt64 = 60_000_000

    /// Run `body` and report whether it FINISHED inside `seconds`.
    ///
    /// ⚠️ EVERY WAIT ON A `.giveUp` CALL GOES THROUGH THIS, and it is not belt-and-braces. The
    /// regression these tests guard against does not return a wrong answer — it never returns at
    /// all, because parking the request forever is precisely the old behaviour. Verified by
    /// mutation: with the give-up branch removed from `waitForTurn`, an unbounded `await` hung the
    /// whole suite at the first test and the remaining six never ran. A broken pause would then
    /// reach a release looking like a stuck CI job rather than a failing assertion.
    private func settles(within seconds: Double = 2, _ body: @escaping () async -> Void) async -> Bool {
        let done = Flag()
        let work = Task { await body(); done.hit = true }
        let deadline = Date().addingTimeInterval(seconds)
        while !done.hit, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !done.hit { work.cancel() }
        return done.hit
    }

    // MARK: The reported defect

    /// ⚠️ THE CHART-DOWNLOAD BUG. The map's chart loader asks for a pack again on every pan and both
    /// prefetchers ask again on every fix, so PARKING those requests made a paused category look like
    /// it was still downloading: the parked row vanished when the next pan tore down its caller's
    /// Task, and an identical row took its place a frame later. From the cockpit that is a pause
    /// button that does nothing.
    func testSelfRenewingWorkIsRefusedOutrightRatherThanQueued() async {
        let q = NetworkActivity()
        q.setPaused(.charts, true)
        let ran = Flag()
        let refused = Flag()

        let settled = await settles {
            do {
                try await q.run("Chart pack: Denver", category: .charts, whenPaused: .giveUp) {
                    ran.hit = true
                }
            } catch is NetworkActivity.Paused {
                refused.hit = true
            } catch {
                // left for the assertions below to report
            }
        }

        XCTAssertTrue(settled,
                      "a paused category must REFUSE work that asks again by itself, not park it. "
                      + "Parking is the behaviour that made the pause look broken: the map's chart "
                      + "loader re-asks on every pan, so the parked row vanished with the next pan "
                      + "and an identical one took its place.")
        XCTAssertTrue(refused.hit, "and the refusal must be NetworkActivity.Paused, not a failure")
        XCTAssertFalse(ran.hit, "the work itself must not run")
        XCTAssertTrue(q.jobs.isEmpty,
                      "and no row may be left behind — a row nobody is waiting on is exactly what "
                      + "the pilot sees as a pause that does nothing")
    }

    /// The other half of the same decision: work the PILOT asked for still waits visibly. A paused
    /// download that silently errored would be worse than one that plainly says it is waiting.
    func testWorkThePilotAskedForStillWaitsVisibly() async throws {
        let q = NetworkActivity()
        q.setPaused(.plates, true)
        let task = Task { try await q.run("Plate: KDFW ILS 17C", category: .plates) { 7 } }
        try await Task.sleep(nanoseconds: settle)

        XCTAssertEqual(q.jobs.count, 1, "the row exists")
        XCTAssertEqual(q.jobs.first?.state, .paused, "and says the pilot paused it")

        q.setPaused(.plates, false)
        let out = try await task.value
        XCTAssertEqual(out, 7, "switching the category back on releases it")
    }

    // MARK: "Get now" no longer lifts the pause

    /// ⚠️ ONE TAP USED TO UNDO THE WHOLE PAUSE. `prioritise` cleared the category outright — so a
    /// pilot who paused chart packs and then asked for ONE of them got every other chart download
    /// restarting behind it, which is indistinguishable from the pause having failed.
    func testGetNowAdmitsThatRowAndLeavesThePauseStanding() async throws {
        let q = NetworkActivity()
        q.setPaused(.charts, true)
        let wanted = Task { try await q.run("Chart pack: Denver", category: .charts) { "denver" } }
        try await Task.sleep(nanoseconds: settle)

        let id = try XCTUnwrap(q.jobs.first?.id)
        q.prioritise(id)
        let out = try await wanted.value
        XCTAssertEqual(out, "denver", "the row the pilot asked for runs")
        XCTAssertTrue(q.isPaused(.charts),
                      "and chart packs stay paused — asking for one pack is not asking for all of them")

        // Proof that the pause is still doing its job for everything else.
        let refused = Flag()
        let settled = await settles {
            do {
                try await q.run("Chart pack: Pueblo", category: .charts, whenPaused: .giveUp) { }
            } catch is NetworkActivity.Paused {
                refused.hit = true
            } catch { }
        }
        XCTAssertTrue(settled, "the category is still paused, so this must be refused, not parked")
        XCTAssertTrue(refused.hit, "and refused with Paused")
    }

    // MARK: Pausing stops work nobody asked for

    /// Switching a category off stops the PREFETCH that was running in it, and spares the download
    /// the pilot is waiting on. The asymmetry is the point: bytes the app spent uninvited are the
    /// cheapest thing to throw away, and bytes the pilot asked for are the most expensive.
    func testPausingStopsUnaskedWorkAndSparesRequestedWork() async throws {
        let q = NetworkActivity()
        let prefetchStarted = expectation(description: "prefetch running")
        let requestedStarted = expectation(description: "requested download running")

        let prefetch = Task {
            try await q.run("Chart pack: ahead of you", category: .charts, priority: .background) {
                prefetchStarted.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let requested = Task {
            try await q.run("Chart pack: Denver", category: .charts, priority: .normal) {
                requestedStarted.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        await fulfillment(of: [prefetchStarted, requestedStarted], timeout: 3)

        q.setPaused(.charts, true)

        do { _ = try await prefetch.value; XCTFail("the prefetch should have been stopped") } catch { }
        XCTAssertEqual(q.jobs.first { $0.priority == .background }?.state, .cancelled,
                       "a prefetch the app started uninvited stops when the pilot switches it off")
        XCTAssertEqual(q.jobs.first { $0.priority == .normal }?.state, .running,
                       "the download the pilot asked for keeps going — a pause is triage, not a "
                       + "reason to discard what they are waiting for")
        requested.cancel()
        _ = try? await requested.value
    }

    // MARK: Stopping one row

    /// ⚠️ THE CONTROL THAT DID NOT EXIST. `cancel` refused to touch a running job, so the queue could
    /// decline to START work but never end it: a 70 MB chart pack crawling over a link that cannot
    /// carry it was unstoppable from the one screen whose whole purpose is control of the link.
    func testStoppingARunningRowEndsTheTransfer() async throws {
        let q = NetworkActivity()
        let running = expectation(description: "transfer running")
        let task = Task {
            try await q.run("Chart pack: Denver", category: .charts) {
                running.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)   // stands in for a slow download
            }
        }
        await fulfillment(of: [running], timeout: 3)

        let id = try XCTUnwrap(q.jobs.first { $0.state == .running }?.id)
        q.cancel(id)

        do {
            _ = try await task.value
            XCTFail("a stopped transfer must not report success")
        } catch {
            // expected: the child task's cancellation surfaces out of the work
        }
        XCTAssertEqual(q.jobs.first { $0.id == id }?.state, .cancelled,
                       "the row says the pilot stopped it, NOT that the download failed — being told "
                       + "your charts failed when you stopped them yourself sends you hunting for a "
                       + "network problem that is not there")
    }

    /// A job that has not started still leaves the queue on a stop, as it always did.
    func testStoppingAWaitingRowRemovesItFromTheQueue() async throws {
        let q = NetworkActivity()
        q.setPaused(.weather, true)
        let task = Task { try await q.run("METAR sweep", category: .weather) { 1 } }
        try await Task.sleep(nanoseconds: settle)

        let id = try XCTUnwrap(q.jobs.first?.id)
        q.cancel(id)
        do { _ = try await task.value; XCTFail("a stopped job must throw") } catch { }
        XCTAssertEqual(q.jobs.first { $0.id == id }?.state, .cancelled)
    }

    /// A real failure must still read as a failure. The stop path sets `.cancelled` before the work
    /// unwinds, and the guard that protects it must not swallow genuine errors on every other path.
    func testAGenuineFailureStillReportsAsFailed() async {
        let q = NetworkActivity()
        struct Boom: Error {}
        do {
            try await q.run("Radar frame", category: .radar) { throw Boom() }
            XCTFail("the work threw")
        } catch { }
        guard case .failed = q.jobs.first?.state else {
            return XCTFail("expected .failed, got \(String(describing: q.jobs.first?.state))")
        }
    }
}
