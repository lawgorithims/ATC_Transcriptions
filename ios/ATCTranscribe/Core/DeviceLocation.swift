import Foundation
import CoreLocation

/// Continuous device-GPS ownship — for the cockpit iPad/iPhone with NO Stratux. A plain (non-@MainActor)
/// object like `OneShotLocation`: `CLLocationManager` is created on the main thread and delivers its
/// callbacks there, and the project's Swift 5 mode doesn't enforce actor isolation on the delegate.
///
/// Observed DIRECTLY by the views that plot ownship (map + plate viewer) — a nested ObservableObject on
/// AppModel doesn't republish its parent (see the Flight Bag C2 fix). GPS lifecycle is owned by the
/// always-mounted home map (MapHostView starts it once) and paused/resumed by scene phase, so it's a
/// single session that the other tabs only READ (they no longer start/stop it, which used to leave the
/// map's ownship marker frozen). The map draws its own ownship symbol from this feed — MKMapView's
/// built-in `showsUserLocation` (a redundant second GPS session) is off.
///
/// Every fix is also folded into `GPSIntegrityMonitor`, which is why `DeviceFix` carries the receiver's
/// uncertainty estimates as well as its position: iOS exposes no DOP, satellite count or raw GNSS, so the
/// only integrity evidence available is those estimates plus the disagreement between position and
/// velocity. `integrity` is what the map, the banner and the GPS bar read to decide whether the fix can
/// be trusted at all.
final class DeviceLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coord: Coord?
    @Published private(set) var courseDeg: Double?      // true course when moving (>= 0), else nil
    @Published private(set) var fix: DeviceFix?         // full snapshot (alt/speed/accuracy) for the GPS readout
    /// Current integrity verdict — drives the accuracy ring, the ownship colour, the threat banner.
    @Published private(set) var integrity = GPSIntegrityAssessment()

    /// Position to PLOT: nil whenever integrity says the fix can't be trusted. A position the pilot will
    /// fly is worse than no position, so an unreliable / suspect state removes the symbol entirely.
    var trustedCoord: Coord? { integrity.shouldSuppressOwnship ? nil : coord }

    private let manager = CLLocationManager()
    private let monitor = GPSIntegrityMonitor()
    private var running = false
    var isRunning: Bool { running }
    /// A fix that simply STOPS arriving has no callback, so the monitor is re-evaluated on this cadence.
    /// (The monitor gates staleness on motion — with `distanceFilter` a parked aircraft is legitimately
    /// silent, so only a moving fix that goes quiet counts.)
    private var staleTimer: Timer?
    private static let staleTickS: TimeInterval = 5

    /// Bounded log of this session's integrity state transitions (diagnostics / flight log).
    var integrityEvents: [GPSIntegrityEvent] { monitor.events }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // The 15 m distance filter suppresses sub-metre jitter deliveries so a parked aircraft doesn't
        // re-render the map every second. NOTE: with `pausesLocationUpdatesAutomatically = false` the GPS
        // radio itself is NOT duty-cycled — that's a deliberate tradeoff (an EFB must never silently stop
        // tracking on the ramp/run-up), accepting the steady radio draw. `activityType` only tunes iOS's
        // filtering heuristics, it does not pause the radio while auto-pause is off. (This out-of-process
        // `locationd` cost is invisible to the in-app CPU sampler — it is a battery, not a cpu%, contributor.)
        manager.distanceFilter = 15
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Begin continuous updates if authorized (asks once if undetermined; updates then begin in
    /// `locationManagerDidChangeAuthorization`). Idempotent.
    func start() {
        guard !running else { return }
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:                       manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: startFeed()
        default:                                   running = false      // denied / restricted — stay silent
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        staleTimer?.invalidate()
        staleTimer = nil
        monitor.reset()                     // a resumed session must not diff across the paused gap
        integrity = GPSIntegrityAssessment()
    }

    deinit { staleTimer?.invalidate() }

    /// Feed + staleness tick start together and stop together — one lifecycle, so no timer outlives the
    /// feed it watches.
    private func startFeed() {
        manager.startUpdatingLocation()
        staleTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.staleTickS, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.integrity = self.monitor.tick(now: Date())
        }
        t.tolerance = 1                     // let the OS coalesce it — not a precision timer
        staleTimer = t
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, l.horizontalAccuracy >= 0 else { return }   // negative accuracy = invalid
        let c = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        let f = Self.widen(l, coord: c)
        let verdict = monitor.ingest(f)
        assert(f.horizontalAccuracyM >= 0, "a widened fix must carry a valid accuracy")
        coord = c
        // Course is published only when the monitor trusts it: below taxi speed, or outside its 1-sigma
        // limit, GPS course is noise and must not drive a heading-up rotation or a wind-correction angle.
        courseDeg = verdict.courseUsable ? f.courseDeg : nil
        fix = f
        integrity = verdict
    }

    /// Widen a `CLLocation` into the app's fix record. Every CoreLocation invalid sentinel is resolved
    /// HERE (speed/course < 0, verticalAccuracy <= 0 all mean "not available") so nothing downstream can
    /// mistake a sentinel for a measurement.
    private static func widen(_ l: CLLocation, coord c: Coord) -> DeviceFix {
        assert(l.horizontalAccuracy >= 0, "caller must reject invalid fixes")
        var f = DeviceFix(coord: c,
                          altitudeMSLm: l.verticalAccuracy > 0 ? l.altitude : nil,
                          groundSpeedMps: l.speed >= 0 ? l.speed : nil,
                          courseDeg: l.course >= 0 ? l.course : nil,
                          horizontalAccuracyM: l.horizontalAccuracy)
        f.timestamp = l.timestamp
        f.verticalAccuracyM = l.verticalAccuracy > 0 ? l.verticalAccuracy : nil
        f.speedAccuracyMps = l.speedAccuracy >= 0 ? l.speedAccuracy : nil
        f.courseAccuracyDeg = l.courseAccuracy >= 0 ? l.courseAccuracy : nil
        if #available(iOS 15.0, macOS 12.0, *) {
            f.altitudeEllipsoidalM = l.verticalAccuracy > 0 ? l.ellipsoidalAltitude : nil
            // On a real device this flag means someone is feeding the app a fake position — a hard spoof
            // signal. In the SIMULATOR every fix is software-generated, so the flag carries no information
            // there; honouring it would pin the app to `suspect`, hide ownship, and make the Simulator QA
            // pass (and the UI tests) meaningless.
            #if targetEnvironment(simulator)
            f.isSimulated = false
            #else
            f.isSimulated = l.sourceInformation?.isSimulatedBySoftware ?? false
            #endif
        }
        return f
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard running else { return }
        switch m.authorizationStatus {
        // MUST go through startFeed(), not startUpdatingLocation() alone: this is the deferred-grant
        // path taken on a FRESH INSTALL (start() hit `.notDetermined` and only asked for permission).
        // startFeed() is the sole place the staleness timer is scheduled, and that timer is the only
        // thing that runs the jam / lost-lock detector. Calling startUpdatingLocation() here would begin
        // the fix stream with no staleness timer, so a GPS that went quiet in flight during the first
        // session would never escalate to unreliable — it would keep drawing the last position as
        // trusted ownship, the exact unsafe-direction failure the timer exists to prevent.
        case .authorizedWhenInUse, .authorizedAlways: startFeed()
        default:                                       running = false
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
