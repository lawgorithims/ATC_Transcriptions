import Foundation

/// Where a dataset came from and when it is legally valid — carried with the data all the way to the UI.
///
/// Aeronautical data is republished on fixed cycles (28 days for CIFP and the d-TPP plate index, 56 for
/// the FAA raster charts). Two facts follow, and both are safety-relevant:
///
///   * A pilot must be able to see whether what they are looking at has EXPIRED. Silently drawing an
///     out-of-cycle chart is worse than drawing nothing, because it looks authoritative.
///   * Two datasets on different cycles should not be silently fused. CommSight does fuse them today
///     (the airport card alone mixes CIFP, the plate index, OurAirports and live weather), so rather
///     than failing those queries — which would remove most of the app — provenance is STAMPED and
///     mismatches are SURFACED.
struct DataProvenance: Equatable {
    /// Human-readable origin, e.g. "FAA CIFP (ARINC 424-18)".
    let source: String
    /// The publisher's cycle identifier, e.g. "2607". Empty when the dataset carries none.
    let cycle: String
    /// First day the data is valid, and the first day it is NOT. Nil when the dataset carries none —
    /// absent stays absent; a missing date is never defaulted to "today" or "forever".
    let effective: Date?
    let expires: Date?
    /// When this app's copy was produced.
    let ingestedAt: Date?

    static let unknown = DataProvenance(source: "", cycle: "", effective: nil, expires: nil, ingestedAt: nil)

    /// Parse from the `key`/`value` rows every bundled dataset now carries.
    init(meta: [String: String]) {
        source = meta["source"] ?? ""
        cycle = meta["cycle"] ?? ""
        effective = Self.date(meta["effective"])
        expires = Self.date(meta["expires"])
        ingestedAt = Self.date(meta["ingested_at"])
    }

    init(source: String, cycle: String, effective: Date?, expires: Date?, ingestedAt: Date?) {
        self.source = source; self.cycle = cycle
        self.effective = effective; self.expires = expires; self.ingestedAt = ingestedAt
    }

    /// ISO-8601 date (`2026-07-09`) or date-time. Returns nil rather than guessing.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        var c = DateComponents()
        let parts = s.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current      // cycles roll over in UTC
        return cal.date(from: c)
    }

    /// FAA cycles hand over at 0901Z on the boundary date, not at midnight — the same instant
    /// `Procedures.cycleBoundary` already anchors the chart banner to. Measuring from UTC midnight
    /// turned the badge red nine hours before the data actually stopped being current, and put the two
    /// surfaces in disagreement about the very same cycle.
    static let cycleBoundary: TimeInterval = 9 * 3600 + 60      // 0901Z

    /// The dataset's validity as of `now`.
    func currency(asOf now: Date = Date()) -> DataCurrency {
        guard let expires else { return .unknown }
        let cutover = expires.addingTimeInterval(Self.cycleBoundary)
        if now >= cutover { return .expired(since: cutover) }
        let days = Self.wholeDays(from: now, to: cutover)
        return days <= 7 ? .expiringSoon(days: days) : .current
    }

    /// Whole UTC days between two instants, so the count doesn't drift with the device timezone.
    static func wholeDays(from: Date, to: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let a = cal.startOfDay(for: from), b = cal.startOfDay(for: to)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// A one-line description for the provenance badge's detail line.
    var summary: String {
        var parts: [String] = []
        if !cycle.isEmpty { parts.append("Cycle \(cycle)") }
        if let e = expires { parts.append("expires \(Self.iso(e))") }
        if !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    static func iso(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// How a dataset stands relative to its published cycle.
enum DataCurrency: Equatable {
    case current
    case expiringSoon(days: Int)
    case expired(since: Date)
    /// The dataset carries no expiry. NOT the same as "fine" — it means we cannot vouch for it, and the
    /// UI says so rather than showing a reassuring green.
    case unknown

    var isExpired: Bool { if case .expired = self { return true }; return false }

    /// Short badge text.
    var label: String {
        switch self {
        case .current:                return "Current"
        case .expiringSoon(let d):    return "\(max(d, 0))d left"
        case .expired:                return "EXPIRED"
        case .unknown:                return "Undated"
        }
    }

    /// Ordering for "worst status across several datasets" — what a combined badge should show.
    var severity: Int {
        switch self {
        case .current:      return 0
        case .unknown:      return 1
        case .expiringSoon: return 2
        case .expired:      return 3
        }
    }

    /// The worst of several datasets' currency — a screen fusing four sources is only as current as its
    /// stalest input, and that is what the pilot needs to see.
    static func worst(_ items: [DataCurrency]) -> DataCurrency {
        assert(items.count <= 64, "unexpectedly many datasets to combine")
        guard let w = items.max(by: { $0.severity < $1.severity }) else { return .unknown }
        return w
    }
}
