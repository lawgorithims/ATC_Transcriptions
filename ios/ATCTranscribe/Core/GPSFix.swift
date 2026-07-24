import Foundation
import CoreLocation

/// ONE position fix with every integrity-bearing field the source exposes — not just lat/lon/course.
///
/// `DeviceLocation` used to keep three fields and drop the rest of each `CLLocation`; the accuracy,
/// velocity-uncertainty and altitude-reference fields it discarded are exactly what an integrity check
/// needs, so this is the widened record every consumer now sees. Pure data (Foundation + CoreLocation
/// types only, no CoreLocation *manager*) so `GPSIntegrityMonitor` is unit-testable with synthesized
/// fixes and never needs a real receiver.
///
/// Sign conventions follow `CLLocation`: an accuracy < 0 means the value is UNAVAILABLE (not "perfect"),
/// and a negative `speed`/`course` means "not computed". The initializer normalizes all of those to nil
/// so no consumer can mistake a sentinel for a measurement.
struct GPSFix: Equatable, Sendable {
    /// Where the fix came from. Only `.device` is produced today; the monitor is source-agnostic, so a
    /// receiver feed (Stratux GDL90) can be added later without touching the detectors.
    enum Source: String, Equatable, Sendable, Codable {
        case device
        case receiver
    }

    var coord: Coord
    var timestamp: Date
    var source: Source = .device

    /// 1-sigma (68%) horizontal radius in metres. Always > 0 — an invalid fix never becomes a `GPSFix`.
    var horizontalAccuracyM: Double
    /// 1-sigma vertical accuracy in metres; nil when the receiver isn't reporting one.
    var verticalAccuracyM: Double?

    /// Altitude above MEAN SEA LEVEL in metres (CoreLocation applies the geoid correction).
    var altitudeMSLm: Double?
    /// Altitude above the WGS-84 ELLIPSOID in metres (iOS 15+). Differs from MSL by the local geoid
    /// undulation — tens of metres in places — which is one reason GPS and baro altitude disagree.
    var altitudeEllipsoidalM: Double?

    var speedMps: Double?             // ground speed; nil when not computed
    var speedAccuracyMps: Double?     // 1-sigma, iOS 13.4+; nil when unavailable
    var courseDeg: Double?            // true course; nil when not computed (i.e. stationary)
    var courseAccuracyDeg: Double?    // 1-sigma, iOS 13.4+; nil when unavailable

    /// The OS says this location was produced by software (Simulator, a mocking tool, a debug profile)
    /// rather than the GNSS chip — iOS 15+. A hard spoof signal on the device side of the chain.
    var isSimulated: Bool = false

    // MARK: - Derived

    var altitudeMSLft: Double? { altitudeMSLm.map { $0 * 3.280839895 } }
    var speedKt: Double? { speedMps.map { $0 * 1.943844492 } }

    /// Geoid undulation (ellipsoidal − MSL) in feet, when both altitudes are present. Explains the
    /// standing GPS-vs-baro offset a pilot sees; nil when the OS gives only one reference.
    var geoidUndulationFt: Double? {
        guard let e = altitudeEllipsoidalM, let m = altitudeMSLm else { return nil }
        return (e - m) * 3.280839895
    }

    // MARK: - Bridge

    /// Widen a `CLLocation`, or nil when the fix carries no usable position (negative horizontal
    /// accuracy is CoreLocation's "invalid" sentinel). Every sentinel-bearing field is normalized here
    /// so the detectors downstream never re-check signs.
    init?(_ l: CLLocation) {
        guard l.horizontalAccuracy >= 0 else { return nil }
        assert(l.horizontalAccuracy.isFinite, "CoreLocation accuracy must be finite")
        self.coord = Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        self.timestamp = l.timestamp
        self.source = .device
        self.horizontalAccuracyM = l.horizontalAccuracy
        self.verticalAccuracyM = l.verticalAccuracy >= 0 ? l.verticalAccuracy : nil
        self.altitudeMSLm = l.verticalAccuracy >= 0 ? l.altitude : nil
        self.speedMps = l.speed >= 0 ? l.speed : nil
        self.speedAccuracyMps = l.speedAccuracy >= 0 ? l.speedAccuracy : nil
        self.courseDeg = l.course >= 0 ? l.course : nil
        self.courseAccuracyDeg = l.courseAccuracy >= 0 ? l.courseAccuracy : nil
        if #available(iOS 15.0, macOS 12.0, *) {
            self.altitudeEllipsoidalM = l.verticalAccuracy >= 0 ? l.ellipsoidalAltitude : nil
            // On a real device this flag means someone is feeding the app a fake position — a hard spoof
            // signal. In the Simulator EVERY fix is software-generated, so the flag carries no
            // information there; honouring it would put the app permanently in `suspect`, hide ownship,
            // and make the Simulator QA pass (and the UI tests) meaningless.
            #if targetEnvironment(simulator)
            self.isSimulated = false
            #else
            self.isSimulated = l.sourceInformation?.isSimulatedBySoftware ?? false
            #endif
        } else {
            self.altitudeEllipsoidalM = nil
            self.isSimulated = false
        }
        assert(horizontalAccuracyM >= 0, "normalized accuracy must be non-negative")
    }

    /// Memberwise construction for tests and for a future non-CoreLocation source.
    init(coord: Coord, timestamp: Date, source: Source = .device,
         horizontalAccuracyM: Double, verticalAccuracyM: Double? = nil,
         altitudeMSLm: Double? = nil, altitudeEllipsoidalM: Double? = nil,
         speedMps: Double? = nil, speedAccuracyMps: Double? = nil,
         courseDeg: Double? = nil, courseAccuracyDeg: Double? = nil,
         isSimulated: Bool = false) {
        assert(horizontalAccuracyM >= 0, "a fix with negative accuracy is invalid, not inaccurate")
        assert((-90...90).contains(coord.lat), "latitude in range")
        self.coord = coord
        self.timestamp = timestamp
        self.source = source
        self.horizontalAccuracyM = horizontalAccuracyM
        self.verticalAccuracyM = verticalAccuracyM
        self.altitudeMSLm = altitudeMSLm
        self.altitudeEllipsoidalM = altitudeEllipsoidalM
        self.speedMps = speedMps
        self.speedAccuracyMps = speedAccuracyMps
        self.courseDeg = courseDeg
        self.courseAccuracyDeg = courseAccuracyDeg
        self.isSimulated = isSimulated
    }
}
