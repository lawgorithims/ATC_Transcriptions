import XCTest
@testable import ATCTranscribe

/// The rule that decides what gets the connection next.
///
/// This is the whole behaviour of the data-queue feature, and it is the kind of code whose bugs only
/// appear under a load nobody can reproduce by hand — a pilot on a weak link, in the air, watching a
/// radar spinner. So the decision is a pure function of plain values and it is tested exhaustively
/// here rather than inferred from a stall in the cockpit.
final class NetworkActivityTests: XCTestCase {

    private typealias P = NetworkActivity.Priority

    private func may(_ candidate: P,
                     paused: Bool = false,
                     running: [P] = [],
                     ahead: [P] = [],
                     limit: Int = 3) -> Bool {
        NetworkActivity.mayStart(candidate: candidate, categoryPaused: paused,
                                 running: running, waitingAhead: ahead, limit: limit)
    }

    // MARK: The headline case

    /// ⚠️ THE REASON THIS FEATURE EXISTS. A pilot opens radar with a thunderstorm ahead while the app
    /// is busy pre-loading chart packs. Before, both crawled and the radar often lost. Urgent work
    /// must start regardless of what background work is already occupying the link.
    func testRadarStartsEvenWhileBackgroundWorkIsSaturatingTheLink() {
        XCTAssertTrue(may(.urgent, running: [.background, .background, .background], limit: 3),
                      "a pilot waiting on radar must not queue behind a chart prefetch")
    }

    /// And the converse: background work stands aside while something urgent is in flight.
    func testBackgroundWaitsWhileUrgentWorkRuns() {
        XCTAssertFalse(may(.background, running: [.urgent]),
                       "a prefetch must not compete with the thing the pilot is staring at")
    }

    /// Standing aside has to include work that is merely QUEUED ahead, not just running — otherwise
    /// a background job slips into a free slot moments before the urgent job is admitted, and the
    /// urgent job waits for it.
    func testBackgroundWaitsForUrgentWorkThatIsStillOnlyQUEUED() {
        XCTAssertFalse(may(.background, running: [], ahead: [.urgent]),
                       "an empty pipe is not a reason to start background work ahead of urgent work")
    }

    func testBackgroundAlsoYieldsToOrdinaryRequestedWork() {
        XCTAssertFalse(may(.background, running: [.normal]))
        XCTAssertFalse(may(.background, ahead: [.normal]))
    }

    func testBackgroundRunsWhenNothingElseWantsTheLink() {
        XCTAssertTrue(may(.background))
        XCTAssertTrue(may(.background, running: [.background], ahead: [.background]))
    }

    // MARK: The concurrency limit

    func testOrdinaryWorkRespectsTheLimit() {
        XCTAssertTrue(may(.normal, running: [.normal, .normal], limit: 3))
        XCTAssertFalse(may(.normal, running: [.normal, .normal, .normal], limit: 3),
                       "a saturated link spent on three jobs that finish beats six that do not")
    }

    /// Urgent work is exempt. One extra connection costs little; being wrong costs the pilot the
    /// one thing this feature is meant to protect.
    func testUrgentIgnoresTheLimit() {
        XCTAssertTrue(may(.urgent, running: [.urgent, .urgent, .urgent, .urgent], limit: 1))
    }

    /// A limit of zero (or nonsense) must not deadlock the queue forever.
    func testALimitOfZeroStillLetsOneJobThrough() {
        XCTAssertTrue(may(.normal, limit: 0), "max(1, limit) — a zero limit would stall everything")
        XCTAssertTrue(may(.normal, limit: -5))
    }

    // MARK: Fairness

    /// Equal priority is first-come. Without this, a long queue of same-priority jobs could starve
    /// its own head every time a new one arrives.
    func testEqualPriorityIsFirstComeFirstServed() {
        XCTAssertTrue(may(.normal, ahead: [.normal], limit: 3),
                      "same-priority work ahead does not block — the limit does the throttling")
    }

    /// Lower-priority work waiting ahead must not hold up higher-priority work behind it.
    func testHigherPriorityOvertakesLowerPriorityAlreadyWaiting() {
        XCTAssertTrue(may(.normal, ahead: [.background, .background]))
        XCTAssertTrue(may(.urgent, ahead: [.normal, .background]))
    }

    // MARK: Pausing

    /// A paused category never starts, at ANY priority. The pilot's switch outranks our opinion of
    /// how important the job is.
    func testAPausedCategoryNeverStarts() {
        for p: P in [.background, .normal, .urgent] {
            XCTAssertFalse(may(p, paused: true), "\(p) started despite its category being paused")
        }
    }

