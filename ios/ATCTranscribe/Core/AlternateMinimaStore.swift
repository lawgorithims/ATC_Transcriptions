import Foundation

/// Parses an airport's IFR alternate minimums out of its booklet, once each, off the main actor.
///
/// Shaped like `MinimaStore` and for the same reason: reading a booklet is tens of milliseconds of
/// PDFKit work, fine once and far too much per redraw. Keyed by booklet, airport AND cycle, so a new
/// 28-day cycle never serves last cycle's restrictions.
///
/// ⚠️ THREE OUTCOMES, NOT TWO. "Not listed" means STANDARD alternate minima apply and is the normal
/// answer for most airports; "unreadable" means the app does not know. Collapsing them would tell a
/// pilot that a restricted field is unrestricted — measured on the shipped cycle, 2,050 of the 2,051
/// listed airports parse, and one booklet in the FAA's own index is a 404 page rather than a chart.
@MainActor
final class AlternateMinimaStore: ObservableObject {

    struct Result: Equatable {
        /// The airport's block, or nil when the booklet was read and does not list it.
        let minima: AlternateMinima?
        /// Set only when the booklet itself could not be read.
        let refusal: String?
    }

    @Published private(set) var results: [String: Result] = [:]
    @Published private(set) var loading: Set<String> = []

    /// Cap on retained parses (rule 2).
    static let maxCached = 200

    static func key(_ procedure: AirportProcedure, ident: String) -> String {
        "\(procedure.pdf)-\(ident.uppercased())-\(Procedures.cycle)"
    }

    func result(for procedure: AirportProcedure, ident: String) -> Result? {
        results[Self.key(procedure, ident: ident)]
    }

    func isLoading(_ procedure: AirportProcedure, ident: String) -> Bool {
        loading.contains(Self.key(procedure, ident: ident))
    }

    /// The alternate-minimums booklet for `ident`, if the cycle publishes one for that field.
    static func booklet(for ident: String) -> AirportProcedure? {
        Procedures.forAirport(ident).prefix(128).first {                 // bounded (rule 2)
            $0.code == "MIN" && $0.name.uppercased().contains("ALTERNATE")
        }
    }

    /// Parse `procedure` for `ident` if the booklet is on disk. Never downloads — same contract as
    /// `MinimaStore`: this reads a chart the pilot already has.
    ///
    /// `publishedRunways` is what makes the runway/footnote split decidable — see
    /// `AlternateMinimaParser.split` — so it is resolved here from NASR rather than left to the caller.
    func ensure(_ procedure: AirportProcedure, ident: String) {
        let k = Self.key(procedure, ident: ident)
        guard results[k] == nil, !loading.contains(k) else { return }
        guard let url = PlateStore.localURL(procedure),
              FileManager.default.fileExists(atPath: url.path) else { return }
        assert(!ident.isEmpty, "AlternateMinimaStore.ensure: unnamed airport")
        let runways = AirportData.runwayEnds(airport: ident).map(\.end)
        loading.insert(k)
        Task.detached(priority: .userInitiated) {
            let parsed = Self.parse(url: url, ident: ident, publishedRunways: runways)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(k)
                if self.results.count >= Self.maxCached { self.results.removeAll() }
                self.results[k] = parsed
            }
        }
    }

    /// Off the main actor: read the booklet and run the parser. Pure with respect to app state.
    nonisolated static func parse(url: URL, ident: String,
                                  publishedRunways: [String]) -> Result {
        #if canImport(PDFKit)
        guard let text = AlternateMinimaReader.text(pdfAt: url) else {
            return Result(minima: nil,
                          refusal: "This booklet could not be read. Clear the plate cache and download it again.")
        }
        return Result(minima: AlternateMinimaParser.parse(text: text, ident: ident,
                                                         publishedRunways: publishedRunways),
                      refusal: nil)
        #else
        return Result(minima: nil, refusal: "PDF reading is unavailable on this platform.")
        #endif
    }
}
