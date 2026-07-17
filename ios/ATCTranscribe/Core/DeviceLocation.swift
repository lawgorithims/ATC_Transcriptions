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
    private let manager = CLLocationManager()
    private var running = false
    var isRunning: Bool { running }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Duty-cycle: only deliver a fix once the position moves ~15 m, so a parked/idle aircraft doesn't
        // stream sub-metre jitter that re-renders the map every second (battery). The activity type lets iOS
        // duty-cycle the GPS radio itself when stationary; auto-pause is off so an EFB never silently stops.
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
        coord = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        courseDeg = l.course >= 0 ? l.course : nil
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
