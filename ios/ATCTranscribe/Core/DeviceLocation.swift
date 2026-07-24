import Foundation
import CoreLocation

/// Continuous device-GPS ownship — for the cockpit iPad/iPhone with NO Stratux. A plain (non-@MainActor)
/// object like `OneShotLocation`: `CLLocationManager` is created on the main thread and delivers its
/// callbacks there, and the project's Swift 5 mode doesn't enforce actor isolation on the delegate.
///
/// Observed DIRECTLY by the views that plot ownship (the plate viewer) — a nested ObservableObject on
/// AppModel doesn't republish its parent (see the Flight Bag C2 fix). Started only while a view needs it
/// (start/stop with the plate viewer's lifecycle) so it isn't a battery drain the rest of the time; the
/// map uses MKMapView's own `showsUserLocation` blue dot separately.
///
/// This is also the app's SINGLE GPS owner (the build-62 battery rule: exactly one `CLLocationManager`,
/// no second subscriber), so the integrity monitor lives here rather than in a parallel feed. Each
/// `CLLocation` is widened into a `GPSFix` — accuracy, velocity uncertainty, both altitude references —
/// and folded into `GPSIntegrityMonitor`; `integrity` is what the map / banner read to decide whether
/// the position can be trusted. The cost of that: `desiredAccuracy` is now `Best` rather than
/// nearest-ten-metres (an integrity check on a deliberately coarsened fix is meaningless), which draws
/// more power WHILE THE FEED RUNS — unchanged when it doesn't, and the start/stop lifecycle is untouched.
final class DeviceLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Raw last-known position — for centering / "roughly where am I", NOT for plotting ownship.
    @Published private(set) var coord: Coord?
    @Published private(set) var courseDeg: Double?      // true course when moving AND trustworthy, else nil
    /// The full widened last fix (nil until one arrives).
    @Published private(set) var fix: GPSFix?
    /// Current integrity verdict — drives the accuracy ring, the ownship colour and the banner.
    @Published private(set) var integrity = GPSIntegrityAssessment()

    /// Position to PLOT: nil whenever integrity says the fix can't be trusted. A position the pilot will
    /// fly is worse than no position, so an unreliable / suspect state removes the symbol entirely.
    var trustedCoord: Coord? { integrity.shouldSuppressOwnship ? nil : coord }

    private let manager = CLLocationManager()
    private let monitor = GPSIntegrityMonitor()
    private var running = false
    /// How many views currently need the feed. The plate viewer is no longer the only holder (the map
    /// now draws ownship from this feed instead of MapKit's own location manager), and without a count
    /// closing a plate would stop the map's GPS out from under it.
    private var holders = 0
    private static let maxHolders = 8
    /// Staleness has no callback — a fix that simply STOPS arriving (jamming, lost lock) is only visible
    /// on a timer, so the monitor is re-evaluated on this cadence while the feed runs.
    private var staleTimer: Timer?
    private static let staleTickS: TimeInterval = 5

    /// Bounded log of this session's integrity state transitions (for the diagnostics view / log).
    var integrityEvents: [GPSIntegrityEvent] { monitor.events }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // An OS-paused feed looks exactly like a stale fix; an EFB in flight must not be auto-paused.
        manager.pausesLocationUpdatesAutomatically = false
    }

    deinit { staleTimer?.invalidate() }

    /// Take a hold on the feed, starting it if this is the first (asks for authorization once if
    /// undetermined; updates then begin in `locationManagerDidChangeAuthorization`). Balanced by `stop`.
    func start() {
        holders = min(holders + 1, Self.maxHolders)
        assert(holders > 0 && holders <= Self.maxHolders, "hold count out of range")
        guard !running else { return }
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:                       manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: startFeed()
        default:                                   running = false      // denied / restricted — stay silent
        }
    }

    /// Release one hold; the feed (and its GPS draw) stops only when the last holder goes away.
    func stop() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        running = false
        manager.stopUpdatingLocation()
        staleTimer?.invalidate()
        staleTimer = nil
        monitor.reset()                       // a resumed session must not diff across the stopped gap
        integrity = GPSIntegrityAssessment()
        fix = nil
    }

    /// Feed + staleness tick start together and stop together — one lifecycle, so no timer can outlive
    /// the feed it watches.
    private func startFeed() {
        manager.startUpdatingLocation()
        staleTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.staleTickS, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.integrity = self.monitor.tick(now: Date())
        }
        t.tolerance = 1                       // let the OS coalesce it — not a precision timer
        staleTimer = t
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, let f = GPSFix(l) else { return }   // nil = negative accuracy, invalid
        assert(f.horizontalAccuracyM >= 0, "a widened fix must carry a valid accuracy")
        assert(running || staleTimer == nil, "no tick timer may outlive the feed")
        let verdict = monitor.ingest(f)
        fix = f
        coord = f.coord
        // Course is published only when the monitor trusts it: below taxi speed, or outside its 1-sigma
        // limit, GPS course is noise and must not drive a heading-up rotation or a wind-correction angle.
        courseDeg = verdict.courseUsable ? f.courseDeg : nil
        integrity = verdict
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard running else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: startFeed()
        default:                                       running = false
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
