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
        // ⚠️ FALL BACK TO NASR RATHER THAN GIVING UP. `airport_symbols.json` covers only part of what
        // the map plots: 10,360 of the 14,089 airport idents in nav_coords.json have no record in it,
        // and 8,907 of those DO have a full NASR record in the bundled apt.sqlite. They were all drawn
        // as the FAA's circled "U" — information lacking — so 6,880 private strips, 254 CLOSED fields
        // and 74 heliports rendered identically to each other and to a genuinely unknown field.
        //
        // apt.sqlite carries every attribute the symbol needs (tower, beacon, fuel, ownership, site
        // type), so an absent row in the curated table is not an absence of data. Only when NASR has
        // nothing either is "unverified" the honest answer.
        guard let r = table[key] else { return nasrAttributes(key, name: name, nasr: nasr) }
        // Resolved AT MOST ONCE per call and memoised — this function runs for every field on screen
        // while the pilot pans, and the whole reason the curated table exists is to keep a per-airport
        // query off that path. `cachedNASR` returns nil without touching SQLite once an ident is known
        // to be absent, so the miss is paid once per airport per launch, not per frame.
        let fallback: () -> AirportData.Airport? = { cachedNASR(key) }
        return AirportSymbol.Attributes(
            // Each field prefers the curated table but falls through to NASR — the towered flag matters
            // most: 26 fields NASR codes ATCT are missing or wrong here, including KDJT, KHDC and KFIN,
            // which drew as unverified rather than as towered airports.
            hasTower: r.t.map { $0 != 0 } ?? fallback()?.isTowered,
            hasFuel: r.f.map { $0 != 0 } ?? fallback().map(\.hasFuel),
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

    /// Memo for the NASR fallback. Keyed by ident, and it stores the MISS as well as the hit — an ident
    /// absent from apt.sqlite must not re-query on every pan. Bounded so a long session over a large
    /// area cannot grow it without limit; at the cap it is cleared rather than evicted one at a time,
    /// because the working set is whatever is on screen and that changes wholesale.
    private static var nasrMemo: [String: AirportData.Airport?] = [:]
    private static let nasrMemoCap = 4_096
    private static let nasrMemoLock = NSLock()

    private static func cachedNASR(_ key: String) -> AirportData.Airport? {
        nasrMemoLock.lock()
        if let hit = nasrMemo[key] { nasrMemoLock.unlock(); return hit }
        nasrMemoLock.unlock()
        let looked = AirportData.airport(key)
        nasrMemoLock.lock()
        if nasrMemo.count >= nasrMemoCap { nasrMemo.removeAll(keepingCapacity: true) }
        nasrMemo[key] = looked
        nasrMemoLock.unlock()
        assert(nasrMemo.count <= nasrMemoCap, "nasrMemo over cap")
        return looked
    }

    /// ⚠️ NASR AND THE CURATED TABLE SPEAK DIFFERENT VOCABULARIES, and `AirportSymbol.classifyKind`
    /// reads the curated one. Feeding it NASR's raw codes made every fallback airport classify as a
    /// plain airport: 254 CLOSED fields drew as usable, and 74 heliports, 87 ultralight strips, 31
    /// gliderports and 4 seaplane bases all drew as private airstrips — worse than the honest circled
    /// "U" they had before, because the app was now affirmatively drawing a usable airfield on a closed
    /// one. Translate, do not pass through.
    ///
    /// CLOSURE IS NOT IN `site_type`. It is `status` (CI/CP), which the first version never read at all.
    /// It is checked FIRST because a closed heliport is closed before it is a heliport.
    static func curatedTypeCode(_ a: AirportData.Airport) -> String? {
        if !a.isOperational, !a.status.isEmpty { return "CLS" }
        switch a.siteType.uppercased() {
        case "H":            return "HEL"
        case "C":            return "SPB"
        case "U":            return "ULT"
        case "G", "B":       return "ULT"      // gliderport / balloonport: not an airplane field
        case "A":            return nil        // a plain airport — let shape and owner classify it
        default:             return nil        // unknown/absent: say nothing rather than guess
        }
    }

    /// NASR ownership → the single letter `classifyKind` tests. MA/MN/MR are the military codes; the
    /// curated table's "M" is what the classifier looks for, and passing "MA" through missed all 21.
    static func curatedOwner(_ ownership: String) -> String? {
        let o = ownership.uppercased()
        guard !o.isEmpty else { return nil }
        return o.hasPrefix("M") ? "M" : o
    }

    /// The symbol attributes an airport's NASR record supports, for the 8,907 fields the curated table
    /// does not cover. Returns the plain unverified attributes when NASR has nothing either — which is
    /// then a true statement rather than a gap.
    ///
    /// NASR's codes are mapped, not invented: `tower` is the TWR_TYPE_CODE ("ATCT…" = towered),
    /// `beacon` is published per field, `fuel` is a comma list where empty genuinely means none, and
    /// `ownership`/`site_type` are the FAA's own single-letter codes, which is exactly what the symbol
    /// renderer already consumes.
    private static func nasrAttributes(_ key: String, name: String?,
                                       nasr: [AirportData.Runway]) -> AirportSymbol.Attributes {
        guard let a = cachedNASR(key) else {
            return AirportSymbol.Attributes(name: name)          // genuinely no record → unverified
        }
        return AirportSymbol.Attributes(
            hasTower: a.isTowered,
            hasFuel: a.hasFuel,
            hasBeacon: nil,                                       // not carried on this row
            hardSurface: Self.hardSurface(nasr),
            owner: Self.curatedOwner(a.ownership),
            typeCode: Self.curatedTypeCode(a),
            name: name ?? (a.name.isEmpty ? nil : a.name))
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
