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
final class DeviceLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coord: Coord?
    @Published private(set) var courseDeg: Double?      // true course when moving (>= 0), else nil
    @Published private(set) var fix: DeviceFix?         // full snapshot (alt/speed/accuracy) for the GPS readout
    private let manager = CLLocationManager()
    private var running = false
    var isRunning: Bool { running }

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
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default:                                   running = false      // denied / restricted — stay silent
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, l.horizontalAccuracy >= 0 else { return }   // negative accuracy = invalid
        let c = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        coord = c
        courseDeg = l.course >= 0 ? l.course : nil
        // Full snapshot for the GPS readout widget (map/plate paths only read coord/courseDeg — unchanged).
        // CoreLocation invalid sentinels resolved here: speed/course < 0 and verticalAccuracy <= 0 → nil.
        fix = DeviceFix(coord: c,
                        altitudeMSLm: l.verticalAccuracy > 0 ? l.altitude : nil,
                        groundSpeedMps: l.speed >= 0 ? l.speed : nil,
                        courseDeg: l.course >= 0 ? l.course : nil,
                        horizontalAccuracyM: l.horizontalAccuracy)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard running else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.startUpdatingLocation()
        default:                                       running = false
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
