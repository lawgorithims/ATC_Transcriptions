import Foundation

/// Decoders for the Stratux web API (github.com/stratux/stratux). Two shapes CommSight consumes:
///  - one ADS-B target pushed over the `/traffic` WebSocket (the Go `TrafficInfo` struct), and
///  - the ownship GPS/AHRS situation from the `/getSituation` HTTP endpoint (Go `SituationData`).
///
/// Stratux marshals these with Go's default JSON encoder, so the JSON keys are the exact Go field
/// names (e.g. `Icao_addr`, `Position_valid`, `GPSLatitude`). Only the fields CommSight needs are
/// decoded; everything else in the (large) structs is ignored.

/// One target from the Stratux `/traffic` WebSocket — a subset of `TrafficInfo`.
struct StratuxTraffic: Decodable {
    let icaoAddr: UInt32?
    let tail: String?
    let reg: String?
    let lat: Double?
    let lng: Double?
    let positionValid: Bool?
    let alt: Int?
    let onGround: Bool?
    let speed: Double?
    let speedValid: Bool?
    let track: Double?
    let distanceMeters: Double?     // `Distance` — metres from ownship (when bearing/dist is valid)
    let ageSec: Double?             // `Age` — seconds since the last position fix (freshness anchor)

    enum CodingKeys: String, CodingKey {
        case icaoAddr = "Icao_addr"
        case tail = "Tail"
        case reg = "Reg"
        case lat = "Lat"
        case lng = "Lng"
        case positionValid = "Position_valid"
        case alt = "Alt"
        case onGround = "OnGround"
        case speed = "Speed"
        case speedValid = "Speed_valid"
        case track = "Track"
        case distanceMeters = "Distance"
        case ageSec = "Age"
    }

    /// Map to CommSight's `Aircraft`, or nil for a target with no usable identity. `receivedAt` is the
    /// device instant this message arrived — the freshness anchor (Stratux `Age` is the offset back to
    /// the last fix), mirroring the airplanes.live `fetchedAt − seen` model so the same prune works.
    func aircraft(receivedAt: Date) -> Aircraft? {
        guard let icaoAddr, icaoAddr != 0 else { return nil }
        let hex = String(format: "%06x", icaoAddr)          // 24-bit ICAO hex, lowercase (like airplanes.live)
        let hasPos = (positionValid ?? false) && lat != nil && lng != nil
        let ground = onGround ?? false
        let age = max(0, ageSec ?? 0)
        return Aircraft(
            hex: hex,
            callsign: tail?.stx_trimmedNonEmpty,
            registration: reg?.stx_trimmedNonEmpty,
            lat: hasPos ? lat : nil,
            lon: hasPos ? lng : nil,
            altBaroFt: ground ? nil : alt,
            onGround: ground,
            gsKt: (speedValid ?? true) ? speed : nil,
            trackDeg: track,
            distanceNm: distanceMeters.map { $0 / 1852.0 },  // metres → nautical miles
            fetchedAt: receivedAt,
            seenSec: age,
            seenPosSec: hasPos ? age : nil)
    }
}

/// Ownship GPS/AHRS from the Stratux `/getSituation` HTTP endpoint — a subset of `SituationData`.
struct StratuxSituation: Decodable {
    let lat: Double?            // GPSLatitude
    let lon: Double?            // GPSLongitude
    let fixQuality: Int?        // GPSFixQuality — 0 = none, 1 = 3D GPS, 2 = DGPS/SBAS (WAAS)
    let satellites: Int?        // GPSSatellites — sats in the solution
    let altMSLft: Double?       // GPSAltitudeMSL — feet MSL
    let groundSpeedKt: Double?  // GPSGroundSpeed — knots
    let trueCourse: Double?     // GPSTrueCourse — degrees true

    enum CodingKeys: String, CodingKey {
        case lat = "GPSLatitude"
        case lon = "GPSLongitude"
        case fixQuality = "GPSFixQuality"
        case satellites = "GPSSatellites"
        case altMSLft = "GPSAltitudeMSL"
        case groundSpeedKt = "GPSGroundSpeed"
        case trueCourse = "GPSTrueCourse"
    }

    /// Normalized ownship GPS for the UI. A (0, 0) latitude/longitude (Stratux's "no fix" sentinel) is
    /// treated as no coordinate.
    var gps: StratuxGPS {
        let coord: Coord? = {
            guard let lat, let lon, !(lat == 0 && lon == 0) else { return nil }
            return Coord(lat: lat, lon: lon)
        }()
        // Sanitize the numeric fields HERE, at the one boundary between the untrusted `/getSituation`
        // feed and everything downstream. `/getSituation` is plaintext HTTP from any host on the local
        // Wi-Fi (a faulty or hostile unit included), and a value like GPSAltitudeMSL = 1e19 decodes as a
        // finite Double, survives every merge unchecked, and then traps the app-wide GPS bar at
        // `Int(1e19.rounded())` — a crash in flight. Bounding to sane aviation ranges (and rejecting
        // non-finite values) protects every consumer at once: the bar, the GPS card, and the AGL row.
        // `satellites` is already `Int` (a JSON number outside Int range fails to decode), so only the
        // Double fields can smuggle in a value that traps a later `Int(_:)`.
        return StratuxGPS(coordinate: coord, fixQuality: fixQuality ?? 0,
                          satellites: max(0, min(satellites ?? 0, 64)),
                          altMSLft: Self.sane(altMSLft, -2_000, 100_000),
                          groundSpeedKt: Self.sane(groundSpeedKt, 0, 5_000),
                          trackDeg: Self.sane(trueCourse, 0, 360))
    }

    /// A finite value inside [lo, hi], else nil. The point is not the exact bounds — it is that a single
    /// out-of-range or non-finite number from the wire can never reach a trapping `Int(_:)` conversion.
    private static func sane(_ v: Double?, _ lo: Double, _ hi: Double) -> Double? {
        guard let v, v.isFinite, v >= lo, v <= hi else { return nil }
        return v
    }
}

/// Ownship GPS state surfaced to the UI / used as the traffic-query center.
struct StratuxGPS: Equatable, Sendable {
    var coordinate: Coord?
    var fixQuality: Int
    var satellites: Int
    var altMSLft: Double?
    var groundSpeedKt: Double?
    var trackDeg: Double?          // GPS true course/track (° true), when the receiver reports one

    /// True once the receiver has a usable position fix.
    var hasFix: Bool { fixQuality > 0 && coordinate != nil }

    var fixLabel: String {
        switch fixQuality {
        case 0:  return "no fix"
        case 1:  return "3D GPS"
        case 2:  return "WAAS"
        default: return "fix \(fixQuality)"
        }
    }
}

private extension String {
    /// Trimmed, or nil if empty after trimming (Stratux pads/blank-fills some string fields).
    var stx_trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
