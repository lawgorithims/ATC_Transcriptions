import Foundation

/// The flight logbook: every saved flight, newest first, as one JSON file under Documents/Logbook. Mirrors
/// NotesStore's on-disk pattern, but takes an injectable directory so it's unit-testable (NotesStore
/// hardcodes Documents and can't be tested — deliberately NOT copied).
@MainActor final class Logbook: ObservableObject {
    @Published private(set) var flights: [LoggedFlight] = []

    static let maxFlights = 500
    private let dir: URL
    private var fileURL: URL { dir.appendingPathComponent("flights.json") }

    init(directory: URL? = nil) {
        dir = directory ?? Logbook.defaultDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    /// Insert a finished flight (clamps its detail breadcrumb + caps the list). Idempotent-safe on id.
    func add(_ flight: LoggedFlight) {
        assert(flight.endedAt >= flight.startedAt, "add: end before start")
        assert(!flights.contains { $0.id == flight.id }, "add: duplicate flight id")
        var f = flight
        if f.breadcrumb.count > LoggedFlight.maxBreadcrumb {
            f = f.withBreadcrumb(Array(f.breadcrumb.prefix(LoggedFlight.maxBreadcrumb)))
        }
        flights.insert(f, at: 0)
        if flights.count > Self.maxFlights { flights = Array(flights.prefix(Self.maxFlights)) }
        assert(flights.count <= Self.maxFlights, "add: list over cap")
        persist()
    }

    func delete(_ id: UUID) {
        flights.removeAll { $0.id == id }
        persist()
    }

    /// Replace a flight (edited aircraft / notes), keeping newest-first order.
    func update(_ flight: LoggedFlight) {
        guard let i = flights.firstIndex(where: { $0.id == flight.id }) else { return }
        flights[i] = flight
        flights.sort { $0.startedAt > $1.startedAt }
        persist()
    }

    // MARK: persistence

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([LoggedFlight].self, from: d) else { return }
        flights = Array(list.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxFlights))
    }
    private func persist() {
        guard let d = try? JSONEncoder().encode(flights) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }

    private static var defaultDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Logbook")
    }
}

extension LoggedFlight {
    /// Copy with a replaced breadcrumb (used to clamp the stored detail trail).
    func withBreadcrumb(_ crumbs: [Breadcrumb]) -> LoggedFlight {
        LoggedFlight(id: id, startedAt: startedAt, endedAt: endedAt, durationSec: durationSec,
                     distanceNM: distanceNM, maxSpeedKt: maxSpeedKt, avgSpeedKt: avgSpeedKt,
                     maxAltFtMSL: maxAltFtMSL, stops: stops, aircraftCallsign: aircraftCallsign,
                     aircraftType: aircraftType, notes: notes, breadcrumb: crumbs)
    }
}
