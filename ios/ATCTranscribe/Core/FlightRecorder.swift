import Foundation

/// The transient GPS fix the recorder samples — assembled by AppModel from `presentPosition` + the merged
/// `GPSReadout`, so the recorder never imports CoreLocation or opens a 2nd GPS session (it READS the one
/// feed the always-mounted map owns).
struct BreadcrumbFix {
    let coord: Coord
    let altFt: Double?
    let speedKt: Double?
    let track: Double?
    let source: GPSReadout.Source
}

enum RecordingState: Equatable { case idle, recording, recovered }

/// What a recording recovered from disk contains, for the prompt that offers it back to the pilot.
///
/// ⚠️ THIS TYPE EXISTS BECAUSE THE RECOVERY DID NOT. The crash-safe mirror below has been written on
/// every tenth point since it was added, and `recoverOnLaunch` has always reloaded it — into a
/// `.recovered` state that NOTHING IN THE APP EVER READ. A pilot whose app died mid-flight saw a REC
/// button that said "not recording", pressed it to start again, and `startRecording` reset the
/// accumulators and overwrote the file. The trail survived the crash and was destroyed by the
/// recovery. Reported from the air as "I lost all of my logbook track".
struct RecoveredRecording: Equatable {
    let startedAt: Date
    /// Last breadcrumb — NOT `Date()`. The app was not running in between, and billing the pilot for
    /// the hours it was shut would put a false duration in the logbook.
    let lastPointAt: Date
    let points: Int
    let distanceNM: Double
    var duration: TimeInterval { max(lastPointAt.timeIntervalSince(startedAt), 0) }
}

/// The crash-safe on-disk mirror of an in-progress recording (survives an app kill / a long flight).
private struct ActiveRecording: Codable {
    var startedAt: Date
    var aircraftCallsign: String?
    var points: [Breadcrumb]
    var stops: [FlightStop]
    var distanceNM: Double
    var maxSpeedKt: Double
    var maxAltFt: Double
    var movingTimeSec: TimeInterval
    var stoppedSince: Date?
}