    // MARK: The queue itself

    @MainActor
    func testPausingACategoryParksItsQueuedJobsAndUnpausingReleasesThem() {
        let q = NetworkActivity()
        q.setPaused(.charts, true)
        XCTAssertTrue(q.isPaused(.charts))
        q.setPaused(.charts, false)
        XCTAssertFalse(q.isPaused(.charts))
    }

    /// Asking for a job IS unpausing it — a "Get this now" button that silently does nothing because
    /// the category is paused would be the most frustrating possible outcome.
    @MainActor
    func testPrioritisingAJobInAPausedCategoryUnpausesThatCategory() async {
        let q = NetworkActivity()
        q.setPaused(.charts, true)
        let done = expectation(description: "ran")
        Task { try? await q.run("pack", category: .charts, priority: .background) { done.fulfill() } }
        await Task.yield()
        guard let job = q.activeJobs.first else { return XCTFail("job never registered") }
        XCTAssertEqual(job.state, .paused)

        q.prioritise(job.id)
        XCTAssertFalse(q.isPaused(.charts), "prioritising must release the pause it is blocked by")
        await fulfillment(of: [done], timeout: 5)
    }

    /// ⚠️ STOPPING A QUEUED JOB MUST NOT RUN IT. `run` was `rethrows`, which made "cancelled" an
    /// outcome it could not express for a non-throwing closure — so the only way out was to run the
    /// work anyway. A Stop button whose effect is to start the download immediately is worse than
    /// no button. This is why `run` throws.
    @MainActor
    func testStoppingAQueuedJobDoesNotRunItsWork() async {
        let q = NetworkActivity()
        q.setPaused(.charts, true)                     // keep it queued so it can be stopped
        var ran = false
        let task = Task { try await q.run("pack", category: .charts) { ran = true } }
        await Task.yield()
        guard let job = q.activeJobs.first else { return XCTFail("job never registered") }

        q.cancel(job.id)
        let result = await task.result
        XCTAssertFalse(ran, "the work ran even though the pilot stopped it")
        if case .success = result { XCTFail("a stopped job must report failure, not success") }
    }

    /// ⚠️ CANCELLING A PARKED JOB MUST NOT HANG IT. `waitForTurn` suspends on a continuation; a
    /// caller that cancels its own Task while the job is waiting for a turn would, without a
    /// cancellation handler, leave that continuation un-resumed forever — the task never finishes,
    /// its `defer` never runs, and the row sits in the queue as "waiting" with nothing left to wait
    /// for. Every caller before the landability packs ran to completion once queued, so nothing
    /// exercised it. Without the handler this test does not fail; it times out.
    @MainActor
    func testCancellingTheCallersTaskReleasesAJobThatIsStillWaiting() async {
        let q = NetworkActivity()
        q.setPaused(.landability, true)          // guarantee it parks rather than running
        var ran = false
        let task = Task { try await q.run("pack", category: .landability) { ran = true } }
        await Task.yield()
        XCTAssertEqual(q.activeJobs.first?.state, .paused, "the job should be parked")

        task.cancel()
        let result = await task.result            // hangs here if the continuation is orphaned
        XCTAssertFalse(ran, "cancelled work must not run")
        if case .success = result { XCTFail("a cancelled job must report failure") }
    }

    /// A finished queue reports nothing, so the UI can stay out of the way when there is no problem.
    @MainActor
    func testSummaryIsNilWhenIdle() {
        XCTAssertNil(NetworkActivity().summary)
    }

    /// Network errors are shown to a pilot, so they have to read like something a person wrote.
    func testErrorsAreTranslatedOutOfNSErrorSpeak() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(NetworkActivity.plainError(offline), "No connection.")
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(NetworkActivity.plainError(timeout), "Timed out.")
        let weird = NSError(domain: "SomethingElse", code: 42)
        XCTAssertEqual(NetworkActivity.plainError(weird), "Did not finish.")
    }

    /// Every category needs words a pilot can act on — this is the text the feature is made of.
    func testEveryCategorySpeaksEnglish() {
        for c in NetworkActivity.Category.allCases {
            XCTAssertFalse(c.title.isEmpty, "\(c) has no title")
            XCTAssertFalse(c.blurb.isEmpty, "\(c) has no explanation")
            XCTAssertFalse(c.title.contains("_"), "\(c.title) looks like an identifier, not a label")
        }
    }
}
