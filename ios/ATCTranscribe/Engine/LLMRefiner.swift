import Foundation

/// Background, low-priority queue that runs the slow-tier LLM corrector **off** the
/// transcription hot path — the mechanism that lets the context-fixer "use a free moment"
/// without ever slowing Whisper.
///
/// Three properties enforce that:
///   * **Off-actor & low priority.** The worker runs in `Task(priority: .background)`, and the
///     llama.cpp engine itself decodes on a utility-QoS queue (CPU only). The OS schedules it on
///     spare cores and yields to the higher-priority transcription task.
///   * **Bounded.** The queue is capped; under load (Whisper saturating the CPU) refinement
///     backs up, so the oldest pending requests are dropped (reported `.skipped`) instead of
///     accumulating latency. Better a missed refinement than a stalled feed.
///   * **Serial.** One generation at a time (the model + KV cache is single-use per call), so it
///     never fans out and oversubscribes the CPU.
actor LLMRefiner {
    private let corrector: LLMCorrector
    private let maxQueue: Int
    /// Deadline after which a generation is REPORTED `.skipped` (default 20 s — a throttled iPad is
    /// legitimately slow, so this is generous). Reporting only: the compute is not interrupted (a
    /// llama.cpp generation is not cancellable), so the serial one-generation invariant is preserved.
    private let timeout: TimeInterval
    private var queue: [RefinementRequest] = []
    private var working = false
    /// Set by `cancel()` (Stop / standby) to drop the backlog and stop the worker; cleared on the next
    /// run via `setOutcomeHandler` so the refiner runs again on resume.
    private var cancelled = false
    private var onOutcome: (@Sendable (UUID, RefinementOutcome) -> Void)?
    /// The request whose generation is currently in flight. Doubles as an exactly-once delivery
    /// token: whichever of {the real result, the timeout watchdog, cancel()} reaches the actor
    /// first clears it and reports; the others see a mismatch and stay silent. All three run in
    /// actor-isolated code with no suspension point between the check and the clear, so the race
    /// is impossible.
    private var inflight: UUID?
    private var watchdog: Task<Void, Never>?

    init(corrector: LLMCorrector, maxQueue: Int = 8, timeout: TimeInterval = 20) {
        self.corrector = corrector
        self.maxQueue = max(1, maxQueue)
        self.timeout = timeout
    }

    /// Set where completed (and skipped) outcomes are delivered. The handler hops to the
    /// MainActor in the session to update the record.
    func setOutcomeHandler(_ handler: @escaping @Sendable (UUID, RefinementOutcome) -> Void) {
        onOutcome = handler
        cancelled = false                 // a new run re-enables the refiner after a prior cancel()
    }

    /// Drop all pending refinements and stop the worker as soon as the in-flight generation (if any)
    /// returns. Called on Stop / standby so the background LLM never keeps "cooking" a queued backlog
    /// in the background. The next run re-enables it (see `setOutcomeHandler`).
    func cancel() {
        cancelled = true
        watchdog?.cancel(); watchdog = nil
        if let id = inflight { inflight = nil; onOutcome?(id, .skipped) }   // abandon the in-flight report
        for req in queue { onOutcome?(req.id, .skipped) }
        queue.removeAll()
    }

    /// Queue a transmission for refinement. Drops the oldest pending items beyond the cap
    /// (reporting each as `.skipped`) so the backlog — and the added latency — stays bounded.
    func enqueue(_ req: RefinementRequest) {
        queue.append(req)
        while queue.count > maxQueue {
            let dropped = queue.removeFirst()
            onOutcome?(dropped.id, .skipped)
        }
        if !working {
            working = true
            Task(priority: .background) { await self.drain() }
        }
    }

    /// Drain serially. The only suspension point is the LLM call, during which `enqueue` can
    /// append more work (actor reentrancy) without spawning a second worker (`working` is set), and
    /// the timeout watchdog can fire. The corrector is always fully awaited before the next dequeue
    /// — so exactly one generation ever runs (the llama.cpp KV-cache invariant); a genuinely hung
    /// generation stalls the queue behind it and the `maxQueue` backpressure sheds load, exactly the
    /// existing bounded behavior. The watchdog changes only REPORTING, never serialization.
    private func drain() async {
        while true {
            guard !cancelled, !queue.isEmpty else { working = false; return }
            let req = queue.removeFirst()
            let t0 = Date()
            inflight = req.id
            armWatchdog(req.id)
            let correction = await corrector.correct(text: req.text, history: req.history, retrieved: req.retrieved)
            let ms = Date().timeIntervalSince(t0) * 1000.0
            deliver(req.id, correction.changed ? .refined(correction, ms: ms) : .clean(ms: ms))
        }
    }

    /// Arm the timeout watchdog for the in-flight request. Fires once at the deadline unless the
    /// real result (or cancel) delivers first and cancels it.
    private func armWatchdog(_ id: UUID) {
        watchdog?.cancel()
        let ns = UInt64(timeout * 1_000_000_000)
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            await self?.fireTimeout(id)
        }
    }

    /// Deadline reached before the generation returned: report `.skipped` and clear the token so the
    /// eventual real result is suppressed. Actor-isolated, no suspension → atomic with `deliver`.
    private func fireTimeout(_ id: UUID) {
        guard inflight == id else { return }   // the real result (or cancel) already reported
        inflight = nil
        onOutcome?(id, .skipped)
    }

    /// Report the real outcome, unless the watchdog (or cancel) already spoke for this request.
    /// Actor-isolated, no suspension → atomic with `fireTimeout`.
    private func deliver(_ id: UUID, _ outcome: RefinementOutcome) {
        guard inflight == id else { return }
        inflight = nil
        watchdog?.cancel(); watchdog = nil
        onOutcome?(id, outcome)
    }
}
