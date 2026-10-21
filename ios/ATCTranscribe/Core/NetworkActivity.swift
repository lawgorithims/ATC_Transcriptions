import Foundation
import Combine

/// What the app is doing with the connection, in the pilot's words — and the order it does it in.
///
/// THE PROBLEM, which every EFB has and none of them show you. On a weak cell link the app has more
/// work queued than the pipe can carry: a chart pack, three weather reports, a NOTAM sweep, a nav-data
/// currency check. They all proceed at once, so they all crawl, and the one the pilot actually needs —
/// the radar frame with a thunderstorm on it — finishes last or not at all. From the cockpit this
/// looks like the app has frozen. It has not; it is busy with things nobody asked for. The pilot
/// cannot see that, cannot tell whether waiting will help, and cannot do anything about it.
///
/// WHAT THIS CHANGES. Every network job registers here with a plain-language label and a priority.
/// Three things follow:
///
///   1. **A bounded queue.** Only a few jobs run at once, so a slow link is spent on a few things that
///      finish instead of many that do not. Serialising a saturated link is faster in wall-clock terms
///      for the job that matters, which is the whole point.
///   2. **Background work yields.** While anything urgent is running or waiting, background work does
///      not start. Opening radar does not have to out-race a chart prefetch.
///   3. **The pilot can see and steer it.** The queue is visible, categories can be paused, and a
///      queued job can be pulled to the front.
///
/// This is deliberately NOT a bandwidth limiter or a scheduler with preemption. A job already in
/// flight is left alone — cancelling a half-finished transfer wastes the bytes it already spent, which
/// on a bad link is the opposite of helping. What is controlled is what STARTS next.
@MainActor
final class NetworkActivity: ObservableObject {
    static let shared = NetworkActivity()

    // MARK: Vocabulary

