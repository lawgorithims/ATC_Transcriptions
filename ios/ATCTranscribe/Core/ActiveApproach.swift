import Foundation

/// The approach currently being FLOWN, and how the aircraft joined it.
///
/// Deliberately separate from `LoadedProcedure` (which records that a procedure's fixes are part of the
/// route): this is the phase-of-flight state that arms the missed-approach control and tells the map
/// which approach is live. It is not persisted — an approach belongs to the flight in progress, and a
/// stale one restored on a later launch would be worse than none.
struct ActiveApproach: Equatable, Identifiable {
    let airport: String
    let ident: String                 // ARINC ident, e.g. "I04R"
    let name: String                  // readable, e.g. "ILS RWY 04R"
    let runway: String
    let entry: ApproachActivation.Entry
    /// The coded missed-approach fixes, in sequence. Empty when the record has no missed segment
    /// (~0.3% of approaches) — the pilot then flies the plate's printed text.
    let missedFixes: [String]
    /// The published holds on this approach, each with the entry worked out for the direction the
    /// aircraft actually arrived from. Empty when the approach publishes none.
    var holds: [ApproachHold] = []
    /// Course-reversal holds the pilot has chosen to SKIP, by pattern id.
    ///
    /// Skipping is a normal, legal choice — a NoPT arrival, a straight-in clearance or radar vectors
    /// all omit the reversal — so the decision is recorded rather than the hold being deleted. The
    /// pattern stays available (and re-flyable) instead of vanishing from the procedure.
    var skippedHoldIDs: Set<String> = []

    var id: String { "\(airport)-\(ident)-\(entry.label)" }
    /// Shown on the armed missed-approach control.
    var shortLabel: String { name.isEmpty ? ident : name }
    var hasCodedMissed: Bool { !missedFixes.isEmpty }

    /// The holds actually to be flown — published, minus the ones the pilot skipped.
    var activeHolds: [ApproachHold] { holds.filter { !skippedHoldIDs.contains($0.id) } }
    /// The course reversal at the front of the approach, if it is published and not skipped.
    var courseReversalHold: ApproachHold? {
        activeHolds.first { $0.pattern.kind == .holdInLieuOfProcedureTurn }
    }
    /// The hold that terminates the missed approach, if published.
    var missedHold: ApproachHold? {
        activeHolds.first { $0.pattern.kind == .missedApproach || $0.pattern.kind == .holdToAltitude }
    }

    /// Skip (or restore) a course-reversal hold. Only a routinely-skipped hold may be dropped this
    /// way — the missed-approach hold is the published end of the go-around, so it is not silently
    /// removable from the procedure by a toggle.
    mutating func setHold(_ id: String, skipped: Bool) {
        guard let h = holds.first(where: { $0.id == id }), h.isSkippable else { return }
        if skipped { skippedHoldIDs.insert(id) } else { skippedHoldIDs.remove(id) }
    }
}
