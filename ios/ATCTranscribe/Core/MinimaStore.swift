import Foundation

/// Parses minima out of cached plates, once each, off the main actor.
///
/// A plate is swept character by character to read its table, which costs tens of milliseconds — nothing
/// for a one-off, far too much to repeat while a view redraws. So a plate is parsed the first time it is
/// asked for and the answer kept for the life of the process, keyed by the plate AND the chart cycle so a
/// new 28-day cycle never serves last cycle's numbers.
@MainActor
final class MinimaStore: ObservableObject {

    /// Parsed results by `<pdf>-<cycle>`.
    @Published private(set) var results: [String: PlateMinimaParser.Result] = [:]
    @Published private(set) var loading: Set<String> = []

    /// Cap on retained parses (rule 2) — a full region download is thousands of plates.
    static let maxCached = 400

    static func key(_ procedure: AirportProcedure) -> String {
        "\(procedure.pdf)-\(Procedures.cycle)"
    }

    func result(for procedure: AirportProcedure) -> PlateMinimaParser.Result? {
        results[Self.key(procedure)]
    }

    func isLoading(_ procedure: AirportProcedure) -> Bool { loading.contains(Self.key(procedure)) }

    /// Parse `procedure` if it is on disk and has not been parsed yet. No-op otherwise — this never
    /// downloads, because the minima panel is opened from a plate the pilot already has.
    func ensure(_ procedure: AirportProcedure, airport: String) {
        let k = Self.key(procedure)
        guard results[k] == nil, !loading.contains(k) else { return }
        guard let url = PlateStore.localURL(procedure),
              FileManager.default.fileExists(atPath: url.path) else { return }
        assert(!airport.isEmpty, "MinimaStore.ensure: unnamed airport")
        loading.insert(k)
        let name = procedure.name
        let cycle = Procedures.cycle
        Task.detached(priority: .userInitiated) {
            let parsed = Self.parse(url: url, airport: airport, approachName: name, cycle: cycle)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(k)
                if self.results.count >= Self.maxCached { self.results.removeAll() }
                self.results[k] = parsed
            }
        }
    }

    /// Off the main actor: read the plate and run the parser. Pure with respect to app state.
    nonisolated static func parse(url: URL, airport: String, approachName: String,
                                  cycle: String) -> PlateMinimaParser.Result {
        #if canImport(PDFKit)
        let extracted = PlateMinimaReader.extract(pdfAt: url)
        if extracted.isUnreadable {
            return PlateMinimaParser.Result(
                minima: nil,
                refusals: ["This plate file could not be opened. Clear the plate cache and download it again."])
        }
        if extracted.isRaster {
            return PlateMinimaParser.Result(
                minima: nil,
                refusals: ["This plate is a scanned image, so its minima cannot be read. Use the chart."])
        }
        return PlateMinimaParser.parse(words: extracted.bandWords, notesText: extracted.notesText,
                                       airport: airport, approachName: approachName, cycle: cycle)
        #else
        return PlateMinimaParser.Result(minima: nil, refusals: ["PDF reading is unavailable on this platform."])
        #endif
    }
}