    /// Plain-language grouping, chosen so a pilot can decide what to pause without knowing the
    /// architecture. These are the words that appear on screen.
    enum Category: String, CaseIterable, Identifiable, Codable {
        case radar, weather, hazards, plates, charts, navData, landability, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .radar:       return "Radar"
            case .weather:     return "Weather reports"
            case .hazards:     return "TFRs & NOTAMs"
            case .plates:      return "Approach plates"
            case .charts:      return "Chart packs"
            case .navData:     return "Procedures & airports"
            case .landability: return "Landability packs"
            case .other:       return "Other"
            }
        }

        /// Why a pilot might leave it on, or switch it off. Shown under the row.
        var blurb: String {
            switch self {
            case .radar:       return "Precipitation imagery for the map."
            case .weather:     return "METARs, TAFs, forecasts and winds aloft."
            case .hazards:     return "Temporary flight restrictions and NOTAMs."
            case .plates:      return "Approach plate PDFs you open or download."
            case .charts:      return "Sectional and IFR tile packs, including the ones loaded ahead of you."
            case .navData:     return "Coded procedures, airports, and the plate index."
            case .landability: return "Off-field landing terrain packs."
            case .other:       return "Everything else."
            }
        }

        /// Pausing these would take away something a pilot may be relying on in the air, so the UI
        /// warns rather than silently obeying. Nothing is forbidden — it is their aircraft.
        var isFlightCritical: Bool {
            self == .radar || self == .weather || self == .hazards
        }
    }

    /// How badly this job is wanted. `urgent` means a human is waiting for it on screen right now.
    enum Priority: Int, Comparable, Codable {
        case background = 0     // nobody asked: prefetch, pre-cache, currency sweeps
        case normal = 1         // the pilot started it and walked away: a bulk download
        case urgent = 2         // the pilot is looking at the spinner
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .background: return "Background"
            case .normal:     return "Requested"
            case .urgent:     return "Needed now"
            }
        }
    }

    enum State: Equatable {
        case queued, running, paused, finished, failed(String), cancelled
        var isActive: Bool { self == .queued || self == .running || self == .paused }
    }

    struct Job: Identifiable, Equatable {
        let id: UUID
        let label: String               // "Radar — 10 min loop", "Chart pack: Denver"
        let category: Category
        var priority: Priority
        var state: State
        var bytes: Int                  // transferred so far, when the caller reports it
        let queuedAt: Date
        var startedAt: Date?

        /// How long the pilot has been waiting on this one.
        func age(_ now: Date = Date()) -> TimeInterval { now.timeIntervalSince(queuedAt) }
    }

    // MARK: Observable state

    @Published private(set) var jobs: [Job] = []
    /// Categories the pilot has switched off. Jobs in them queue and wait rather than failing —
    /// a paused download that silently errored would be worse than one that visibly waits.
    @Published private(set) var pausedCategories: Set<Category> = []
    /// How many jobs may run at once. Lowered on a metered or constrained link, where parallelism
    /// is actively harmful: the same bytes arrive either way, but serialised they arrive in an order
    /// somebody chose.
    @Published private(set) var concurrencyLimit: Int = 3

    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var activeJobs: [Job] { jobs.filter { $0.state.isActive } }
    var runningCount: Int { jobs.filter { $0.state == .running }.count }

    /// A one-line summary for a status pill: "3 waiting · radar first".
    var summary: String? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        let running = active.filter { $0.state == .running }.count
        let waiting = active.count - running
        var s = "\(running) running"
        if waiting > 0 { s += " · \(waiting) waiting" }
        return s
    }

    // MARK: The admission rule

    /// Whether `candidate` may start, given what is already running and waiting.
    ///
    /// PURE, AND SEPARATE FROM THE QUEUE ON PURPOSE. This is the whole behaviour of the feature, and
    /// a scheduler is the kind of code whose bugs appear only under a load you cannot reproduce by
    /// hand. Keeping the decision a function of plain values means the rules can be tested
    /// exhaustively (`NetworkActivityTests`) rather than inferred from a stall in the cockpit.
    ///
    /// The rules, in order:
    ///   * A paused category never starts. It waits; it does not fail.
    ///   * Urgent work ignores the concurrency limit. A pilot staring at a radar spinner should not
    ///     wait on a queue slot — one extra connection costs little, and being wrong here costs the
    ///     thing the feature exists to protect.
    ///   * Background work waits while ANY higher-priority job is running or waiting. This is the
    ///     rule that stops a chart prefetch from out-racing the radar.
    ///   * Otherwise, first-come within the limit.
    nonisolated static func mayStart(
        candidate: Priority,
        categoryPaused: Bool,
        running: [Priority],
        waitingAhead: [Priority],
        limit: Int
    ) -> Bool {
        if categoryPaused { return false }
        if candidate == .urgent { return true }
        if candidate == .background {
            if running.contains(where: { $0 > .background }) { return false }
            if waitingAhead.contains(where: { $0 > .background }) { return false }
        }
        if waitingAhead.contains(where: { $0 > candidate }) { return false }
        return running.count < max(1, limit)
    }

    // MARK: Running work

    /// Register a job, wait for a turn, run it, and report the outcome.
    ///
    /// The work closure is the caller's existing network call, unchanged. Everything here is
    /// bookkeeping around it, so adopting this at a call site is one line and cannot alter what the
    /// call does — only when it starts.
    /// `throws`, not `rethrows`, because this can fail for a reason the WORK did not: the pilot
    /// stopped it while it was waiting. With `rethrows` a non-throwing closure made that
    /// inexpressible, and the only way to return was to run the work anyway — a Stop button whose
    /// effect is to start the download immediately. Every caller already sits inside `try`/`try?`
    /// because `URLSession` throws, so nothing at the call sites changed.
    @discardableResult
    func run<T>(_ label: String,
                category: Category,
                priority: Priority = .normal,
                _ work: @escaping () async throws -> T) async throws -> T {
        let id = UUID()
        jobs.append(Job(id: id, label: label, category: category, priority: priority,
                        state: .queued, bytes: 0, queuedAt: Date(), startedAt: nil))
        trim()
        await waitForTurn(id)
        defer { pump() }

        guard let i = index(id) else { throw CancellationError() }   // dropped from the list entirely
        guard jobs[i].state != .cancelled else { throw CancellationError() }
        update(id) { $0.state = .running; $0.startedAt = Date() }
        do {
            let out = try await work()
            update(id) { $0.state = .finished }
            return out
        } catch {
            update(id) { $0.state = .failed(Self.plainError(error)) }
            throw error
        }
    }

    /// Park until the admission rule says this job may start.
    private func waitForTurn(_ id: UUID) async {
        while true {                                            // bounded by pump()/cancel (rule 2)
            guard let i = index(id) else { return }             // gone — run() turns this into a throw
            let me = jobs[i]
            if me.state == .cancelled { return }                // run() throws CancellationError
            let ahead = jobs.prefix(i).filter { $0.state == .queued || $0.state == .paused }.map(\.priority)
            let running = jobs.filter { $0.state == .running }.map(\.priority)
            if Self.mayStart(candidate: me.priority,
                             categoryPaused: pausedCategories.contains(me.category),
                             running: running, waitingAhead: Array(ahead), limit: concurrencyLimit) {
                return
            }
            update(id) { $0.state = pausedCategories.contains($0.category) ? .paused : .queued }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters[id] = c
            }
        }
    }

    /// Wake every waiter so each re-evaluates the rule. Called whenever the answer could have
    /// changed: a job finished, a pause flipped, a priority was raised, the limit moved.
    ///
    /// Waking all of them rather than picking a winner keeps the decision in ONE place — the rule
    /// above — instead of splitting it between an admission test and a scheduling heuristic that can
    /// disagree with it. The cost is a few resumed continuations that immediately park again.
    private func pump() {
        let waking = waiters
        waiters.removeAll()
        for (_, c) in waking { c.resume() }
    }

    // MARK: Pilot controls

    func setPaused(_ category: Category, _ paused: Bool) {
        if paused { pausedCategories.insert(category) } else { pausedCategories.remove(category) }
        for i in jobs.indices where jobs[i].category == category && jobs[i].state.isActive {
            if jobs[i].state != .running {
                jobs[i].state = paused ? .paused : .queued
            }
        }
        pump()
    }

    func isPaused(_ category: Category) -> Bool { pausedCategories.contains(category) }

    /// Pull a queued job to the front and mark it as wanted now. Does not disturb anything already
    /// running — see the note at the top about not throwing away bytes already spent.
    func prioritise(_ id: UUID) {
        guard let i = index(id), jobs[i].state != .running else { return }
        var job = jobs.remove(at: i)
        job.priority = .urgent
        job.state = .queued
        pausedCategories.remove(job.category)      // asking for it IS unpausing it
        jobs.insert(job, at: 0)
        pump()
    }

    /// Stop a job that has not started. A RUNNING job is deliberately not stoppable: the bytes it
    /// has already pulled are spent either way, and on a bad link throwing them away to start over
    /// is the opposite of helping. The UI only offers this on jobs that are still waiting.
    func cancel(_ id: UUID) {
        guard let i = index(id), jobs[i].state != .running else { return }
        jobs[i].state = .cancelled
        pump()
    }

    /// Reported by callers that know their transfer size, so the UI can say "4.2 MB so far".
    func report(_ id: UUID, bytes: Int) { update(id) { $0.bytes = bytes } }

    /// Narrow the pipe on a link that cannot use it. Called by whoever knows the path state.
    func setConcurrencyLimit(_ n: Int) {
        concurrencyLimit = max(1, min(8, n))
        pump()
    }

    /// Match the queue depth to the link.
    ///
    /// On a cellular or metered path, running three transfers at once does not move more bytes —
    /// it divides the same bytes among three jobs so that all three finish late. One at a time
    /// means the first thing in the queue finishes FIRST, and on a bad link the first thing is the
    /// thing the pilot asked for. Urgent work is exempt from the limit either way, so narrowing it
    /// cannot delay the radar frame; it only stops background work from fanning out behind it.
    func refreshLimitFromPath() async {
        let path = await DownloadPolicy.currentPath()
        setConcurrencyLimit(path.expensive || path.constrained ? 1 : 3)
    }

    // MARK: Housekeeping

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = index(id) else { return }
        change(&jobs[i])
    }

    /// Keep a short tail of finished jobs for the "what just happened" read, and bound the array.
    private func trim() {
        guard jobs.count > 60 else { return }
        var kept: [Job] = []
        var finished = 0
        for job in jobs.reversed() {
            if job.state.isActive { kept.append(job); continue }
            finished += 1
            if finished <= 20 { kept.append(job) }
        }
        jobs = kept.reversed()
    }

    /// Error text a pilot can act on, not an NSError dump.
    nonisolated static func plainError(_ error: Error) -> String {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): return "No connection."
        case (NSURLErrorDomain, NSURLErrorTimedOut):               return "Timed out."
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):  return "Connection dropped."
        case (NSURLErrorDomain, NSURLErrorCancelled):              return "Cancelled."
        default: return "Did not finish."
        }
    }
}

// MARK: - Drop-in wrappers for the call sites

/// Thin equivalents of the `URLSession.shared` calls this app already makes. Adopting the queue at a
/// call site is a one-line substitution that cannot change what the request DOES — only when it
/// starts and whether the pilot can see it. That property is what made it safe to convert every
/// network path in the app in one pass.
extension NetworkActivity {
    @MainActor
    static func data(for req: URLRequest, _ label: String, _ category: Category,
                     _ priority: Priority = .normal) async throws -> (Data, URLResponse) {
        try await shared.run(label, category: category, priority: priority) {
            try await URLSession.shared.data(for: req)
        }
    }

    @MainActor
    static func download(for req: URLRequest, _ label: String, _ category: Category,
                         _ priority: Priority = .normal) async throws -> (URL, URLResponse) {
        try await shared.run(label, category: category, priority: priority) {
            try await URLSession.shared.download(for: req)
        }
    }

    @MainActor
    static func download(from url: URL, _ label: String, _ category: Category,
                         _ priority: Priority = .normal) async throws -> (URL, URLResponse) {
        try await shared.run(label, category: category, priority: priority) {
            try await URLSession.shared.download(from: url)
        }
    }
}
