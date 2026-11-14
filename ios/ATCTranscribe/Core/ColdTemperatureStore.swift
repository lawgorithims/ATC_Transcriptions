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
    /// Candidate weather stations around each field, computed once per field (two SQLite queries).
    private var stationCache: [String: FieldStations] = [:]

    /// Cap on retained reads (rule 2).
    static let maxCached = 800
    /// How many stand-in stations to request weather for when the field itself does not report.
    static let nearbyFetchLimit = 4

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
                if self.results.count >= Self.maxCached { self.results.removeAll() }
                self.results[k] = info
            }
        }
    }

    // MARK: weather stations

    /// The field's own weather ident, the plate's named source (resolved), and nearby reporting fields.
    struct FieldStations {
        let fieldWx: String
        let candidates: [ColdTemperatureAdvisor.Station]   // tempC nil; filled at assess time
        let aliases: [String: [String]]                    // wx ident → [FAA ident]
    }

    private func stations(for airport: String) -> FieldStations {
        let key = airport.uppercased()
        if let s = stationCache[key] { return s }
        let field = AirportData.airport(airport)
        let fieldWx = field.flatMap(NearestAirports.wxIdent(for:)) ?? key
        var candidates: [ColdTemperatureAdvisor.Station] = []
        var aliases: [String: [String]] = [:]
        if let field {
            let near = AirportData.airportsNear(field.coord, radiusNm: ColdTemperatureAdvisor.sourceMaxNm, limit: 160)
            for a in near.prefix(160) {                                    // bounded (rule 2)
                guard let wx = NearestAirports.wxIdent(for: a), wx != fieldWx else { continue }
                candidates.append(.init(ident: wx, name: a.name,
                                        distanceNm: Geo.nmBetween(field.coord, a.coord), tempC: nil))
                aliases[wx] = [a.ident.uppercased()]
            }
        }
        let out = FieldStations(fieldWx: fieldWx, candidates: candidates, aliases: aliases)
        stationCache[key] = out
        return out
    }

    /// Idents whose METARs the advisory may need. The field first; stand-ins only once the field is
    /// known not to report a temperature, so a reporting field never costs extra requests.
    func weatherIdents(for procedure: AirportProcedure, airport: String, metars: MetarStore) -> [String] {
        guard info(for: procedure)?.restrictionC != nil, !airport.isEmpty else { return [] }
        let s = stations(for: airport)
        var out = [s.fieldWx]
        let fieldSettled = metars.state(s.fieldWx) != nil
        guard fieldSettled, metars.metar(s.fieldWx)?.tempC == nil else { return out }
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
        let withTemps = s.candidates.map {
            ColdTemperatureAdvisor.Station(ident: $0.ident, name: $0.name, distanceNm: $0.distanceNm,
                                           tempC: metars.metar($0.ident)?.tempC)
        }
        let source = info.sourceName.flatMap {
            ColdTemperatureAdvisor.resolveSource(name: $0, candidates: withTemps, identAliases: s.aliases)
        }
        return ColdTemperatureAdvisor.assess(restrictionC: limit,
                                             fieldIdent: s.fieldWx, fieldTempC: metars.metar(s.fieldWx)?.tempC,
                                             plateSourceName: info.sourceName, plateSource: source,
                                             nearby: withTemps)
    }
}
