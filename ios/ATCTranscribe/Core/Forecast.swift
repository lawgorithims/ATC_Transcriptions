import Foundation

/// One period of the NWS 7-day forecast ("Thursday", "Thursday Night", …) — the fields the airport
/// card's outlook list shows. Lenient decode: a missing field never drops the whole outlook.
struct ForecastPeriod: Decodable, Equatable, Sendable {
    let name: String
    let temperature: Int?
    let temperatureUnit: String?
    let windSpeed: String?
    let windDirection: String?
    let shortForecast: String?
    let isDaytime: Bool?

    var tempText: String {
        guard let t = temperature else { return "—" }
        return "\(t)°\(temperatureUnit ?? "F")"
    }
    var windText: String {
        [windDirection, windSpeed].compactMap { $0 }.joined(separator: " ")
    }
}

/// Fetches + caches the NWS (api.weather.gov) 7-day forecast for airport coordinates — the "outlook"
/// section under the airport card's Weather tab. Two-step API (points → gridpoint forecast), US-only
/// (matches the app's coverage), no key; NWS asks for a User-Agent. 1-hour TTL; a transport failure
/// gets a short backoff (mirrors `MetarStore`). UI-only; nothing here touches the transcription pipeline.
@MainActor final class ForecastStore: ObservableObject {
    @Published private(set) var forecasts: [String: [ForecastPeriod]] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let ttl: TimeInterval = 3600

    func forecast(_ ident: String) -> [ForecastPeriod]? { forecasts[Self.key(ident)] }

    /// Fetch the outlook for an airport if missing/stale (deduped against in-flight requests).
    func ensure(_ ident: String, coord: Coord, now: Date = Date()) {
        assert((-90...90).contains(coord.lat) && (-180...180).contains(coord.lon), "ensure: coord out of range")
        let id = Self.key(ident)
        guard !id.isEmpty, !inFlight.contains(id) else { return }
        if let at = fetchedAt[id], now.timeIntervalSince(at) <= ttl { return }
        inFlight.insert(id)
        Task {
            let result = await Self.download(coord)
            inFlight.remove(id)
            let stamp = Date()
            guard let result else {
                fetchedAt[id] = stamp.addingTimeInterval(30 - ttl)   // transport failure → retry in ~30 s
                return
            }
            fetchedAt[id] = stamp
            forecasts[id] = result
        }
    }

    nonisolated private static func key(_ ident: String) -> String {
        ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private struct PointsDTO: Decodable {
        struct Props: Decodable { let forecast: String? }
        let properties: Props
    }
    private struct ForecastDTO: Decodable {
        struct Props: Decodable { let periods: [ForecastPeriod] }
        let properties: Props
    }

    /// nil = transport/decode failure (retry soon); [] should not occur but is a valid empty outlook.
    nonisolated private static func download(_ coord: Coord) async -> [ForecastPeriod]? {
        func get(_ urlString: String) async -> Data? {
            guard let url = URL(string: urlString) else { return nil }
            var req = URLRequest(url: url); req.timeoutInterval = 15
            req.setValue("CommSight iOS (flycommsight.com)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        let pointsURL = String(format: "https://api.weather.gov/points/%.4f,%.4f", coord.lat, coord.lon)
        guard let pointsData = await get(pointsURL),
              let points = try? JSONDecoder().decode(PointsDTO.self, from: pointsData),
              let forecastURL = points.properties.forecast,
              let fcData = await get(forecastURL),
              let fc = try? JSONDecoder().decode(ForecastDTO.self, from: fcData) else { return nil }
        return Array(fc.properties.periods.prefix(14))    // 7 days × day/night — bounded (rule 2)
    }
}
