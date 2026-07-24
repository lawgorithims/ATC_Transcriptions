import Foundation

/// Activating an approach: which way the aircraft joins it, which legs that produces, and where the
/// missed approach begins.
///
/// All of this is DERIVED from the coded CIFP records, because the shipped `cifp.sqlite` carries no
/// explicit IAF / FAF / MAP / missed-approach flags — `Tools/build_cifp.py` keeps only
/// (seq, fix, lat, lon, leg_type, course, alt) and drops ARINC's route-type and waypoint-description
/// columns where those flags live. The structure we DO have is reliable and is what this file uses:
///
///   * One `procedure` row per (airport, approach ident, TRANSITION). Every non-empty transition is a
///     published way to enter the approach, and its ident is the entry fix (the IAF) in 22,050 of
///     22,145 records (99.6%).
///   * The row whose transition is EMPTY is the approach proper: final approach, then the missed
///     approach appended to its tail. 9,120 of 10,243 approaches carry the `RW<runway>` runway
///     threshold pseudo-fix, and 9,117 of those have legs after it — that boundary is the missed
///     approach. 10,217 of 10,243 (99.7%) end in an `HM`/`HF` holding leg, the missed-approach hold.
///
/// Pure value logic, no I/O — the CIFP reads happen in the caller so this stays unit-testable.
enum ApproachActivation {

    /// How the aircraft joins the approach.
    enum Entry: Equatable, Identifiable, Hashable {
        /// Fly direct to this published transition's entry fix (the IAF), then the approach.
        case transition(String)
        /// ATC will vector to final — no IAF, join at the final approach course. The published data has
        /// no such transition (there is no "VECTORS" row anywhere in the DB), so the app synthesizes it.
        case vectors

        var id: String { label }
        var label: String {
            switch self {
            case .transition(let fix): return fix
            case .vectors:             return "VECTORS"
            }
        }
        /// The fix to fly direct to, or nil for vectors.
        var iafFix: String? {
            switch self {
            case .transition(let fix): return fix
            case .vectors:             return nil
            }
        }
    }

    /// The published entries for one approach, in the order to show them: the transitions (alphabetical,
    /// stable) then VECTORS, which is always offered because ATC can always vector to final.
    ///
    /// `transitions` is the raw set of transition idents from the approach's CIFP rows (blank entries —
    /// the approach-proper row — are ignored).
    static func entries(transitions: [String]) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for t in transitions.prefix(64) {                        // bounded (rule 2)
            let ident = t.trimmingCharacters(in: .whitespaces).uppercased()
            guard !ident.isEmpty, seen.insert(ident).inserted else { continue }
            out.append(.transition(ident))
        }
        out.sort { $0.label < $1.label }
        out.append(.vectors)
        assert(out.count >= 1, "entries must always offer at least VECTORS")
        assert(out.count <= 65, "entries unexpectedly large")
        return out
    }

    /// Split an approach-proper leg sequence into the part flown to the runway and the MISSED APPROACH.
    ///
    /// Boundary rules, in order:
    ///   1. The `RW*` runway-threshold pseudo-fix — everything AFTER it is the missed approach. This is
    ///      the published structure and covers 9,117 of the 9,120 approaches that carry the fix.
    ///   2. Failing that, the trailing holding legs (`HM`/`HF`) — the missed-approach hold — plus any
    ///      legs from the first climb leg (`CA`/`CF`/`FA`/`VA`) that precedes them.
    /// If neither is found the approach is returned whole and the missed is empty; a caller must then
    /// fall back to the plate's printed text rather than invent a path.
    ///
    /// `legs` is (seq, fix, legType) in sequence order — the minimum this needs from a CIFPLeg.
    static func splitMissed(_ legs: [(seq: Int, fix: String, legType: String)])
        -> (approach: [Int], missed: [Int]) {
        assert(legs.count <= 512, "approach leg count out of range")
        guard !legs.isEmpty else { return ([], []) }

        // 1. runway-threshold boundary
        var thresholdIdx: Int? = nil
        for (i, l) in legs.enumerated().prefix(512) where l.fix.uppercased().hasPrefix("RW") {
            thresholdIdx = i                                     // last RW* wins (some carry two)
        }
        if let t = thresholdIdx, t + 1 < legs.count {
            return (legs.prefix(t + 1).map(\.seq), legs.suffix(from: t + 1).map(\.seq))
        }

        // 2. trailing hold: walk back over the hold, then over the climb that feeds it
        var start = legs.count
        var i = legs.count - 1
        while i >= 0, ["HM", "HF", "HA"].contains(legs[i].legType.uppercased()) {   // bounded by count
            start = i; i -= 1
        }
        if start < legs.count {
            while i >= 0, ["CA", "CF", "FA", "VA", "VM", "DF"].contains(legs[i].legType.uppercased()) {
                start = i; i -= 1
            }
            if start > 0 {
                return (legs.prefix(start).map(\.seq), legs.suffix(from: start).map(\.seq))
            }
        }
        return (legs.map(\.seq), [])
    }

    /// Match a PLATE (whose only identity is its printed name, e.g. "ILS OR LOC RWY 04R") to the coded
    /// approaches for that airport. The plate and the CIFP records share no key, so this narrows by
    /// runway and then scores the approach TYPE against the plate title.
    ///
    /// Returns every plausible coded approach, best first — one plate legitimately maps to several
    /// (an "ILS OR LOC RWY 04R" plate covers both the ILS `I04R` and the localizer `L04R`), so the
    /// caller offers a choice rather than guessing.
    ///
    /// `candidates` is (ident, name, runway) for the airport's IAP records, deduped by ident.
    static func matchPlate(plateName: String, runway: String?,
                           candidates: [(ident: String, name: String, runway: String)])
        -> [(ident: String, name: String, runway: String)] {
        assert(candidates.count <= 1024, "candidate list out of range")
        let plate = plateName.uppercased()
        let wantRw = runway?.uppercased()

        var scored: [(item: (ident: String, name: String, runway: String), score: Int)] = []
        for c in candidates.prefix(1024) {                       // bounded (rule 2)
            // Runway must agree when the plate names one; a plate without a runway (e.g. a VOR-A
            // circling approach) can't be narrowed that way.
            if let rw = wantRw, !rw.isEmpty {
                guard c.runway.uppercased() == rw else { continue }
            }
            var score = 0
            let name = c.name.uppercased()
            // Approach-type agreement is what separates I04R from L04R on the same plate.
            for token in ["ILS", "LOC", "RNAV", "GPS", "VOR", "NDB", "LDA", "SDF", "TACAN"]
            where plate.contains(token) && name.contains(token) {
                score += 2
            }
            if plate.contains("RNAV") && name.contains("GPS") { score += 1 }   // charted RNAV (GPS)
            scored.append((c, score))
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : a.item.ident < b.item.ident
        }
        return scored.map(\.item)
    }
}
