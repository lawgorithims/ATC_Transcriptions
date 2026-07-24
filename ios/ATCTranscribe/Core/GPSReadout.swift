import Foundation

/// A full device-GPS snapshot (CoreLocation), with the framework's invalid sentinels already resolved to
/// nil by `DeviceLocation` (speed/course < 0 and verticalAccuracy <= 0 all mean "not available"). A pure
/// value type (no CoreLocation import) so the merge + unit conversions are unit-testable.
///
/// The fields below the accuracy line are the INTEGRITY-BEARING ones (`GPSIntegrityMonitor` reads them):
/// iOS exposes no DOP, no satellite count and no raw GNSS measurements, so the only cross-checks available
/// are the receiver's own uncertainty estimates and the disagreement between position and velocity. They
/// default to nil/false so every existing construction of a `DeviceFix` still compiles unchanged.
struct DeviceFix: Equatable {
    var coord: Coord
    var altitudeMSLm: Double?      // metres MSL; nil when verticalAccuracy <= 0 (altitude invalid)
    var groundSpeedMps: Double?    // m/s; nil when CLLocation.speed < 0 (stationary / no estimate yet)
    var courseDeg: Double?         // ° true; nil when CLLocation.course < 0 (not moving)
    var horizontalAccuracyM: Double

    /// When the fix was taken (CLLocation.timestamp) — the monitor diffs pairs on this, never on now().
    var timestamp: Date = .distantPast
    var verticalAccuracyM: Double?      // metres, 1-sigma; nil when unavailable
    /// Altitude above the WGS-84 ELLIPSOID (iOS 15+). Differs from MSL by the local geoid undulation —
    /// tens of metres — which is one reason GPS and baro altitude disagree, and why AGL must subtract a
    /// terrain elevation in the SAME datum as `altitudeMSLm`.
    var altitudeEllipsoidalM: Double?
    var speedAccuracyMps: Double?       // 1-sigma, iOS 13.4+; nil when unavailable
    var courseAccuracyDeg: Double?      // 1-sigma, iOS 13.4+; nil when unavailable
    /// The OS says this location was produced by software rather than the GNSS chip (iOS 15+) — a hard
    /// spoof signal on the device side.
    var isSimulated: Bool = false

    // MARK: - Derived

    var altitudeMSLft: Double? { altitudeMSLm.map { $0 * GPSReadout.mToFt } }
    var groundSpeedKt: Double? { groundSpeedMps.map { $0 * GPSReadout.mpsToKt } }

    /// Geoid undulation (ellipsoidal − MSL) in feet, when both altitudes are present.
    var geoidUndulationFt: Double? {
        guard let e = altitudeEllipsoidalM, let m = altitudeMSLm else { return nil }
        return (e - m) * GPSReadout.mToFt
    }
}

/// GPS signal quality normalized across the two sources — Stratux reports a fix TYPE (3D/WAAS) + satellite
/// count; the device only exposes a horizontal ACCURACY (metres). Both collapse to a 0-4 bars scale.
enum FixQuality: Int, Equatable {
    case none = 0, poor = 1, fair = 2, good = 3, excellent = 4
    var bars: Int { rawValue }

    init(stratux q: Int) {                       // 0 none · 1 3D · 2 WAAS
        assert(q >= 0, "stratux fixQuality must be >= 0")
        switch q { case 2: self = .excellent; case 1: self = .good; default: self = .none }
    }
    init(horizontalAccuracyM m: Double) {        // CLLocation.horizontalAccuracy (metres, smaller = better)
        assert(m.isFinite, "accuracy must be finite")
        guard m >= 0 else { self = .none; return }
        switch m {
        case ..<8:   self = .excellent
        case ..<20:  self = .good
        case ..<45:  self = .fair
        case ..<150: self = .poor
        default:     self = .none
        }
    }
    var label: String {
        switch self {
        case .none: return "No fix"; case .poor: return "Poor"; case .fair: return "Fair"
        case .good: return "Good"; case .excellent: return "Excellent"
        }
    }
}

/// The merged, display-ready GPS readout: the Stratux fix is preferred when it has one (richer: fix type +
/// satellites, ~1 Hz), else the on-device CoreLocation fix (the contingency for users with NO Stratux),
/// else none. Altitude/speed are converted to aviation units (ft MSL / knots) here.
struct GPSReadout: Equatable {
    enum Source: Equatable { case stratux, device, none }
    var source: Source
    var fixQuality: FixQuality
    var horizontalAccuracyM: Double?   // device only (Stratux reports satellites instead)
    var satellites: Int?               // stratux only
    var altitudeFtMSL: Double?
    var groundSpeedKt: Double?
    var trackDeg: Double?

    static let none = GPSReadout(source: .none, fixQuality: .none, horizontalAccuracyM: nil,
                                 satellites: nil, altitudeFtMSL: nil, groundSpeedKt: nil, trackDeg: nil)
    static let mToFt = 3.280839895
    static let mpsToKt = 1.9438444924

    /// Stratux-preferred merge. Pure; no loops/recursion; >=2 assertions.
    static func merge(stratux: StratuxGPS?, device: DeviceFix?) -> GPSReadout {
        assert(stratux == nil || stratux!.fixQuality >= 0, "bad stratux fixQuality")
        assert(device == nil || device!.horizontalAccuracyM.isFinite, "bad device accuracy")
        if let s = stratux, s.hasFix {
            return GPSReadout(source: .stratux, fixQuality: FixQuality(stratux: s.fixQuality),
                              horizontalAccuracyM: nil, satellites: s.satellites,
                              altitudeFtMSL: s.altMSLft, groundSpeedKt: s.groundSpeedKt, trackDeg: s.trackDeg)
        }
        if let d = device {
            return GPSReadout(source: .device, fixQuality: FixQuality(horizontalAccuracyM: d.horizontalAccuracyM),
                              horizontalAccuracyM: d.horizontalAccuracyM, satellites: nil,
                              altitudeFtMSL: d.altitudeMSLm.map { $0 * mToFt },
                              groundSpeedKt: d.groundSpeedMps.map { $0 * mpsToKt }, trackDeg: d.courseDeg)
        }
        return .none
    }
}
