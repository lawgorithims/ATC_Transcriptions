import Foundation

// The FAILSAFE behind the Clearance Test Bench. The bench edits real flight state (callsign, plan,
// context) to set up a scenario, so before it does anything it takes a verbatim snapshot of that
// state and writes it as a breadcrumb. On a normal exit the snapshot is restored. If the app is
// KILLED mid-test (crash, force-quit, OOM), the breadcrumb survives and `recoverIfInterrupted()` —
// called before any flight state loads at launch — puts the real plan back. The sandbox can never
// become the user's "real" filed plan.
//
// The snapshot is the RAW persisted blobs (not re-encoded values), so restore is byte-identical to
// what the user had and is immune to any model-shape change between encode and decode.
//
// NASA/JPL "Power of 10" (Swift): pure, small funcs, validated inputs, no unbounded work.

struct FlightStateSnapshot: Codable, Equatable {
    var flightPlan: Data?          // raw `atc.flightPlan` blob (nil = no plan filed)
    var aircraftProfiles: Data?    // raw `atc.aircraftProfiles` blob (nil = none)
    var airport: String            // `atc.airport`
    var efbSuggestionsEnabled: Bool
    var foreflightEnabled: Bool

    // The `atc.*` keys this snapshot mirrors, plus the two breadcrumb keys.
    enum Key {
        static let flightPlan       = "atc.flightPlan"
        static let aircraftProfiles = "atc.aircraftProfiles"
        static let airport          = "atc.airport"
        static let efbSuggestions   = "atc.efbSuggestions"
        static let foreflight       = "atc.foreflight"
        static let breadcrumb       = "atc.diag.snapshot"   // the encoded snapshot
        static let active           = "atc.diag.active"     // "a test bench is (was) live"
    }

    /// Capture the current flight state verbatim. Bool toggles default to `true` when unset — the
    /// same default the app itself uses (`object(forKey:) as? Bool ?? true`), so restore is faithful
    /// even for a first-run user who never touched those switches.
    static func capture(from d: UserDefaults = .standard) -> FlightStateSnapshot {
        FlightStateSnapshot(
            flightPlan: d.data(forKey: Key.flightPlan),
            aircraftProfiles: d.data(forKey: Key.aircraftProfiles),
            airport: d.string(forKey: Key.airport) ?? "",
            efbSuggestionsEnabled: (d.object(forKey: Key.efbSuggestions) as? Bool) ?? true,
            foreflightEnabled: (d.object(forKey: Key.foreflight) as? Bool) ?? true)
    }

    /// Write this snapshot as the crash breadcrumb and mark a bench live. Encoding a value type of
    /// `Data?`/`String`/`Bool` cannot realistically fail; if it somehow did we must NOT set the
    /// active flag (a flag with no snapshot behind it would be un-restorable), so both writes are
    /// gated on a successful encode.
    func persistAsBreadcrumb(to d: UserDefaults = .standard) {
        guard let blob = try? JSONEncoder().encode(self) else {
            assertionFailure("flight-state snapshot failed to encode")
            return
        }
        d.set(blob, forKey: Key.breadcrumb)
        d.set(true, forKey: Key.active)
    }

    /// Write the captured blobs/toggles back into the live `atc.*` keys (nil blob → remove the key,
    /// i.e. "no plan filed" is restored as no plan, not an empty one).
    func restoreBlobs(to d: UserDefaults = .standard) {
        writeBlob(flightPlan, forKey: Key.flightPlan, to: d)
        writeBlob(aircraftProfiles, forKey: Key.aircraftProfiles, to: d)
        d.set(airport, forKey: Key.airport)
        d.set(efbSuggestionsEnabled, forKey: Key.efbSuggestions)
        d.set(foreflightEnabled, forKey: Key.foreflight)
    }

    private func writeBlob(_ data: Data?, forKey key: String, to d: UserDefaults) {
        if let data { d.set(data, forKey: key) } else { d.removeObject(forKey: key) }
    }

    /// The pending snapshot if a bench was live and never cleanly exited, else nil.
    static func pending(in d: UserDefaults = .standard) -> FlightStateSnapshot? {
        guard d.bool(forKey: Key.active), let blob = d.data(forKey: Key.breadcrumb) else { return nil }
        return try? JSONDecoder().decode(FlightStateSnapshot.self, from: blob)
    }

    /// Remove the breadcrumb (called after a successful restore, or a clean exit).
    static func clearBreadcrumb(in d: UserDefaults = .standard) {
        d.removeObject(forKey: Key.breadcrumb)
        d.removeObject(forKey: Key.active)
    }

    /// Launch-time recovery: if a bench was interrupted, put the real flight blobs back BEFORE the
    /// app reads them, then clear the breadcrumb. Returns true when a recovery happened (for logging).
    /// Idempotent — a second call with no pending breadcrumb is a no-op.
    @discardableResult
    static func recoverIfInterrupted(in d: UserDefaults = .standard) -> Bool {
        guard let snap = pending(in: d) else { return false }
        snap.restoreBlobs(to: d)
        clearBreadcrumb(in: d)
        return true
    }
}
