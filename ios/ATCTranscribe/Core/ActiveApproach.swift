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

    var id: String { "\(airport)-\(ident)-\(entry.label)" }
    /// Shown on the armed missed-approach control.
    var shortLabel: String { name.isEmpty ? ident : name }
    var hasCodedMissed: Bool { !missedFixes.isEmpty }
}
