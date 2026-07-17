import Foundation

/// Offline coordinate → local time zone, for showing a weather/NOTAM Zulu time in the LOCAL clock time of
/// that airport/area. No network (a cockpit EFB must work offline), so the zone is derived from the
/// coordinate: the US regions map to real IANA zone identifiers (so `TimeZone` handles DST correctly), and
/// anywhere else falls back to a whole-hour offset from longitude. The US longitude bands are
/// APPROXIMATE — the real zone boundaries zigzag by county — so a point within ~1° of a boundary may show
/// the neighbouring zone; good enough for a weather time, and the Zulu time is always shown alongside.
enum LocationTime {

    /// The local time zone for a coordinate. nil only for an out-of-range coordinate.
    static func timeZone(lat: Double, lon: Double) -> TimeZone? {
        // A degenerate coordinate returns nil gracefully rather than trapping (the callers pass real
        // airport/TFR coordinates, but the map's tap could hand us anything).
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        if let id = usZoneID(lat: lat, lon: lon), let tz = TimeZone(identifier: id) { return tz }
        // Elsewhere: nearest whole-hour nautical offset from longitude (no DST — approximate).
        let hours = Int((lon / 15).rounded())
        return TimeZone(secondsFromGMT: hours * 3600)
    }

    /// IANA zone id for a US coordinate (DST-aware), else nil. Special regions (AK/HI/AZ) are checked before
    /// the CONUS longitude bands.
    private static func usZoneID(lat: Double, lon: Double) -> String? {
        if lat >= 51, lon <= -129.9 { return "America/Anchorage" }               // Alaska
        if lat < 25, lon <= -150 { return "Pacific/Honolulu" }                   // Hawaii
        guard lat >= 24, lat <= 50, lon <= -66.5, lon >= -125.5 else { return nil }   // CONUS box
        if lat >= 31.3, lat <= 37.1, lon <= -109.0, lon >= -114.9 { return "America/Phoenix" }   // Arizona (no DST)
        if lon >= -87.5  { return "America/New_York" }     // Eastern (approximate CONUS bands)
        if lon >= -101.5 { return "America/Chicago" }      // Central
        if lon >= -114.3 { return "America/Denver" }       // Mountain
        return "America/Los_Angeles"                       // Pacific
    }

    private static let timeOnly: DateFormatter = df("h:mm a zzz")
    private static let timeNoZone: DateFormatter = df("h:mm a")
    private static let dateTime: DateFormatter = df("MMM d, h:mm a zzz")
    private static func df(_ fmt: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = fmt; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }

    /// "9:00 PM EDT" for a coordinate's local zone, or nil when no zone resolves.
    static func localTime(_ date: Date, lat: Double, lon: Double) -> String? {
        guard let tz = timeZone(lat: lat, lon: lon) else { return nil }
        timeOnly.timeZone = tz
        return timeOnly.string(from: date)
    }

    /// A local-clock range: "9:00 PM–2:00 AM EDT" (abbreviation once, at the end), or "9:00 PM EDT" when
    /// `to` is nil. nil when no zone resolves.
    static func localRange(_ from: Date, _ to: Date?, lat: Double, lon: Double) -> String? {
        guard let tz = timeZone(lat: lat, lon: lon) else { return nil }
        timeOnly.timeZone = tz; timeNoZone.timeZone = tz
        guard let to else { return timeOnly.string(from: from) }
        return "\(timeNoZone.string(from: from))–\(timeOnly.string(from: to))"
    }
    /// "Jul 16, 9:00 PM EDT" for a coordinate's local zone, or nil when no zone resolves.
    static func localDateTime(_ date: Date, lat: Double, lon: Double) -> String? {
        guard let tz = timeZone(lat: lat, lon: lon) else { return nil }
        dateTime.timeZone = tz
        return dateTime.string(from: date)
    }
}