/// Records the flight: on a timer while recording it samples the merged GPS into a breadcrumb trail, keeps
/// running metrics (distance / max+avg speed / max altitude / moving time) and detects stops (stationary
/// dwell → a leg boundary, tagged with the nearest airport). On stop it builds a `LoggedFlight`. Structural
/// twin of `BatteryDiagnostics` (main-actor sampler task, foreground-gated, atomic JSON persistence).
@MainActor final class FlightRecorder: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var trail: [Breadcrumb] = []          // the map bridges this (append-only per session)
    @Published private(set) var stops: [FlightStop] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var distanceNM: Double = 0
    @Published var recoveredPendingSave: LoggedFlight?           // a flight that was awaiting its save prompt at a crash

    /// Injected by AppModel: the current merged fix (nil when there's no GPS). The recorder's only input.
    var fixProvider: (() -> BreadcrumbFix?)?

    // Tuning
    private let tickSeconds: UInt64 = 2
    private let minSampleDistanceNM = 0.02      // ~37 m move gate (below this = jitter, not travel)
    private let heartbeatSec: TimeInterval = 15 // a parked plane still logs ~4 pts/min (not thousands)
    private let maxPoints = 20_000              // ~11 h moving; downsampled in place at the cap (rule 2)
    private let maxStops = 200
    private let stopSpeedKt = 3.0, taxiSpeedKt = 5.0
    private let stopDwellSec: TimeInterval = 120
    private let persistEveryNPoints = 10
    /// ⚠️ AND ON A CLOCK, because the point count alone leaves a hole. A parked or slow aircraft only
    /// appends on the 15 s heartbeat, so ten points is two and a half minutes of exposure — and the
    /// taxi and run-up before departure are exactly when a pilot is also loading plates and charts,
    /// which is when the app is most likely to be killed for memory.
    private let persistEverySec: TimeInterval = 20

    private var samplerTask: Task<Void, Never>?
    private var foregrounded = true
    private var aircraftCallsign: String?
    private var lastPoint: Breadcrumb?
    private var maxSpeedKt = 0.0, maxAltFt = 0.0, movingTimeSec: TimeInterval = 0
    private var stoppedSince: Date?
    private var openStopIndex: Int?
    private var pointsSincePersist = 0
    private var lastPersistAt = Date.distantPast

    var isRecording: Bool { state == .recording }

    /// A recording reloaded from disk after the app died, waiting for the pilot to resume or save it.
    /// nil in every other state.
    var recovered: RecoveredRecording? {
        guard state == .recovered, let start = startedAt, let last = trail.last else { return nil }
        return RecoveredRecording(startedAt: start, lastPointAt: last.t,
                                  points: trail.count, distanceNM: distanceNM)
    }

    /// `directory` is injectable so a test can exercise the crash-and-recover path against a temp
    /// folder. It defaults to Application Support, which is where a real recording lives — and tests
    /// MUST pass their own, because `recoverOnLaunch` runs from this initialiser and a test that
    /// shared the app's folder could both read a pilot's real in-progress flight and overwrite it.
    init(directory: URL? = nil) {
        dir = directory ?? Self.defaultDirectory
        recoverOnLaunch()
    }

    // MARK: control

    func startRecording(aircraftCallsign tail: String?) {
        assert(state != .recording, "startRecording while already recording")
        // ⚠️ REFUSES OVER A RECOVERED RECORDING, AND THAT GUARD IS THE WHOLE BUG. Without it the next
        // line resets the accumulators and the one after that overwrites the on-disk mirror, so the
        // first tap of REC after a crash destroyed the flight the crash had spared. A recovered
        // recording is ended by `resumeRecovered`, `stopRecording` or `discardRecovered` — all three
        // of which the pilot reaches from the banner — never by implicitly starting a new one.
        guard state != .recovered else { return }
        resetAccumulators()
        aircraftCallsign = tail
        startedAt = Date()
        state = .recording
        persistActive()
        startSampler()
        assert(trail.isEmpty && startedAt != nil, "startRecording: dirty start")
    }

    /// Stop and produce the finished flight (breadcrumb downsampled to the logbook cap). Persists it to a
    /// pending slot so a crash during the save prompt can't lose it. Returns nil if nothing was recorded.
    func stopRecording() -> LoggedFlight? {
        guard state == .recording || state == .recovered, let start = startedAt else { return nil }
        stopSampler()
        // A recovered flight ended when its last breadcrumb was laid down, not now: the app was shut
        // in between, and `Date()` here would log the hours it spent closed as time in the air.
        let end = state == .recovered ? (trail.last?.t ?? start) : Date()
        let flight = buildFlight(start: start, end: end)
        state = .idle
        trail = []; stops = []; startedAt = nil; distanceNM = 0
        deleteFile(activeURL)
        if let flight { recoveredPendingSave = nil; persistPending(flight) }
        assert(state == .idle, "stopRecording: state not reset")
        return flight
    }

    func resumeRecovered() { guard state == .recovered else { return }; state = .recording; startSampler() }
    func discardRecovered() {
        guard state == .recovered else { return }
        state = .idle; trail = []; stops = []; startedAt = nil; distanceNM = 0; deleteFile(activeURL)
    }
    func clearPendingSave() { recoveredPendingSave = nil; deleteFile(pendingURL) }

    /// Scene-phase gating (from AppModel.handleScenePhase). Backgrounding flushes so no fix is lost; note the
    /// app uses WhenInUse GPS so the trail HAS a time gap while backgrounded — honest, and crash-safe on disk.
    func setForegrounded(_ active: Bool) {
        foregrounded = active
        guard state == .recording else { return }
        active ? startSampler() : { persistActive(); stopSampler() }()
    }

    // MARK: sampler

    private func startSampler() {
        guard samplerTask == nil, foregrounded, state == .recording else { return }
        // ⚠️ `Task {}` INHERITS this @MainActor context, so `tick()` is a plain main-actor call — the sleep is
        // the loop's only suspension point. An `await` on it is inert (and warns); it never bought a hop.
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {                                 // bounded by cancellation (rule 2)
                try? await Task.sleep(nanoseconds: (self?.tickSeconds ?? 2) * 1_000_000_000)
                self?.tick()
            }
        }
    }
    private func stopSampler() { samplerTask?.cancel(); samplerTask = nil }

    #if DEBUG
    /// Drive one sample synchronously. The sampler is a 2-second timer and a deterministic test cannot
    /// wait on it; same pattern and same reason as `CIFP.reopenForTests`. Test-only — the branch does
    /// not exist in a release build.
    func forceSampleForTests() { tick() }
    #endif

    private func tick() {
        guard state == .recording, let fix = fixProvider?() else { return }   // no fix → skip; timer keeps running
        guard fix.coord.lat.isFinite, fix.coord.lon.isFinite else { return }
        let now = Date()
        if shouldAppend(fix, now: now) { append(fix, now: now) }
    }

    private func shouldAppend(_ fix: BreadcrumbFix, now: Date) -> Bool {
        guard let last = lastPoint else { return true }              // first point always
        let seg = Geo.nmBetween(last.coord, fix.coord)
        return seg >= minSampleDistanceNM || now.timeIntervalSince(last.t) >= heartbeatSec
    }

    private func append(_ fix: BreadcrumbFix, now: Date) {
        let point = Breadcrumb(t: now, lat: fix.coord.lat, lon: fix.coord.lon,
                               altFt: fix.altFt, speedKt: fix.speedKt, track: fix.track)
        accumulate(point, fix: fix, now: now)
        trail.append(point)
        lastPoint = point
        if trail.count >= maxPoints { downsample() }
        pointsSincePersist += 1
        if pointsSincePersist >= persistEveryNPoints
            || now.timeIntervalSince(lastPersistAt) >= persistEverySec {
            pointsSincePersist = 0
            persistActive()
        }
        assert(trail.count <= maxPoints, "append: trail exceeded cap")
        assert(distanceNM >= 0, "append: negative distance")
    }

    /// Running metrics + stop detection. Distance/time accumulate BEFORE any downsampling, so dropping stored
    /// points never loses them (the scalars are authoritative, the trail is just for drawing).
    private func accumulate(_ point: Breadcrumb, fix: BreadcrumbFix, now: Date) {
        guard let last = lastPoint else { maxAltFt = fix.altFt ?? 0; return }
        let dt = now.timeIntervalSince(last.t)
        let seg = Geo.nmBetween(last.coord, point.coord)
        let effSpeed = fix.speedKt ?? (dt > 0 ? seg / (dt / 3600) : 0)
        if seg >= minSampleDistanceNM { distanceNM += seg }         // jitter under the gate never inflates distance
        maxAltFt = max(maxAltFt, fix.altFt ?? 0)
        maxSpeedKt = max(maxSpeedKt, effSpeed)
        if effSpeed >= taxiSpeedKt { movingTimeSec += dt }
        detectStop(point, effSpeed: effSpeed, now: now)
    }

    private func detectStop(_ point: Breadcrumb, effSpeed: Double, now: Date) {
        if effSpeed <= stopSpeedKt {
            let since = stoppedSince ?? now
            stoppedSince = since
            if now.timeIntervalSince(since) >= stopDwellSec {
                if let i = openStopIndex, stops.indices.contains(i) {
                    stops[i].durationSec = now.timeIntervalSince(since)
                } else {
                    let stop = FlightStop(id: UUID(), lat: point.lat, lon: point.lon, arrivedAt: since,
                                          durationSec: now.timeIntervalSince(since), airport: nil)
                    if stops.count >= maxStops { stops.removeFirst() }
                    stops.append(stop); openStopIndex = stops.count - 1
                    resolveAirport(for: stop.id, coord: point.coord)
                    _ = stop
                }
            }
        } else { stoppedSince = nil; openStopIndex = nil }          // moving again → close any open stop
    }

    /// Nearest FAA airport within a few NM, resolved OFF-MAIN (NavDatabase.nearby scans ~90k idents) and
    /// patched back onto the stop on the main actor.
    private func resolveAirport(for id: UUID, coord: Coord) {
        Task.detached(priority: .utility) { [weak self] in
            let d = 0.1
            let box = BBox(minLat: coord.lat - d, minLon: coord.lon - d, maxLat: coord.lat + d, maxLon: coord.lon + d)
            let near = NavDatabase.nearby(box, types: [0], limit: 8)
                .min { Geo.nmBetween($0.coord, coord) < Geo.nmBetween($1.coord, coord) }
            guard let apt = near, Geo.nmBetween(apt.coord, coord) <= 5 else { return }
            await MainActor.run { [weak self] in
                guard let self, let i = self.stops.firstIndex(where: { $0.id == id }) else { return }
                self.stops[i].airport = apt.ident
            }
        }
    }

    private func downsample() {
        var kept: [Breadcrumb] = []
        for (i, p) in trail.enumerated() where i % 2 == 0 || i == trail.count - 1 { kept.append(p) }  // bounded
        assert(kept.count < trail.count, "downsample: nothing dropped")
        trail = kept
    }

    private func resetAccumulators() {
        trail = []; stops = []; distanceNM = 0; maxSpeedKt = 0; maxAltFt = 0; movingTimeSec = 0
        lastPoint = nil; stoppedSince = nil; openStopIndex = nil; pointsSincePersist = 0
        lastPersistAt = .distantPast
    }

    // MARK: build + persistence

    private func buildFlight(start: Date, end: Date) -> LoggedFlight? {
        guard !trail.isEmpty else { return nil }
        let elapsed = max(end.timeIntervalSince(start), 0)
        let avg = movingTimeSec > 0 ? distanceNM / (movingTimeSec / 3600) : 0
        let crumbs = Self.downsampled(trail, to: LoggedFlight.maxBreadcrumb)
        assert(crumbs.count <= LoggedFlight.maxBreadcrumb, "buildFlight: breadcrumb over cap")
        return LoggedFlight(id: UUID(), startedAt: start, endedAt: end, durationSec: elapsed,
                            distanceNM: distanceNM, maxSpeedKt: maxSpeedKt, avgSpeedKt: avg,
                            maxAltFtMSL: maxAltFt, stops: stops, aircraftCallsign: aircraftCallsign,
                            aircraftType: nil, notes: "", breadcrumb: crumbs)
    }

    /// Even-stride downsample keeping first + last. Bounded; >=2 assertions.
    static func downsampled(_ pts: [Breadcrumb], to cap: Int) -> [Breadcrumb] {
        assert(cap >= 2, "downsampled: cap too small")
        guard pts.count > cap else { return pts }
        let stride = Int((Double(pts.count) / Double(cap)).rounded(.up))
        assert(stride >= 1, "downsampled: bad stride")
        var out: [Breadcrumb] = []
        for (i, p) in pts.enumerated() where i % stride == 0 { out.append(p) }   // bounded by pts.count
        if let last = pts.last, out.last != last { out.append(last) }
        return out
    }

    private func recoverOnLaunch() {
        if let d = try? Data(contentsOf: pendingURL),
           let f = try? JSONDecoder().decode(LoggedFlight.self, from: d) { recoveredPendingSave = f }
        guard let d = try? Data(contentsOf: activeURL),
              let a = try? JSONDecoder().decode(ActiveRecording.self, from: d), !a.points.isEmpty else { return }
        trail = a.points; stops = a.stops; startedAt = a.startedAt; aircraftCallsign = a.aircraftCallsign
        distanceNM = a.distanceNM; maxSpeedKt = a.maxSpeedKt; maxAltFt = a.maxAltFt
        movingTimeSec = a.movingTimeSec; stoppedSince = a.stoppedSince; lastPoint = a.points.last
        openStopIndex = a.stops.isEmpty ? nil : a.stops.count - 1
        state = .recovered                                          // don't auto-resume the timer (GPS may be down)
    }

    private func persistActive() {
        guard let start = startedAt else { return }
        let a = ActiveRecording(startedAt: start, aircraftCallsign: aircraftCallsign, points: trail, stops: stops,
                                distanceNM: distanceNM, maxSpeedKt: maxSpeedKt, maxAltFt: maxAltFt,
                                movingTimeSec: movingTimeSec, stoppedSince: stoppedSince)
        guard let d = try? JSONEncoder().encode(a) else { return }
        try? d.write(to: activeURL, options: .atomic)
        lastPersistAt = Date()
    }
    private func persistPending(_ flight: LoggedFlight) {
        guard let d = try? JSONEncoder().encode(flight) else { return }
        try? d.write(to: pendingURL, options: .atomic)
    }
    private func deleteFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private static var defaultDirectory: URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
    }
    private let dir: URL
    private var activeURL: URL { dir.appendingPathComponent("flight_recorder_active_v1.json") }
    private var pendingURL: URL { dir.appendingPathComponent("flight_recorder_pending_v1.json") }
}
