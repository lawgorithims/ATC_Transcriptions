import Foundation

/// Runways + published airband frequencies for one airport — the grounding data the
/// CallsignSnap/SlotSnap correction stages verify transmissions against. Swift mirror of
/// `python-legacy/airport_data.py:AirportContext` (see `python-legacy/docs/PIPELINE.md`).
struct AirportContextData: Sendable, Equatable {
    let ident: String
    var runways: [String] = []                       // open designators, both ends ("17C", "31L")
    var frequencies: [String: [Double]] = [:]        // type ("TWR"/"GND"/…) → MHz

    var frequencyValues: [Double] { frequencies.values.flatMap { $0 }.sorted() }
    var isEmpty: Bool { runways.isEmpty && frequencies.isEmpty }
}

/// A source of airport context. Sources compose in a priority chain (curated config → bundled
/// nationwide table → internet fallback); the first source that answers wins per field.
protocol AirportContextSource: Sendable {
    func airport(_ ident: String) async -> AirportContextData?
}

/// Nationwide bundled table (`nav/airport_ctx.json`, ~29k airports worldwide, 1.2 MB), built by
/// `Tools/build_airport_ctx.py` from the same OurAirports upstream as `nav_coords.json`.
/// Schema: `{ "KDFW": [["13L", …], {"TWR": [124.15], …}], … }`. Lazy-loaded like `NavDatabase`.
struct BundledAirportContextSource: AirportContextSource {
    func airport(_ ident: String) async -> AirportContextData? {
        Self.lookup(ident)
    }

    /// Synchronous seam for tests and non-async callers.
    static func lookup(_ ident: String) -> AirportContextData? {
        let key = ident.trimmingCharacters(in: .whitespaces).uppercased()
        guard let entry = table[key] else { return nil }
        return AirportContextData(ident: key, runways: entry.runways, frequencies: entry.frequencies)
    }

    static var count: Int { table.count }   // test seam / lazy-load probe

    private struct Entry: Decodable {
        let runways: [String]
        let frequencies: [String: [Double]]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            runways = try c.decode([String].self)
            frequencies = try c.decode([String: [Double]].self)
        }
    }

    private static let table: [String: Entry] = {
        let url = Bundle.main.url(forResource: "airport_ctx", withExtension: "json", subdirectory: "nav")
            ?? Bundle.main.url(forResource: "airport_ctx", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return dict
    }()
}

/// Hand-curated per-facility configs (`airport_configs/*.json`) — richest data for the few
/// bundled facilities (KDFW, KJFK). Frequencies come from the per-feed map; type is opaque.
struct CuratedAirportContextSource: AirportContextSource {
    func airport(_ ident: String) async -> AirportContextData? {
        guard let cfg = try? AirportConfig.load(named: ident.lowercased()) else { return nil }
        var freqs: [String: [Double]] = [:]
        for (_, mhz) in cfg.frequencies ?? [:] {
            if let v = Double(mhz) { freqs["ATC", default: []].append(v) }
        }
        let data = AirportContextData(ident: cfg.airportCode ?? ident.uppercased(),
                                      runways: cfg.runways ?? [],
                                      frequencies: freqs)
        return data.isEmpty ? nil : data
    }
}

