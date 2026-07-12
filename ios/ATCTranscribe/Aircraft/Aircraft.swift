import Foundation

/// A plain lat/lon pair — `Sendable`/`Equatable` so it crosses the `ADSBService` actor boundary
/// cleanly (unlike `CLLocationCoordinate2D`). `Codable` so EONET hazard snapshots round-trip
/// through their disk cache. Device GPS will produce one of these later too.
struct Coord: Sendable, Equatable, Hashable, Codable {
    var lat: Double
    var lon: Double
}

/// One ADS-B contact from airplanes.live, normalized for the UI + corrector.
///
/// Freshness is anchored to **when the snapshot bytes arrived** (`fetchedAt`) minus the
/// server-relative age (`seenPosSec ?? seenSec`), NOT to poll time — so a parked-but-transmitting
/// aircraft ages correctly and can never be made "immortal" by re-stamping it every poll.
struct Aircraft: Identifiable, Equatable, Sendable {
    let hex: String                     // ICAO 24-bit address — stable id
    var id: String { hex }
    var callsign: String? = nil         // trimmed `flight`
    var registration: String? = nil     // `r` — tail / N-number
    var typeCode: String? = nil         // `t`
    var lat: Double? = nil
    var lon: Double? = nil
    var altBaroFt: Int? = nil           // nil when on the ground
    var onGround: Bool = false
    var gsKt: Double? = nil
    var trackDeg: Double? = nil
    var squawk: String? = nil
    var distanceNm: Double? = nil       // `dst` — distance from the query center
    /// Device instant the snapshot bytes arrived (the freshness anchor).
    var fetchedAt: Date
    /// Seconds since the feed last heard ANY message from this aircraft (`seen`).
    var seenSec: Double
    /// Seconds since the last POSITION message (`seen_pos`), when present.
    var seenPosSec: Double? = nil

    /// Absolute instant this contact was last heard — server-anchored, never poll time.
    var lastSeen: Date { fetchedAt.addingTimeInterval(-(seenPosSec ?? seenSec)) }

    /// A contact is stale when its last-heard instant is older than `window`.
    func isStale(window: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) > window
    }

    var coordinate: Coord? {
        guard let lat, let lon else { return nil }
        return Coord(lat: lat, lon: lon)
    }

    /// Best spoken label: callsign preferred, else registration.
    var label: String? { callsign ?? registration }

    // MARK: - Decoding (airplanes.live /v2/point)

    /// Decode a `/v2/point` response into normalized contacts plus the server clock (for a skew
    /// sanity check at the call site). Tolerant: a malformed `ac` element is skipped (never fatal),
    /// and an unknown `alt_baro` is treated as on-ground rather than throwing.
    static func decode(_ data: Data, fetchedAt: Date) throws -> (aircraft: [Aircraft], serverNow: Date?) {
        let resp = try JSONDecoder().decode(ADSBResponse.self, from: data)
        // `now` is a unix timestamp; airplanes.live emits milliseconds — normalize to seconds.
        let serverNow = resp.now.map { Date(timeIntervalSince1970: $0 > 1_000_000_000_000 ? $0 / 1000 : $0) }
        let list = (resp.ac ?? []).compactMap { $0.aircraft(fetchedAt: fetchedAt) }
        return (list, serverNow)
    }
}

/// Wire model for the `{ "now": …, "ac": [ … ] }` response. Kept private to `Aircraft`.
private struct ADSBResponse: Decodable {
    let now: Double?
    let ac: [Raw]?

    struct Raw: Decodable {
        let hex: String?
        let flight: String?
        let r: String?
        let t: String?
        let lat: Double?
        let lon: Double?
        let altBaro: AltBaro?
        let gs: Double?
        let track: Double?
        let squawk: String?
        let seen: Double?
        let seenPos: Double?
        let dst: Double?

        // Explicit keys: ADS-B uses short snake_case keys; do NOT rely on a global
        // `.convertFromSnakeCase` strategy (it would mangle keys like `r`/`t`).
        enum CodingKeys: String, CodingKey {
            case hex, flight, r, t, lat, lon, gs, track, squawk, seen, dst
            case altBaro = "alt_baro"
            case seenPos = "seen_pos"
        }

        func aircraft(fetchedAt: Date) -> Aircraft? {
            guard let hex, !hex.isEmpty else { return nil }
            let cs = flight?.trimmingCharacters(in: .whitespaces)
            return Aircraft(
                hex: hex,
                callsign: (cs?.isEmpty == false) ? cs : nil,
                registration: r?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                typeCode: t?.nilIfEmpty,
                lat: lat, lon: lon,
                altBaroFt: altBaro?.feet,
                onGround: altBaro?.isGround ?? false,
                gsKt: gs, trackDeg: track,
                squawk: squawk?.nilIfEmpty,
                distanceNm: dst,
                fetchedAt: fetchedAt,
                // A contact with no `seen` is treated as ancient so the freshness prune drops it.
                seenSec: seen ?? 1_000_000_000,
                seenPosSec: seenPos)
        }
    }
}

/// `alt_baro` is either an integer (feet) or the string "ground". Tolerant: anything else → ground.
private enum AltBaro: Decodable {
    case feet(Int)
    case ground

    var feet: Int? { if case .feet(let f) = self { return f } else { return nil } }
    var isGround: Bool { if case .ground = self { return true } else { return false } }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .feet(i) }
        else if let d = try? c.decode(Double.self) { self = .feet(Int(d)) }
        else { self = .ground }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
