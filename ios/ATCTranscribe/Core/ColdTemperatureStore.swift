import Foundation

/// Reads the cold-temperature (snowflake) figure off cached plates, once each, off the main actor, and
/// turns it into an advisory against live weather.
///
/// Like `MinimaStore`, this never downloads a plate: it reads what the pilot already has. Plate results
/// are keyed by plate AND chart cycle, so a new 28-day cycle re-reads the figure — CTA temperatures are
/// recomputed by the FAA and do change.
@MainActor
final class ColdTemperatureStore: ObservableObject {

    @Published private(set) var results: [String: ColdTemperatureRestriction.PlateInfo] = [:]
    private var loading: Set<String> = []
    /// Candidate weather stations around each field, computed once per field.
    private var stationCache: [String: FieldStations] = [:]

    /// Cap on retained reads (rule 2).
    static let maxCached = 800
    /// How many stand-in stations to request weather for when the field itself does not report. Not
    /// every field with an ICAO code reports, so this is generous; it is one batched request.
    static let nearbyFetchLimit = 8

    static func key(_ procedure: AirportProcedure) -> String { "\(procedure.pdf)-\(Procedures.cycle)" }

    func info(for procedure: AirportProcedure) -> ColdTemperatureRestriction.PlateInfo? {
        results[Self.key(procedure)]
    }

    /// Read `procedure` if it is an approach on disk and has not been read yet. No-op otherwise.
    func ensure(_ procedure: AirportProcedure) {
        guard procedure.category == .approach else { return }
        let k = Self.key(procedure)
        guard results[k] == nil, !loading.contains(k),
              let url = PlateStore.localURL(procedure),
              FileManager.default.fileExists(atPath: url.path) else { return }
        loading.insert(k)
        Task.detached(priority: .utility) {
            #if canImport(PDFKit)
            let info = ColdTemperatureRestriction.read(pdfAt: url)
            #else
            let info = ColdTemperatureRestriction.PlateInfo(restrictionC: nil, sourceName: nil, unreadable: true)
            #endif
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(k)
                // An unreadable file concluded nothing — caching it as "no snowflake" would hide a real
                // one for the rest of the process. Leave it unread so the next `ensure` tries again.
                guard !info.unreadable else { return }
                if self.results.count >= Self.maxCached {
                    // Bounded (rule 2). Viewers re-`ensure` the plate they show when it goes missing.
                    self.results.removeAll()
                }
                self.results[k] = info
            }
        }
    }

    // MARK: weather stations

    /// The field's own weather ident and the reporting stations around it.
    struct FieldStations {
        let fieldWx: String
        let candidates: [ColdTemperatureAdvisor.Station]   // tempC nil; filled at assess time
        let aliases: [String: [String]]                    // wx ident → [FAA ident]
    }

    /// The ident the weather service files this field's METAR under.
    ///
    /// The NASR ICAO column when present. Without one, a lower-48 field's METAR is filed under `K` +
    /// its FAA ident (`M46` → `KM46`): 791 approach airports have no ICAO in NASR, and asking for the
    /// bare ident returns nothing, so fields that DO report were called "no report". Outside the lower
    /// 48 the `K` convention is wrong (`NearestAirports.wxIdent` records why), so it is not used there.
    nonisolated static func weatherIdent(_ a: AirportData.Airport) -> String? {
        if let icao = NearestAirports.wxIdent(for: a) { return icao }
        let id = a.ident.trimmingCharacters(in: .whitespaces).uppercased()
        let lower48 = (24.0...49.5).contains(a.coord.lat) && (-125.0 ... -66.5).contains(a.coord.lon)
        guard lower48, id.count == 3, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "K" + id
    }

    private func stations(for airport: String) -> FieldStations {
        let key = airport.uppercased()
        if let s = stationCache[key] { return s }
        let field = AirportData.airport(airport)
        let fieldWx = field.flatMap(Self.weatherIdent) ?? key
        var candidates: [ColdTemperatureAdvisor.Station] = []
        var aliases: [String: [String]] = [:]
        if let field {
            let radius = ColdTemperatureAdvisor.sourceMaxNm
            let cities = AirportData.cities(near: field.coord, radiusNm: radius)
            for a in AirportData.airportsNear(field.coord, radiusNm: radius, limit: 200).prefix(200) {   // bounded
                guard let wx = Self.weatherIdent(a), wx != fieldWx else { continue }
                candidates.append(.init(ident: wx, name: a.name,
                                        distanceNm: Geo.nmBetween(field.coord, a.coord), tempC: nil,
                                        city: cities[a.ident.uppercased()] ?? ""))
                aliases[wx] = [a.ident.uppercased()]
            }
        }
        let out = FieldStations(fieldWx: fieldWx, candidates: candidates, aliases: aliases)
        stationCache[key] = out
        return out
    }

    private func current(_ ident: String, _ metars: MetarStore) -> (tempC: Double, age: TimeInterval?)? {
        ColdTemperatureAdvisor.current(metars.metar(ident))
    }

    /// Idents whose METARs the advisory may need. The field first; stand-ins only once the field is
    /// known not to have a current temperature, so a reporting field never costs extra requests.
    func weatherIdents(for procedure: AirportProcedure, airport: String, metars: MetarStore) -> [String] {
        guard info(for: procedure)?.restrictionC != nil, !airport.isEmpty else { return [] }
        let s = stations(for: airport)
        var out = [s.fieldWx]
        guard metars.state(s.fieldWx) != nil, current(s.fieldWx, metars) == nil else { return out }
        if let name = info(for: procedure)?.sourceName,
           let src = ColdTemperatureAdvisor.resolveSource(name: name, candidates: s.candidates, identAliases: s.aliases) {
            out.append(src.ident)
        }
        out += s.candidates.filter { $0.distanceNm <= ColdTemperatureAdvisor.nearbyRadiusNm }
                           .prefix(Self.nearbyFetchLimit).map(\.ident)
        return out
    }

    /// True once every weather fetch the advisory depends on has finished (reported, no report, or
    /// failed). Until then "no temperature found" would be a claim about a fetch still in flight.
    func weatherSettled(for procedure: AirportProcedure, airport: String, metars: MetarStore) -> Bool {
        let ids = weatherIdents(for: procedure, airport: airport, metars: metars)
        return ids.allSatisfy { metars.state($0) != nil }
    }

    /// The advisory for a plate, or nil when the plate carries no snowflake (or has not been read yet).
    func advisory(for procedure: AirportProcedure, airport: String,
                  metars: MetarStore) -> ColdTemperatureAdvisor.Advisory? {
        guard let info = info(for: procedure), let limit = info.restrictionC else { return nil }
        let s = stations(for: airport)
        let withTemps = s.candidates.map { c -> ColdTemperatureAdvisor.Station in
            let obs = current(c.ident, metars)
            return .init(ident: c.ident, name: c.name, distanceNm: c.distanceNm, tempC: obs?.tempC,
                         city: c.city, age: obs?.age)
        }
        let source = info.sourceName.flatMap {
            ColdTemperatureAdvisor.resolveSource(name: $0, candidates: withTemps, identAliases: s.aliases)
        }
        let field = current(s.fieldWx, metars)
        let failed = weatherIdents(for: procedure, airport: airport, metars: metars)
            .contains { metars.state($0) == .failed }
        return ColdTemperatureAdvisor.assess(restrictionC: limit,
                                             fieldIdent: s.fieldWx, fieldTempC: field?.tempC, fieldAge: field?.age,
                                             plateSourceName: info.sourceName, plateSource: source,
                                             nearby: withTemps, fetchFailed: failed)
    }
}