/// Internet fallback — downloads the OurAirports runways/frequencies CSVs (public domain, ~5 MB)
/// once into Application Support and answers from the parsed tables. The bundled table is built
/// from the same data, so this only fires for airports added upstream after the bundle was built
/// (or if the bundle resource is missing); it follows the `ADSBService` networking conventions
/// (ephemeral session, fail-soft: any error → nil so the chain just yields no context).
actor NetworkAirportContextSource: AirportContextSource {
    static let shared = NetworkAirportContextSource()
    private let base = "https://davidmegginson.github.io/ourairports-data/"
    private let maxAge: TimeInterval = 30 * 24 * 3600
    private var runways: [String: [String]]?
    private var freqs: [String: [String: [Double]]]?

    func airport(_ ident: String) async -> AirportContextData? {
        await loadIfNeeded()
        let key = ident.uppercased()
        guard runways != nil || freqs != nil else { return nil }
        let data = AirportContextData(ident: key,
                                      runways: runways?[key]?.sorted() ?? [],
                                      frequencies: freqs?[key] ?? [:])
        return data.isEmpty ? nil : data
    }

    private func loadIfNeeded() async {
        guard runways == nil else { return }
        guard let rw = await csv("runways"), let fq = await csv("airport-frequencies") else { return }
        // runways.csv schema: id,airport_ref,airport_ident,length_ft,width_ft,surface,
        // lighted,closed,le_ident,le_lat,le_lon,le_elev,le_hdg,le_dthr,he_ident,...
        // -> le_ident col 8, he_ident col 14 (review finding: col 9 is le_latitude).
        var rwTable: [String: [String]] = [:]
        for row in rw where row.count > 14 && row[7] != "1" {         // closed column
            for end in [row[8], row[14]] where !end.isEmpty {
                if rwTable[row[2], default: []].contains(end) == false { rwTable[row[2], default: []].append(end) }
            }
        }
        var fqTable: [String: [String: [Double]]] = [:]
        for row in fq where row.count > 5 {
            guard let mhz = Double(row[5]), (118.0...136.975).contains(mhz) else { continue }
            let type = String(row[3].uppercased().prefix(4))
            fqTable[row[2], default: [:]][type.isEmpty ? "ATC" : type, default: []].append(mhz)
        }
        runways = rwTable
        freqs = fqTable
    }

    /// Fetch (or reuse a fresh cached copy of) one CSV and split it into unquoted-comma rows.
    /// OurAirports quotes every field, so a simple state machine suffices.
    private func csv(_ name: String) async -> [[String]]? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirportData", isDirectory: true)
        let file = dir.appendingPathComponent("\(name).csv")
        var data: Data?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < maxAge {
            data = try? Data(contentsOf: file)
        }
        if data == nil {
            guard let url = URL(string: base + name + ".csv") else { return nil }
            let session = URLSession(configuration: .ephemeral)
            guard let (fetched, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        }
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").dropFirst().map { Self.splitCSVRow(String($0)) }
    }

    static func splitCSVRow(_ line: String) -> [String] {
        var out: [String] = []
        var field = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ",", !inQuotes { out.append(field); field = "" }
            else { field.append(ch) }
        }
        out.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return out
    }
}

/// The provider chain: curated config → bundled nationwide table → internet fallback. First
/// answer wins per field; later sources fill missing fields (mirrors `CompositeSource` in
/// `airport_data.py`). LiveATC/demo mode uses exactly this chain keyed by the feed's airport.
struct AirportContextStore: Sendable {
    var sources: [any AirportContextSource] = [
        CuratedAirportContextSource(),
        BundledAirportContextSource(),
        NetworkAirportContextSource.shared,
    ]

    func airport(_ ident: String) async -> AirportContextData? {
        var result: AirportContextData?
        for source in sources {
            guard let ctx = await source.airport(ident) else { continue }
            if result == nil {
                result = ctx
            } else {
                if result!.runways.isEmpty { result!.runways = ctx.runways }
                if result!.frequencies.isEmpty { result!.frequencies = ctx.frequencies }
            }
            if let r = result, !r.runways.isEmpty, !r.frequencies.isEmpty { break }
        }
        return result
    }

    /// Airports around a position (Stratux GPS / device location / route leg), context-resolved.
    /// Coordinates come from `NavDatabase` (kind 0 = airport) so the two bundles stay one source
    /// of truth; context then resolves through the normal chain.
    func nearby(lat: Double, lon: Double, radiusNm: Double = 30) async -> [AirportContextData] {
        let dLat = radiusNm / 60.0
        let dLon = radiusNm / (60.0 * max(0.2, cos(lat * .pi / 180)))
        let box = BBox(minLat: lat - dLat, minLon: lon - dLon, maxLat: lat + dLat, maxLon: lon + dLon)
        var out: [AirportContextData] = []
        for point in NavDatabase.nearby(box, types: [0], limit: 24) {
            if let ctx = await airport(point.ident) { out.append(ctx) }
        }
        return out
    }
}
