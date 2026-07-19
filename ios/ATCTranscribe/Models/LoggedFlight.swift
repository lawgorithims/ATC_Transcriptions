import Foundation
import CoreLocation

/// One recorded GPS point on the breadcrumb trail. Flat doubles keep a multi-hour trail compact on disk.
struct Breadcrumb: Codable, Equatable {
    let t: Date
    let lat, lon: Double
    let altFt: Double?
    let speedKt: Double?
    let track: Double?
    var coord: Coord { Coord(lat: lat, lon: lon) }
    var clCoord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// A place the aircraft sat still long enough to count as a stop (a leg boundary). `airport` is filled in
/// off-main from the nearest FAA airport when one is within a few NM.
struct FlightStop: Codable, Equatable, Identifiable {
    let id: UUID
    let lat, lon: Double
    let arrivedAt: Date
    var durationSec: TimeInterval
    var airport: String?
    var coord: Coord { Coord(lat: lat, lon: lon) }
    var label: String { airport ?? String(format: "%.3f, %.3f", lat, lon) }
}

/// A saved flight in the logbook. Metrics are computed by the FlightRecorder from the live GPS trail; this
/// type owns the shape + display + the detail-map region only. Aircraft is DENORMALIZED to strings (not a
/// profile id): a log is historical, and the hangar is mutable — a later profile edit/delete must not
/// rewrite or orphan past flights.
struct LoggedFlight: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let durationSec: TimeInterval
    let distanceNM: Double
    let maxSpeedKt: Double
    let avgSpeedKt: Double
    let maxAltFtMSL: Double
    let stops: [FlightStop]
    var aircraftCallsign: String?
    var aircraftType: String?
    var notes: String
    let breadcrumb: [Breadcrumb]

    static let maxBreadcrumb = 2000         // stored trail cap — dense enough to REPLAY (position/alt/speed
                                            // per point), still bounded (~100 KB/flight)

    // MARK: display helpers (pure)

    var durationText: String { Self.hms(durationSec) }
    var distanceText: String { String(format: "%.1f NM", distanceNM) }
    var maxSpeedText: String { "\(Int(maxSpeedKt.rounded())) kt" }
    var avgSpeedText: String { "\(Int(avgSpeedKt.rounded())) kt" }
    var maxAltText: String { "\(Int(maxAltFtMSL.rounded())) ft" }
    var aircraftLine: String {
        let parts = [aircraftCallsign, aircraftType].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Aircraft not recorded" : parts.joined(separator: " · ")
    }
    /// "KBOS → KJFK → KDCA" from the detected stops, else "Flight" when none were resolved.
    var routeSummary: String {
        let named = stops.compactMap { $0.airport }
        return named.isEmpty ? "Flight" : named.joined(separator: " → ")
    }

    /// Center + span covering the breadcrumb (for the detail map camera); nil when there's too little to draw.
    var mapRegion: (center: Coord, spanLat: Double, spanLon: Double)? {
        guard breadcrumb.count >= 2 else { return nil }
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for b in breadcrumb.prefix(Self.maxBreadcrumb) {           // bounded (rule 2)
            minLat = min(minLat, b.lat); maxLat = max(maxLat, b.lat)
            minLon = min(minLon, b.lon); maxLon = max(maxLon, b.lon)
        }
        assert(minLat <= maxLat && minLon <= maxLon, "mapRegion: degenerate bbox")
        let center = Coord(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
        return (center, max((maxLat - minLat) * 1.3, 0.05), max((maxLon - minLon) * 1.3, 0.05))
    }

    /// H:MM:SS when ≥ 1 h, else M:SS. Pure; >=2 assertions.
    static func hms(_ seconds: TimeInterval) -> String {
        assert(seconds.isFinite, "hms: non-finite")
        let s = max(Int(seconds.rounded()), 0)
        assert(s >= 0, "hms: negative")
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
