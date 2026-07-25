import Foundation

/// Lazy reader for the bundled `airport_symbols.json` (built by `Tools/build_airport_symbols.py`).
/// Same load-once-on-first-access shape as `NavMeta`.
///
/// The file is a compact ident → short-key record map, because it ships in the app bundle:
///   t tower · b beacon · f fuel/services · o owner (P/M/R) · y type (ARP/HEL/SPB/CLS) · s surface (H/S)
///
/// An ident that is ABSENT is not "an airport with nothing" — it is an airport we hold no record for,
/// and `AirportSymbol` renders that as the FAA's `unverified` case rather than an ordinary field.
enum AirportSymbolData {

    private struct Record: Decodable {
        let t: Int?; let b: Int?; let f: Int?
        let o: String?; let y: String?; let s: String?
    }

    private static let table: [String: Record] = {
        guard let url = Bundle.main.url(forResource: "airport_symbols", withExtension: "json",
                                        subdirectory: "nav")
                ?? Bundle.main.url(forResource: "airport_symbols", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return decoded
    }()

    /// True once the bundled table is present — lets a caller distinguish "no record for this field"
    /// from "the dataset failed to load", which mean very different things on a chart.
    static var isAvailable: Bool { !table.isEmpty }
    static var count: Int { table.count }

    /// The symbol attributes for an ident, merged with the airport's display name (used to spot
    /// military fields whose owner code doesn't say so).
    static func attributes(_ ident: String) -> AirportSymbol.Attributes {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        let name = NavMeta.airport(key)?.name
        guard let r = table[key] else {
            return AirportSymbol.Attributes(name: name)          // no record → unverified
        }
        return AirportSymbol.Attributes(
            hasTower: r.t.map { $0 != 0 },
            hasFuel: r.f.map { $0 != 0 },
            hasBeacon: r.b.map { $0 != 0 },
            hardSurface: r.s.map { $0.uppercased() == "H" },
            owner: r.o,
            typeCode: r.y,
            name: name)
    }

    /// The runways an airport's symbol draws, from the coded CIFP data (real per-end bearings and
    /// lengths). Bounded; empty for the ~7,700 fields CIFP has no runway record for.
    static func runways(_ ident: String) -> [AirportSymbol.Runway] {
        CIFP.runways(airport: ident).prefix(32).compactMap { r in
            guard let b = r.bearingMag, b.isFinite, let len = r.lengthFt, len > 0 else { return nil }
            return AirportSymbol.Runway(bearingDeg: b, lengthFt: len)
        }
    }

    /// The complete drawing spec for one airport at its current reported category.
    static func spec(_ ident: String, category: AirportSymbol.Category? = nil) -> AirportSymbol.Spec {
        AirportSymbol.spec(attributes: attributes(ident), runways: runways(ident), category: category)
    }
}
