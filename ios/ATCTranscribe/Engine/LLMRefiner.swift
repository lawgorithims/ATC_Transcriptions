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
    private var queue: [RefinementRequest] = []
    private var working = false
    private var onOutcome: (@Sendable (UUID, RefinementOutcome) -> Void)?

    init(corrector: LLMCorrector, maxQueue: Int = 8) {
        self.corrector = corrector
        self.maxQueue = max(1, maxQueue)
    }

    /// Set where completed (and skipped) outcomes are delivered. The handler hops to the
    /// MainActor in the session to update the record.
    func setOutcomeHandler(_ handler: @escaping @Sendable (UUID, RefinementOutcome) -> Void) {
        onOutcome = handler
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
    /// append more work (actor reentrancy) without spawning a second worker (`working` is set).
    private func drain() async {
        while true {
            guard !queue.isEmpty else { working = false; return }
            let req = queue.removeFirst()
            let t0 = Date()
            let correction = await corrector.correct(text: req.text, history: req.history, retrieved: req.retrieved)
            let ms = Date().timeIntervalSince(t0) * 1000.0
            onOutcome?(req.id, correction.changed ? .refined(correction, ms: ms) : .clean(ms: ms))
        }
    }
}
