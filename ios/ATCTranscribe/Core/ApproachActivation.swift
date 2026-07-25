import Foundation

/// Activating an approach: which way the aircraft joins it, which legs that produces, and where the
/// missed approach begins.
///
/// The missed-approach boundary is READ from the FAA's own published marker, not inferred: since the
/// cycle-2607 rebuild `Tools/build_cifp.py` carries ARINC's waypoint-description and route-type
/// columns through, and all 10,243 coded approaches mark exactly one missed-approach point. The
/// structural heuristic below is kept only as a fallback for a record that carries no marker.
///
/// The rest is still derived from the coded structure, which is reliable:
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
    ///
    /// Prefer `splitMissed(_:roles:)`, which uses the FAA's PUBLISHED missed-approach-point marker
    /// instead of inferring the boundary. This form remains for the ~0 records that carry no marker.
    static func splitMissed(_ legs: [(seq: Int, fix: String, legType: String)])
        -> (approach: [Int], missed: [Int]) {
        assert(legs.count <= 512, "approach leg count out of range")
        guard !legs.isEmpty else { return ([], []) }

        // 1. runway-threshold boundary
        var thresholdIdx: Int? = nil
        for (i, l) in legs.enumerated().prefix(512) where CIFP.isRunwayPseudoFix(l.fix) {
            thresholdIdx = i                                     // last RW* wins (some carry two)
        }
        if let t = thresholdIdx, t + 1 < legs.count {
            return (legs.prefix(t + 1).map(\.seq), legs.suffix(from: t + 1).map(\.seq))
        }

        // 2. trailing hold: walk back over the hold, then over the climb that feeds it.
        // Both walks use an explicit descending RANGE rather than a `while` so the iteration count is
        // statically bounded by the leg count (Power of 10, rule 2) — a corrupt record cannot spin here.
        var start = legs.count
        var i = legs.count - 1
        for idx in stride(from: legs.count - 1, through: 0, by: -1) {
            guard ["HM", "HF", "HA"].contains(legs[idx].legType.uppercased()) else { break }
            start = idx; i = idx - 1
        }
        if start < legs.count {
            for idx in stride(from: i, through: 0, by: -1) {
                guard ["CA", "CF", "FA", "VA", "VM", "DF"].contains(legs[idx].legType.uppercased()) else { break }
                start = idx
            }
            if start > 0 {
                return (legs.prefix(start).map(\.seq), legs.suffix(from: start).map(\.seq))
            }
        }
        return (legs.map(\.seq), [])
    }

    /// Split the approach using the FAA's PUBLISHED segment markers when they are present.
    ///
    /// The missed approach begins immediately AFTER the missed-approach point — the leg the source
    /// marks `M` in the 4th character of its waypoint-description code. 10,243 of the 10,243 coded
    /// approaches in cycle 2607 carry exactly one such marker, so this is a read, not an inference.
    ///
    /// Falls back to the structural heuristic only when a record carries no marker at all, so a future
    /// cycle that omits one degrades to the previous behaviour rather than losing the missed approach.
    ///
    /// `roles` is parallel to `legs`.
    static func splitMissed(_ legs: [(seq: Int, fix: String, legType: String)],
                            roles: [LegRole]) -> (approach: [Int], missed: [Int]) {
        assert(legs.count == roles.count, "roles must be parallel to legs")
        assert(legs.count <= 512, "approach leg count out of range")
        guard !legs.isEmpty else { return ([], []) }

        var mapIdx: Int? = nil
        for (i, r) in roles.enumerated().prefix(512) where r == .missedApproachPoint {
            if mapIdx == nil { mapIdx = i }                  // first marker wins
        }
        guard let m = mapIdx, m + 1 < legs.count else {
            return splitMissed(legs)                          // unmarked record → structural fallback
        }
        return (legs.prefix(m + 1).map(\.seq), legs.suffix(from: m + 1).map(\.seq))
    }

    /// The missed-approach fix sequence AS FLOWN, from the missed legs' fix idents in published order.
    ///
    /// Drops fix-less legs (climbs and vectors carry no ident) and runway-threshold pseudo-fixes, then
    /// collapses only CONSECUTIVE repeats — the hold's inbound `DF` and its `HM` leg name the same fix,
    /// so without that the sequence ends with the hold written twice.
    ///
    /// Collapsing *all* repeats instead is wrong, and dangerously so: a missed approach may legitimately
    /// return to a fix it has already crossed. PADK's I23-Y missed is ADK, COMAT, ADK, hold at ADK; with
    /// every repeat removed the sequence ended at COMAT, so the go-around's destination became a
    /// waypoint that is not the published hold — at an airport where that matters a great deal.
    static func missedSequence(_ fixes: [String]) -> [String] {
        assert(fixes.count <= 512, "missed leg count out of range")
        var out: [String] = []
        for raw in fixes.prefix(512) {                           // bounded (rule 2)
            let f = raw.uppercased()
            guard !f.isEmpty, !CIFP.isRunwayPseudoFix(f) else { continue }
            if out.last != f { out.append(f) }
        }
        assert(out.count <= fixes.count, "collapsing must not lengthen the sequence")
        return out
    }

    /// The circling designator of an approach title — the `A` in "RNAV (GPS)-A" — or nil when the title
    /// names a runway, which makes it a straight-in. Circling approaches have no runway, so this letter
    /// is the only thing distinguishing one from another at the same field.
    static func circlingLetter(_ title: String) -> Character? {
        let t = title.uppercased()
        guard !t.contains("RWY") else { return nil }
        guard let dash = t.lastIndex(of: "-") else { return nil }
        let tail = t[t.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard tail.count == 1, let ch = tail.first, ch.isLetter else { return nil }
        return ch
    }

    /// The MULTIPLE INDICATOR of an approach title — the `Z` in "RNAV (GPS) Z RWY 22" — or nil.
    ///
    /// The FAA publishes several distinct procedures to the same runway with the same primary navaid,
    /// lettered backwards from Z. They are NOT interchangeable: different minimums, different step-down
    /// fixes, different equipment requirements, and different MISSED APPROACH paths. So this letter is
    /// the whole difference between two otherwise identical-looking rows.
    ///
    /// Scanned as a standalone token rather than by position, because the letter is not always next to
    /// "RWY" — real titles include "ILS Y OR LOC Y RWY 04", "ILS Z OR LOC RWY 17" and
    /// "VOR Z OR TACAN RWY 20". Only U-Z occur in the published data.
    static func multipleIndicator(_ title: String) -> Character? {
        for token in title.uppercased().split(separator: " ").prefix(16) {   // bounded (rule 2)
            guard token.count == 1, let ch = token.first, "UVWXYZ".contains(ch) else { continue }
            return ch
        }
        return nil
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

        var scored: [(item: (ident: String, name: String, runway: String), score: Int, wrongLetter: Bool)] = []
        for c in candidates.prefix(1024) {                       // bounded (rule 2)
            // Runway must agree when the plate names one; a plate without a runway (e.g. a VOR-A
            // circling approach) can't be narrowed that way.
            if let rw = wantRw, !rw.isEmpty {
                guard c.runway.uppercased() == rw else { continue }
            }
            var score = 0
            let name = c.name.uppercased()
            // Approach-type agreement is what separates I04R from L04R on the same plate. RNP earns its
            // place here: it is what distinguishes an RNAV (RNP) AR approach — which requires specific
            // operator and aircrew authorization — from the ordinary RNAV (GPS) to the same runway.
            for token in ["ILS", "LOC", "RNAV", "GPS", "RNP", "VOR", "NDB", "LDA", "SDF", "TACAN"]
            where plate.contains(token) && name.contains(token) {
                score += 2
            }
            // Y vs Z to the same runway are different procedures with different missed approaches, and
            // they tie on every type token — so without this the ident tiebreak silently picked Y.
            //
            // A letter DISAGREEMENT disqualifies rather than merely penalises. Two different letters is
            // two different procedures, and a penalty still left the loser scoring above zero, so it
            // stayed a "confident" match: KLGA's "RNAV (GPS) Y RWY 13" plate came back as the single
            // confident candidate for the Z procedure and the sheet armed it with no chooser shown.
            // Nationwide this is always the same situation — the plate's own letter is not coded at all
            // — and the right answer there is to offer nothing rather than a different approach.
            // One side being unlettered is NOT a disagreement: "ILS Z OR LOC RWY 17" genuinely covers
            // the unlettered localizer.
            var wrongLetter = false
            let plateMult = Self.multipleIndicator(plate), nameMult = Self.multipleIndicator(name)
            switch (plateMult, nameMult) {
            case let (p?, n?):  if p == n { score += 3 } else { wrongLetter = true }
            case (nil, nil):    break
            default:            score -= 1          // one is lettered and the other is not
            }
            // Circling approaches are identified by their letter, not a runway ("RNAV (GPS)-A"). Without
            // this a circling plate ties with the straight-in of the same type and lost the ident
            // tiebreak, so the pilot's own approach ranked second in its own chooser.
            if let letter = Self.circlingLetter(plate) {
                score += Self.circlingLetter(name) == letter ? 2 : -1
            }
            scored.append((c, score, wrongLetter))
        }
        scored.sort { a, b in
            if a.wrongLetter != b.wrongLetter { return !a.wrongLetter }
            return a.score != b.score ? a.score > b.score : a.item.ident < b.item.ident
        }
        // A candidate that shares NO approach-type token with the plate title is not a match, it is
        // merely the only thing left at that airport. Returning it looked identical to a confident
        // single match, and the sheet hides its approach chooser when exactly one candidate comes back
        // — so opening 12N's "VOR-A" plate and tapping Activate silently armed R03, an RNAV approach to
        // a runway the plate does not name. Keep unscored candidates only when nothing scored at all,
        // where they are the caller's last resort AND the chooser stays visible because there is more
        // than one; a lone unscored candidate is dropped outright.
        let confident = scored.filter { $0.score > 0 && !$0.wrongLetter }
        if !confident.isEmpty { return confident.map(\.item) }
        return scored.count > 1 ? scored.map(\.item) : []
    }
}
