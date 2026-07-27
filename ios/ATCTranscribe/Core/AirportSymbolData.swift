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
        attributes(ident, nasr: AirportData.runways(airport: ident))
    }

    /// `nasr` is passed in so `spec` can read the runway table ONCE per airport. It is read on the glyph
    /// build path, which runs for every field on screen while the pilot pans, and a second query per
    /// airport there is pure waste on a battery-sensitive device.
    static func attributes(_ ident: String, nasr: [AirportData.Runway]) -> AirportSymbol.Attributes {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        let name = NavMeta.airport(key)?.name
        guard let r = table[key] else {
            return AirportSymbol.Attributes(name: name)          // no record → unverified
        }
        return AirportSymbol.Attributes(
            hasTower: r.t.map { $0 != 0 },
            hasFuel: r.f.map { $0 != 0 },
            hasBeacon: r.b.map { $0 != 0 },
            // Prefer the PUBLISHED surface over the approximated flag in airport_symbols.json
            // (derived from aviationweather.gov because NASR was unavailable at the time). A
            // field with any paved runway is hard-surfaced; one with runway records and none
            // paved is definitively soft, which is a stronger statement than the flag could make.
            hardSurface: Self.hardSurface(nasr) ?? r.s.map { $0.uppercased() == "H" },
            owner: r.o,
            typeCode: r.y,
            name: name)
    }

    /// The runways an airport's symbol draws: PAVED, in service, and actual runways.
    ///
    /// NASR first, because it is the only source that carries a surface. CIFP has real per-end bearings
    /// but no surface at all, so every published strip was drawn the same — KTCS showed five runways
    /// when four of them are gravel, and grass fields drew a full runway outline as though they were
    /// paved. NASR also covers 19,436 fields against CIFP's ~6,400.
    ///
    /// CIFP remains the fallback for a field NASR has no runway record for, so nothing that drew
    /// before stops drawing.
    static func runways(_ ident: String) -> [AirportSymbol.Runway] {
        runways(ident, nasr: AirportData.runways(airport: ident))
    }

    static func runways(_ ident: String, nasr: [AirportData.Runway]) -> [AirportSymbol.Runway] {
        if !nasr.isEmpty {
            return nasr.prefix(32).compactMap { r -> AirportSymbol.Runway? in
                guard r.isPaved, !r.isHelipad, !r.isFailed,
                      let b = r.bearingDeg, let len = r.lengthFt, len > 0 else { return nil }
                return AirportSymbol.Runway(bearingDeg: b, lengthFt: Int(len))
            }
        }
        return CIFP.runways(airport: ident).prefix(32).compactMap { r in
            guard let b = r.bearingMag, b.isFinite, let len = r.lengthFt, len > 0 else { return nil }
            return AirportSymbol.Runway(bearingDeg: b, lengthFt: Int(len))
        }
    }

    /// Whether the field has any paved runway, from NASR. Nil when NASR knows no runways for it, so
    /// the caller falls back to the approximated flag rather than asserting "soft" from silence.
    static func hardSurface(_ nasr: [AirportData.Runway]) -> Bool? {
        let r = nasr.filter { !$0.isHelipad }
        guard !r.isEmpty else { return nil }
        return r.contains { $0.isPaved && !$0.isFailed }
    }

    static func hardSurface(_ ident: String) -> Bool? { hardSurface(AirportData.runways(airport: ident)) }

    /// The complete drawing spec for one airport at its current reported category.
    static func spec(_ ident: String, category: AirportSymbol.Category? = nil) -> AirportSymbol.Spec {
        let nasr = AirportData.runways(airport: ident)          // one read, both consumers
        return AirportSymbol.spec(attributes: attributes(ident, nasr: nasr),
                                  runways: runways(ident, nasr: nasr), category: category)
    }
}
