import Foundation

/// A hand-curated airport feed config, decoded from `airport_configs/*.json`
/// (e.g. `kdfw.json`, `kjfk.json`). Drives the static Whisper prompt prefix and the
/// corrector vocabulary. Field names map from the JSON's snake_case via
/// `.convertFromSnakeCase` (see `load`). Mirrors how `atc_context.py` /
/// `server/app.py` read these files.
struct AirportConfig: Codable, Equatable {
    var airportCode: String?
    var airportName: String?
    var tracon: String?
    var runways: [String]?
    var fixes: [String]?
    var waypoints: [String]?
    var taxiways: [String]?
    /// Map of logical name -> frequency string, e.g. "tower_east" -> "126.550".
    var frequencies: [String: String]?
    /// Map of feed key -> stream entry, e.g. "lone_star_approach_17c_final" -> {...}.
    var streams: [String: StreamEntry]?

    struct StreamEntry: Codable, Equatable {
        var label: String?
        var url: String?
        var streamUrl: String?
        var liveatcPage: String?
        var frequencyMhz: String?
        var archiveMount: String?
    }

    /// Load and decode a bundled config by base name (e.g. "kdfw"). The JSON files
    /// live in the `airport_configs/` folder reference inside the app bundle.
    static func load(named name: String, in bundle: Bundle = .main) throws -> AirportConfig {
        guard let url = bundle.url(forResource: name, withExtension: "json",
                                   subdirectory: "airport_configs") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    /// Decode from raw JSON bytes (also used by tests with inline JSON).
    static func decode(_ data: Data) throws -> AirportConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AirportConfig.self, from: data)
    }
}
